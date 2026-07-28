import Foundation
import Vision
import AppKit
import os

/// MED-8 (2026-07-26 review): discriminated OCR outcome so callers can
/// distinguish "no text found" (normal, non-actionable) from "Vision engine
/// error" (actionable — logs, diagnostics, or degraded-mode UX).
enum OCROutcome {
    case text(String)
    case noText
    case failure(Error)
}

/// OCR abstraction so tests can inject a fake recognizer.
protocol OCRServiceProtocol {
    /// Recognizes text in image data (PNG/TIFF).
    func recognizeText(in imageData: Data, completion: @escaping (OCROutcome) -> Void)
}

/// Vision-framework OCR. Runs entirely on-device (Neural Engine on Apple
/// Silicon); nothing leaves the machine. Uses the system's newest text
/// recognition revision by default, so accuracy improves with newer macOS.
final class VisionOCRService: OCRServiceProtocol {
    static let shared = VisionOCRService()

    /// Serial queue so bursts of new screenshots don't starve the clipboard
    /// monitor or spin up many concurrent Vision requests.
    private let queue = DispatchQueue(label: "com.clipmemory.ocr", qos: .utility)
    private let maxCharacters = 2000

    private init() {}

    func recognizeText(in imageData: Data, completion: @escaping (OCROutcome) -> Void) {
        queue.async {
            let result = self.performRecognition(imageData: imageData)
            // BUG-044 (2026-07-21) + 2026-07-28 F-2 audit closeout: hop completion to
            // main. This is contract enforcement, NOT a defensive patch —
            // `ClipboardMonitor.processImageData` invokes the completion from a
            // background queue and immediately calls
            // `delegate?.monitorDidRecognizeText(...)` with no self-hop at the caller
            // (see ClipboardMonitor.swift:459-463), so this dispatch is load-bearing.
            //
            // Future callers from a non-main context should NOT remove this without
            // first providing their own main-thread hop (e.g. via
            // `MainActor.assumeIsolated`). Future F-2 work after F-1 phase 3
            // (ClipboardStore @MainActor) will sweep `ClipboardStore+OCR.swift:56, 70`
            // — those are the LAST remaining "if Thread.isMainThread" sites that may
            // become deletable; this site is not in that set.
            if Thread.isMainThread {
                completion(result)
            } else {
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    private func performRecognition(imageData: Data) -> OCROutcome {
        guard let image = NSImage(data: imageData),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .noText
        }

        // BUG-045 (2026-07-21): pin revision explicitly. The default
        // revision can change across macOS versions, producing inconsistent
        // OCR results across user upgrades.
        let request = VNRecognizeTextRequest()
        if #available(macOS 13.0, *) {
            request.revision = VNRecognizeTextRequestRevision3
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = Self.supportedRecognitionLanguages(
            from: ["zh-Hans", "zh-Hant", "en", "ja", "ko"]
        )

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            // MED-8 (2026-07-26 review): surface Vision errors as .failure
            // so callers can log / diagnose / degrade differently from the
            // normal "image has no text" case.
            Self.ocrLanguageLogger.error("Vision recognition failed: \(error.localizedDescription, privacy: .public)")
            return .failure(error)
        }

        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { return .noText }
        let joined = lines.joined(separator: "\n")
        return .text(String(joined.prefix(maxCharacters)))
    }

    /// NEW-1 (2026-07-21): filter the requested languages against the ones
    /// the active revision actually supports. If macOS drops a locale in a
    /// future release, the previous code would set an unsupported value and
    /// `handler.perform` would throw — caught and silently turned into a
    /// nil OCR result. The user would see "no text recognized" with no
    /// indication that a config mismatch is the cause. Falling back to
    /// "en" only when NONE of the requested langs are supported keeps
    /// every supported locale working and degrades gracefully otherwise.
    ///
    /// M-23 (2026-07-24 audit): log when the fallback to "en" actually
    /// fires — the audit pointed out that silent downgrade gives no
    /// signal when a future macOS drops a locale that's still in our
    /// requested list. Operators (and the on-call for transcripts) can
    /// `log show --predicate 'subsystem == "com.clipmemory.app"'` and
    /// see exactly which locales were dropped. Avoids guess-debug loop
    /// when users report "OCR doesn't recognize my language".
    private static let ocrLanguageLogger = Logger(
        subsystem: "com.clipmemory.app",
        category: "OCR.supportedLanguages"
    )

    /// M-7 (2026-07-25 audit): the Vision-supported language list for a given
    /// revision is invariant at runtime, but we previously queried it on every
    /// OCR invocation. Cache the result per revision to avoid repeated
    /// framework round-trips during backfills.
    private static var cachedSupportedLanguages: [Int: [String]] = [:]
    private static let cachedSupportedLanguagesLock = NSLock()

    private static func supportedRecognitionLanguages(for revision: Int) -> [String] {
        cachedSupportedLanguagesLock.lock()
        if let cached = cachedSupportedLanguages[revision] {
            cachedSupportedLanguagesLock.unlock()
            return cached
        }
        cachedSupportedLanguagesLock.unlock()

        let supported = (try? VNRecognizeTextRequest
            .supportedRecognitionLanguages(
                for: VNRequestTextRecognitionLevel.accurate,
                revision: revision
            )) ?? []

        cachedSupportedLanguagesLock.lock()
        cachedSupportedLanguages[revision] = supported
        cachedSupportedLanguagesLock.unlock()
        return supported
    }

    private static func supportedRecognitionLanguages(from requested: [String]) -> [String] {
        if #available(macOS 13.0, *) {
            // The 2-arg overload is deprecated in macOS 12+ in favor of the
            // parameterless form (introduced macOS 15). Suppress the warning
            // here — we explicitly want to query Revision3 since the rest of
            // the file pins that revision for reproducibility (BUG-045).
            let supported = supportedRecognitionLanguages(for: VNRecognizeTextRequestRevision3)
            let filtered = requested.filter { supported.contains($0) }
            if filtered.isEmpty {
                let dropped = requested.filter { !supported.contains($0) }
                ocrLanguageLogger.error(
                    "No requested OCR language is supported by Revision3 on this macOS; requested=\(requested, privacy: .public) supported=\(supported, privacy: .public) dropped=\(dropped, privacy: .public). Falling back to en."
                )
                // CLIP-5 (2026-07-24 review): "en" itself is not guaranteed
                // to be in `supported` (a future macOS could drop it, and
                // `supported` can even be empty when the query throws).
                // Setting an unsupported language makes handler.perform
                // throw — the exact failure this function exists to avoid.
                return supported.contains("en") ? ["en"] : Array(supported.prefix(1))
            }
            return filtered
        }
        // CLIP-5 (2026-07-24 review): the pre-13 path passed `requested`
        // through unfiltered — an unsupported entry would make
        // handler.perform throw and OCR silently return nil. Run the same
        // supported-filter + verified fallback as the 13+ path. (Dead on
        // this project's macOS 13 deployment target; kept compiling for
        // correctness if the target ever drops.)
        let supported = supportedRecognitionLanguages(for: VNRecognizeTextRequestRevision2)
        let filtered = requested.filter { supported.contains($0) }
        if filtered.isEmpty {
            return supported.contains("en") ? ["en"] : Array(supported.prefix(1))
        }
        return filtered
    }
}
