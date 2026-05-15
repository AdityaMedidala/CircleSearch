import Vision
import CoreGraphics

/// Runs Vision text recognition off the main thread and returns the extracted string.
enum OCRManager {

    /// Recognises text in `image` using `VNRecognizeTextRequest` at the accurate level.
    /// Dispatches the synchronous Vision call to a background thread to avoid blocking the UI.
    nonisolated static func recognizeText(in image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest { req, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    let lines = (req.results as? [VNRecognizedTextObservation] ?? [])
                        .compactMap { $0.topCandidates(1).first?.string }
                    continuation.resume(returning: lines.joined(separator: "\n"))
                }
                request.recognitionLevel        = .accurate
                request.usesLanguageCorrection  = true
                request.automaticallyDetectsLanguage = true

                do {
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
