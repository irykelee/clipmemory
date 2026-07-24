import Foundation
import Vision
import AppKit
import os

/// OCR abstraction so tests can inject a fake recognizer.
protocol OCRServiceProtocol {
    /// Recognizes text in image data (PNG/TIFF). completion(nil) when the image
    /// contains no readable text or recognition fails.
    func recognizeText(in imageData: Data, completion: @escaping (String?) -> Void)
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

    func recognizeText(in imageData: Data, completion: @escaping (String?) -> Void) {
        queue.async {
            let result = self.performRecognition(imageData: imageData)
            // BUG-044 (2026-07-21): hop completion to main. Callers that
            // mutate @Published properties risk main-thread checker
            // assertions when invoked from this .utility queue. ClipboardStore
            // .attachOCRText already self-dispatches, but defensive hop
            // here makes the API contract explicit and protects future
            // callers that forget.
            if Thread.isMainThread {
                completion(result)
            } else {
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    private func performRecognition(imageData: Data) -> String? {
        guard let image = NSImage(data: imageData),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
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
            return nil
        }

        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { return nil }
        let joined = lines.joined(separator: "\n")
        return String(joined.prefix(maxCharacters))
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

    private static func supportedRecognitionLanguages(from requested: [String]) -> [String] {
        if #available(macOS 13.0, *) {
            // The 2-arg overload is deprecated in macOS 12+ in favor of the
            // parameterless form (introduced macOS 15). Suppress the warning
            // here — we explicitly want to query Revision3 since the rest of
            // the file pins that revision for reproducibility (BUG-045).
            let supported = (try? VNRecognizeTextRequest
                .supportedRecognitionLanguages(
                    for: VNRequestTextRecognitionLevel.accurate,
                    revision: VNRecognizeTextRequestRevision3
                )) ?? []
            let filtered = requested.filter { supported.contains($0) }
            if filtered.isEmpty {
                let dropped = requested.filter { !supported.contains($0) }
                ocrLanguageLogger.error(
                    "No requested OCR language is supported by Revision3 on this macOS; requested=\(requested, privacy: .public) supported=\(supported, privacy: .public) dropped=\(dropped, privacy: .public). Falling back to en."
                )
                return ["en"]
            }
            return filtered
        }
        return requested
    }
}
