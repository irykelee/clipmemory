import Foundation
import Vision
import AppKit
import CoreImage
import ImageIO
import os

/// MED-8 (2026-07-26 review): discriminated OCR outcome so callers can
/// distinguish "no text found" (normal, non-actionable) from "Vision engine"
/// error" (actionable — logs, diagnostics, or degraded-mode UX).
enum OCROutcome {
    case text(String)
    case noText
    case failure(Error)
}

extension Notification.Name {
    /// ID-OCR-0002 (2026-07-30 audit): posted when the requested OCR
    /// language(s) are not supported by `VNRecognizeTextRequestRevision3`
    /// on this macOS and the recognizer falls back to a different (usually
    /// "en") language. UTF-16 payloads so consumers can route the warning
    /// to a UI banner without joining the requested list on the receiver.
    /// Carries no payload when the requested list was empty (no fallback).
    static let ocrLanguageFallback = Notification.Name("OCRService.languageFallback")
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
        // ID-OCR-0001 (2026-07-30 audit): honour EXIF orientation.
        // iPhone HEIC photos copied via AirDrop carry `Orientation=6/8`
        // (rotated). `VNImageRequestHandler(cgImage:options:)` does NOT
        // apply that — Apple-documented. Building a `CIImage` from `Data`
        // goes through CoreImage which honours EXIF, then we ask for
        // `cgImage` on the oriented CIImage and pass that to Vision.
        // Plain `NSImage(data:).cgImage` skips the orientation step.
        guard let orientedCGImage = Self.cgImageRespectingEXIF(from: imageData) else {
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
        // ID-OCR-0005 (2026-07-30 audit): default `minimumTextHeight = 0.02`
        // is tuned for printed-document photos. UI screenshots and dense
        // terminal/code captures drop below 0.02 of the image height and
        // return `.noText` despite visually-clear text. 0.01 matches the
        // common "12-pt text on a Retina display" case; the accuracy cost
        // on printed documents is acceptable because false positives are
        // filtered by `topCandidates(1).confidence` at the result layer.
        request.minimumTextHeight = 0.01
        request.recognitionLanguages = Self.supportedRecognitionLanguages(
            from: ["zh-Hans", "zh-Hant", "en", "ja", "ko"]
        )

        // ID-OCR-0006 (2026-07-30 audit): watchdog around Vision's
        // synchronous `perform`. A malformed / corrupt / unusually-large
        // image (e.g. 50-MB TIFF from an old scanner, or a PNG with
        // truncated IDAT that Vision tries to decode internally) can hang
        // the recognizer indefinitely; without an external timeout the
        // hung call blocks the serial OCR queue and every subsequent
        // `recognizeText` waits behind it. The public Vision SDK has no
        // timeout API, so we run `perform` on a background queue and arm
        // a DispatchSourceTimer that calls `request.cancel()` if it
        // overruns `performTimeoutSeconds`. After cancel the queued
        // `perform` throws (caught below) and the call returns `.failure`.
        let handler = VNImageRequestHandler(cgImage: orientedCGImage, options: [:])
        // Capture the perform error so we can distinguish "Vision threw
        // (e.g. cancel-induced)" from "Vision returned successfully".
        // `request.cancel()` is documented to make `perform` throw on
        // its next checkpoint — the watchdog fires when timeout elapses,
        // the throw propagates, and the workItem completes with the
        // error captured here.
        var performError: Error?
        let workItem = DispatchWorkItem {
            do {
                try handler.perform([request])
            } catch {
                performError = error
            }
        }
        let resultSemaphore = DispatchSemaphore(value: 0)
        workItem.notify(queue: Self.performQueue) { resultSemaphore.signal() }
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
        let cancelTimer = DispatchSource.makeTimerSource(queue: Self.performQueue)
        cancelTimer.schedule(deadline: .now() + Self.performTimeoutSeconds)
        cancelTimer.setEventHandler {
            // `request.cancel()` is atomic and thread-safe per Apple docs
            // — safe to call from the watchdog queue. The next time
            // `perform` checks its cancel flag (Vision polls at internal
            // boundaries), it throws and the workItem's catch block
            // captures the error.
            request.cancel()
        }
        cancelTimer.resume()
        let waitResult = resultSemaphore.wait(timeout: .now() + Self.performTimeoutSeconds + 1.0)
        cancelTimer.cancel()
        if waitResult == .timedOut {
            // Belt-and-braces: the cancel timer should have fired and
            // made `perform` throw before the semaphore wait timed out.
            // If we still hit this branch, Vision is hung in a way even
            // `request.cancel()` couldn't unblock — return failure so the
            // serial queue at least keeps moving.
            Self.ocrLanguageLogger.error("Vision recognition timed out after \(String(Self.performTimeoutSeconds), privacy: .public)s; returning failure")
            return .failure(NSError(
                domain: "OCRService.timeout",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Vision recognition timed out"]
            ))
        }
        if let performError = performError {
            // ID-OCR-0006: log the captured error so the operator can
            // distinguish "Vision cancelled by watchdog" from "Vision
            // threw for some other reason" (e.g. corrupt input).
            Self.ocrLanguageLogger.error("Vision recognition failed: \(performError.localizedDescription, privacy: .public)")
            return .failure(performError)
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { return .noText }
        let joined = lines.joined(separator: "\n")
        return .text(String(joined.prefix(maxCharacters)))
    }

    /// ID-OCR-0006 (2026-07-30 audit): dedicated queue for the Vision
    /// `perform` watchdog. The serial `com.clipmemory.ocr` queue is the
    /// "logical" serial gate for OCR work; this is a separate
    /// priority-of-life queue used only for the cancel-timer source, so
    /// a Vision hang on one item can't stall the watchdog for the next.
    private static let performQueue = DispatchQueue(label: "com.clipmemory.ocr.perform", qos: .utility)

    /// ID-OCR-0006: 15 s cap on a single Vision `perform` call. Picked
    /// empirically: well-formed images on Apple Silicon return in
    /// 50-500 ms; 15 s is 30× the worst case I've measured and short
    /// enough to clear the serial queue within a backfill's interval.
    /// Returns `.failure` rather than blocking forever.
    private static let performTimeoutSeconds: TimeInterval = 15

    /// ID-OCR-0001: decode image bytes via Image I/O so the EXIF
    /// orientation is applied before we hand the bitmap to Vision.
    /// Falls back to the full-resolution CGImage when Image I/O can't
    /// make a source (corrupt headers, formats Image I/O doesn't index).
    ///
    /// ID-OCR-0007 (2026-07-30 audit): replace the previous
    /// `CIImage → CIContext.createCGImage` + `NSImage.cgImage` pair with
    /// `CGImageSourceCreateThumbnailAtIndex` capped at
    /// `thumbnailMaxPixelSize` (2048 px). The previous path decoded the
    /// full image into a backing CGImage (50+ MB for a 6K HEIC) and the
    /// CIContext's createCGImage retained a second bitmap buffer during
    /// the copy. With `backfillMaxConcurrentOCR = 4` that's ~200-400 MB
    /// transient resident above baseline during a backfill burst —
    /// exceeded ID-PERF-0007's footprint budget on memory-constrained
    /// 8 GB MacBook Airs. `CGImageSourceCreateThumbnailAtIndex` with
    /// `kCGImageSourceCreateThumbnailWithTransform` honours EXIF
    /// orientation in the same pass, so the ID-OCR-0001 correctness
    /// contract is preserved. Vision's accuracy on a 2048-px thumbnail
    /// of a 6K screenshot is comparable for UI text (the common case);
    /// printed-document photos drop slightly but our recognition result
    /// is for search/snippet, not pixel-perfect transcription.
    private static let thumbnailMaxPixelSize: CGFloat = 2048

    private static func cgImageRespectingEXIF(from data: Data) -> CGImage? {
        // Image I/O path: single-buffer thumbnail with EXIF orientation
        // applied. `kCGImageSourceShouldCacheImmediately = false` defers
        // the bitmap decode until the thumbnail is actually drawn —
        // combined with the 2048-px cap, peak memory for a 6K HEIC
        // drops from ~100 MB to ~16 MB.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return fallbackFullResolutionCGImage(from: data)
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
            kCGImageSourceShouldCacheImmediately: false
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) {
            return cgImage
        }
        // Fallback: source exists but thumbnail generation failed (rare —
        // animated GIFs, some formats). Use the full image as a last
        // resort so OCR still gets a bitmap.
        return fallbackFullResolutionCGImage(from: data)
    }

    /// ID-OCR-0007: full-resolution CGImage fallback. Only used when
    /// `CGImageSourceCreateThumbnailAtIndex` returns nil — animated GIFs,
    /// unusual formats, or corrupt headers. Pays the full-memory cost
    /// (50+ MB for a 6K HEIC) but only on the rare failure path; the
    /// common path is the 2048-px thumbnail above.
    ///
    /// Internal (not private) so the ID-OCR-0009 regression test can feed
    /// it an EXIF-rotated JPEG directly — simulating "thumbnail generation
    /// failed" deterministically is not practical from the test side.
    static func fallbackFullResolutionCGImage(from data: Data) -> CGImage? {
        if let ciImage = CIImage(data: data) {
            // ID-OCR-0009 (2026-07-31 audit, ID-OCR-0001 residual):
            // `CIImage(data:)` records the EXIF orientation in
            // `properties` but does NOT bake it into the bitmap —
            // `createCGImage(_:from: ciImage.extent)` returned the
            // unrotated pixels, so Vision misread rotated screenshots
            // (e.g. AirDropped iPhone photos) whenever the thumbnail path
            // failed. Apply `.oriented(_:)` here, matching what the
            // thumbnail path's `kCGImageSourceCreateThumbnailWithTransform`
            // does in its pass.
            var oriented = ciImage
            if let raw = ciImage.properties[kCGImagePropertyOrientation as String] as? NSNumber,
               let exif = CGImagePropertyOrientation(rawValue: raw.uint32Value),
               exif != .up {
                oriented = ciImage.oriented(exif)
            }
            let context = CIContext(options: [.useSoftwareRenderer: false])
            return context.createCGImage(oriented, from: oriented.extent)
        }
        if let image = NSImage(data: data) {
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        return nil
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

    /// ID-SILENT-0016 (2026-07-31 audit): test seam around the Vision
    /// language query so tests can simulate a framework throw. Production
    /// never reassigns this; tests must restore the original afterwards
    /// (paired with `resetSupportedLanguagesCacheForTesting`).
    static var recognitionLanguagesQuery: (Int) throws -> [String] = { revision in
        try VNRecognizeTextRequest.supportedRecognitionLanguages(
            for: VNRequestTextRecognitionLevel.accurate,
            revision: revision
        )
    }

    /// ID-SILENT-0016: test-only cache reset so language-query tests stay
    /// isolated from each other and from earlier real queries in the session.
    static func resetSupportedLanguagesCacheForTesting() {
        cachedSupportedLanguagesLock.lock()
        cachedSupportedLanguages.removeAll()
        cachedSupportedLanguagesLock.unlock()
    }

    /// Internal (not private) so the ID-SILENT-0016 regression tests can
    /// drive the cache through the injected query above.
    static func supportedRecognitionLanguages(for revision: Int) -> [String] {
        cachedSupportedLanguagesLock.lock()
        if let cached = cachedSupportedLanguages[revision] {
            cachedSupportedLanguagesLock.unlock()
            return cached
        }
        cachedSupportedLanguagesLock.unlock()

        // ID-SILENT-0016 (2026-07-31 audit): distinguish "query returned an
        // empty array" (a valid answer — cacheable) from "query threw"
        // (transient framework failure — do NOT cache). The previous
        // `(try? ...) ?? []` cached an empty array on the first Vision
        // error, so every language was judged unsupported for the rest of
        // the session even after the framework recovered. On throw: log,
        // return empty for this call only, and let the next call re-query.
        let supported: [String]
        do {
            supported = try recognitionLanguagesQuery(revision)
        } catch {
            ocrLanguageLogger.error(
                "supportedRecognitionLanguages query threw for revision \(revision, privacy: .public): \(error.localizedDescription, privacy: .public). Not caching; will re-query on next OCR call."
            )
            return []
        }

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
                // ID-OCR-0002 (2026-07-30 audit): tag the log with
                // `userLocale` so on-call can correlate the fallback with the
                // user's macOS language list (CJK users hit this most often
                // because zh-Hans / zh-Hant / ja / ko are the most likely
                // to be staggered across macOS revisions). Also post
                // `.ocrLanguageFallback` so a future settings banner can
                // surface "OCR recognition is using English on this Mac"
                // — the user-facing diagnostic that the original log line
                // didn't provide.
                let userLocale = Locale.current.identifier
                ocrLanguageLogger.error(
                    "No requested OCR language is supported by Revision3 on this macOS; requested=\(requested, privacy: .public) supported=\(supported, privacy: .public) dropped=\(dropped, privacy: .public) userLocale=\(userLocale, privacy: .public). Falling back to en."
                )
                NotificationCenter.default.post(
                    name: .ocrLanguageFallback,
                    object: nil,
                    userInfo: [
                        "requested": requested,
                        "supported": supported,
                        "dropped": dropped,
                        "userLocale": userLocale
                    ]
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
            let userLocale = Locale.current.identifier
            ocrLanguageLogger.error(
                "No requested OCR language is supported by Revision2 on this macOS; requested=\(requested, privacy: .public) supported=\(supported, privacy: .public) userLocale=\(userLocale, privacy: .public). Falling back to en."
            )
            NotificationCenter.default.post(
                name: .ocrLanguageFallback,
                object: nil,
                userInfo: [
                    "requested": requested,
                    "supported": supported,
                    "userLocale": userLocale
                ]
            )
            return supported.contains("en") ? ["en"] : Array(supported.prefix(1))
        }
        return filtered
    }
}
