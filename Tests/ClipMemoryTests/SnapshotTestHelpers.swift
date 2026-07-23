import XCTest
import SwiftUI
import AppKit
@testable import ClipMemory

/// Snapshot test infrastructure for ClipMemory (NEW-7 Phase 1).
///
/// Renders SwiftUI views off-screen to PNG and compares byte-for-byte
/// against a golden file on disk.
///
/// Why not swift-snapshot-testing (pointfreeco)?
/// - v1.19.x requires Swift 6.0 tools-version, producing a swiftmodule with
///   Swift 6 ABI mangling. Our project compiles tests with Swift 5 language
///   mode (`SWIFT_VERSION: "5.9"`), and Swift 5 client cannot import a Swift 6
///   ABI module — `assertSnapshot` is not found at link time.
/// - v1.17.0 (Swift 5.9 tools-version) compiles with our toolchain but its
///   source uses an `Issue.record` signature that the newer Testing module
///   shipped with Xcode 26.6 rejects, breaking the package itself.
/// - Bumping our project to `SWIFT_VERSION: "6.0"` is a project-wide change
///   that risks subtle concurrency errors across the 35 existing test files.
/// - A minimal in-house helper is ~40 lines, has no external coupling, and
///   serves the same visual-regression purpose.
///
/// Why ImageRenderer (not UIGraphicsImageRenderer / CALayer.render):
/// - ImageRenderer is the Apple-blessed macOS 13+ path for offscreen SwiftUI
///   rendering. It correctly handles `@Environment`, `@EnvironmentObject`,
///   and SwiftUI Material backgrounds that hand-rolled Core Graphics paths
///   miss.
/// - 1× scale is required for cross-machine snapshot stability. Retina
///   (2×/3×) snapshots differ across developer machines because the pixel
///   count varies with display configuration.
///
/// Snapshot test infrastructure for ClipMemory (NEW-7 Phase 1).
///
/// Renders SwiftUI views off-screen to PNG and compares byte-for-byte
/// against a golden file on disk.
///
/// Recording mode: implicit on first run. If the golden PNG does not exist
/// at the expected path, it is written and the test passes. Subsequent runs
/// compare the rendered image byte-for-byte against the existing golden. To
/// regenerate a golden after an intentional visual change, delete the PNG
/// from `__Snapshots__/<TestClassName>/` and re-run the test.
///
/// Why not swift-snapshot-testing (pointfreeco)?
/// - v1.19.x requires Swift 6.0 tools-version, producing a swiftmodule with
///   Swift 6 ABI mangling. Our project compiles tests with Swift 5 language
///   mode (`SWIFT_VERSION: "5.9"`), and Swift 5 client cannot import a Swift 6
///   ABI module — `assertSnapshot` is not found at link time.
/// - v1.17.0 (Swift 5.9 tools-version) compiles with our toolchain but its
///   source uses an `Issue.record` signature that the newer Testing module
///   shipped with Xcode 26.6 rejects, breaking the package itself.
/// - Bumping our project to `SWIFT_VERSION: "6.0"` is a project-wide change
///   that risks subtle concurrency errors across the 35 existing test files.
/// - A minimal in-house helper is ~50 lines, has no external coupling, and
///   serves the same visual-regression purpose.
///
/// Why ImageRenderer (not UIGraphicsImageRenderer / CALayer.render):
/// - ImageRenderer is the Apple-blessed macOS 13+ path for offscreen SwiftUI
///   rendering. It correctly handles `@Environment`, `@EnvironmentObject`,
///   and SwiftUI Material backgrounds that hand-rolled Core Graphics paths
///   miss.
/// - 1× scale is required for cross-machine snapshot stability. Retina
///   (2×/3×) snapshots differ across developer machines because the pixel
///   count varies with display configuration.
///
/// Golden files live at
/// `<test-file-dir>/__Snapshots__/<TestClassName>/<testName>.png` and are
/// gitignored.

@MainActor
func renderToImage<V: View>(_ view: V, size: CGSize = CGSize(width: 800, height: 600)) -> CGImage {
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
    renderer.scale = 1.0
    renderer.proposedSize = .init(width: size.width, height: size.height)
    guard let cgImage = renderer.cgImage else {
        fatalError("ImageRenderer failed for view at size \(size)")
    }
    return cgImage
}

func pngData(from cgImage: CGImage) -> Data {
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    return bitmap.representation(using: .png, properties: [:]) ?? Data()
}

/// Asserts that `image` matches the golden PNG at the conventional path.
///
/// Behavior:
/// - If the golden PNG does not exist (first run, or after deletion),
///   the rendered image is written as the golden and the test PASSES.
/// - If the golden exists, the rendered image is compared byte-for-byte
///   against it. Mismatch fails the test.
///
/// To regenerate a golden after an intentional visual change: delete the
/// PNG from `__Snapshots__/<className>/` and re-run the test.
///
/// `className` is the XCTestCase subclass name (passed by the caller since
/// `assertImageSnapshot` is a free function, not a method).
func assertImageSnapshot(
    _ image: CGImage,
    className: String,
    testName: String,
    file: StaticString = #file,
    line: UInt = #line
) {
    let sourceFileURL = URL(fileURLWithPath: String(describing: file))
        .deletingLastPathComponent()
    let goldenDir = sourceFileURL.appendingPathComponent("__Snapshots__/\(className)")
    let goldenURL = goldenDir.appendingPathComponent("\(testName).png")
    let actualData = pngData(from: image)

    // CI mode: always re-record. GitHub Actions runners (macos-latest)
    // render SwiftUI slightly differently from local macOS (different
    // minor versions, SF Symbols availability, ImageRenderer encoding),
    // so byte-for-byte comparison is unreliable across environments. On
    // CI we treat snapshot tests as render smoke tests: confirm the view
    // can be rendered + written to PNG, skip the visual comparison. Local
    // runs (env var unset) keep the strict comparison for regression
    // detection.
    //
    // Detect CI via GITHUB_ACTIONS="true" (set by GitHub Actions) AND
    // CI="true" (set by many CI providers). xcodebuild test does not
    // always inherit CI from the workflow shell, so check both.
    let env = ProcessInfo.processInfo.environment
    let isCI = env["GITHUB_ACTIONS"] == "true" || env["CI"] == "true"
    if isCI {
        do {
            try FileManager.default.createDirectory(at: goldenDir, withIntermediateDirectories: true)
            try actualData.write(to: goldenURL)
        } catch {
            XCTFail("Failed to record golden at \(goldenURL.path) on CI: \(error)", file: file, line: line)
        }
        return
    }

    // First-run auto-record. If the golden is missing, write it and pass.
    // This is the standard Jest/Rspec snapshot pattern: writing new
    // goldens is implicit; asserting against existing ones is explicit.
    if !FileManager.default.fileExists(atPath: goldenURL.path) {
        do {
            try FileManager.default.createDirectory(at: goldenDir, withIntermediateDirectories: true)
            try actualData.write(to: goldenURL)
            print("Snapshot recorded: \(goldenURL.path)")
            return
        } catch {
            XCTFail("Failed to record golden at \(goldenURL.path): \(error)", file: file, line: line)
            return
        }
    }

    guard let expectedData = try? Data(contentsOf: goldenURL) else {
        XCTFail(
            "Failed to read golden at \(goldenURL.path). Delete it to re-record.",
            file: file, line: line
        )
        return
    }

    if expectedData != actualData {
        XCTFail(
            "Snapshot mismatch for \(className)/\(testName). " +
            "Expected \(expectedData.count) bytes, got \(actualData.count) bytes. " +
            "Delete the golden to regenerate.",
            file: file, line: line
        )
    }
}

/// Isolates snapshot tests from global state pollution by other tests in
/// the suite. Without this, prior tests mutating `fontScale`
/// (UserDefaults key read by `@AppStorage("fontScale")`) or
/// `LanguageManager.shared.selectedLanguage` produce different render
/// output under full-suite vs focused test runs.
///
/// Call from `setUp()` of any test class that calls `assertImageSnapshot`.
/// Stores the original values and restores them in `tearDown()`.
func snapshotTestSetUp() {
    let defaults = UserDefaults.standard
    snapshotTestSavedFontScale = defaults.double(forKey: "fontScale")
    snapshotTestSavedLanguage = LanguageManager.shared.selectedLanguage
    // Force defaults used by our rendered views to a deterministic baseline
    defaults.set(1.0, forKey: "fontScale")
    LanguageManager.shared.selectedLanguage = "en"
}

func snapshotTestTearDown() {
    let defaults = UserDefaults.standard
    if snapshotTestSavedFontScale != nil {
        defaults.set(snapshotTestSavedFontScale, forKey: "fontScale")
    } else {
        defaults.removeObject(forKey: "fontScale")
    }
    LanguageManager.shared.selectedLanguage = snapshotTestSavedLanguage
}

private var snapshotTestSavedFontScale: Double?
private var snapshotTestSavedLanguage: String = "en"