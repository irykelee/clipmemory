import Foundation
import Vision
import AppKit

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
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en", "ja", "ko"]

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
}
