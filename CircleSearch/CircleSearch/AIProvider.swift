import AppKit
import Foundation

// MARK: - ChatTurn

struct ChatTurn {
    let role: Role
    let content: String
    let image: CGImage?

    enum Role { case user, assistant }
}

// MARK: - ProviderType

enum ProviderType: String, CaseIterable {
    case anthropic
    case openai
    case google

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic Claude"
        case .openai:    return "OpenAI"
        case .google:    return "Google Gemini"
        }
    }

    var keychainAccount: String {
        switch self {
        case .anthropic: return "anthropic-api-key"
        case .openai:    return "openai-api-key"
        case .google:    return "google-api-key"
        }
    }

    var consoleURL: URL {
        switch self {
        case .anthropic: return URL(string: "https://console.anthropic.com/")!
        case .openai:    return URL(string: "https://platform.openai.com/api-keys")!
        case .google:    return URL(string: "https://aistudio.google.com/app/apikey")!
        }
    }

    var models: [(id: String, label: String)] {
        switch self {
        case .anthropic:
            return [
                ("claude-sonnet-4-6",        "claude-sonnet-4-6 (default)"),
                ("claude-haiku-4-5-20251001", "claude-haiku-4-5-20251001 (faster)"),
                ("claude-opus-4-7",           "claude-opus-4-7 (most capable)"),
            ]
        case .openai:
            return [
                ("gpt-4o-mini", "gpt-4o-mini (default)"),
                ("gpt-4o",      "gpt-4o"),
                ("gpt-4.1",     "gpt-4.1"),
            ]
        case .google:
            return [
                ("gemini-2.0-flash", "gemini-2.0-flash (default)"),
                ("gemini-2.5-pro",   "gemini-2.5-pro (most capable)"),
            ]
        }
    }

    var defaultModel: String { models[0].id }
}

// MARK: - AIProvider

protocol AIProvider {
    static var providerType: ProviderType { get }
    static var displayName: String { get }
    static var keychainAccount: String { get }
    static var consoleURL: URL { get }
    static var models: [(id: String, label: String)] { get }

    var apiKey: String { get }
    var model: String { get }

    init(apiKey: String, model: String)

    /// Streams an AI response token-by-token.
    ///
    /// - Parameters:
    ///   - image:   The original screen capture (same across all turns in a session).
    ///   - ocrText: OCR-extracted text; included in the first user turn's prompt when non-empty.
    ///   - history: Follow-up turns after the initial analysis (assistant + user pairs).
    func stream(image: CGImage, ocrText: String, history: [ChatTurn]) -> AsyncThrowingStream<String, Error>
}

// MARK: - Shared image encoding

/// Encodes a `CGImage` as PNG and returns the base64 string.
/// Downsamples to `maxLongEdge` pixels on the long edge before encoding.
func pngBase64(from image: CGImage, maxLongEdge: CGFloat = 1568) throws -> String {
    let w        = CGFloat(image.width)
    let h        = CGFloat(image.height)
    let longEdge = max(w, h)

    let finalImage: CGImage
    if longEdge > maxLongEdge {
        let scale = maxLongEdge / longEdge
        let newW  = Int((w * scale).rounded())
        let newH  = Int((h * scale).rounded())

        guard let colorSpace = image.colorSpace,
              let context    = CGContext(
                  data: nil, width: newW, height: newH,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ImageEncodingError.pngFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        guard let scaled = context.makeImage() else {
            throw ImageEncodingError.pngFailed
        }
        finalImage = scaled
    } else {
        finalImage = image
    }

    let rep = NSBitmapImageRep(cgImage: finalImage)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw ImageEncodingError.pngFailed
    }
    NSLog("CircleSearch: encoded image %dx%d → %d KB",
          finalImage.width, finalImage.height, data.count * 4 / 3 / 1024)
    return data.base64EncodedString()
}

// MARK: - Shared errors

enum ImageEncodingError: LocalizedError {
    case pngFailed
    var errorDescription: String? { "Failed to encode the captured image as PNG." }
}

enum ProviderError: LocalizedError {
    case invalidURL
    case httpError(Int)
    case apiError(String)   // provider returned a decoded error message

    var errorDescription: String? {
        switch self {
        case .invalidURL:       return "Invalid API URL."
        case .httpError(401):   return "Invalid API key. Update it in Settings."
        case .httpError(403):   return "Invalid API key or access denied. Update it in Settings."
        case .httpError(429):   return "Rate limit reached. Wait a moment and try again."
        case .httpError(let c): return "API error (HTTP \(c)). Check Settings."
        case .apiError(let m):  return m
        }
    }
}
