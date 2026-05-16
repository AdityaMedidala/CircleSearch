import AppKit
import Foundation

// MARK: - Client

struct AnthropicClient {

    static let defaultModel = "claude-sonnet-4-6"

    private static let systemPrompt = """
        You are CircleSearch, a visual assistant. The user captured a region of their screen. \
        Analyze what they captured and provide the most useful response — explain code, summarize \
        text, translate, solve math, identify UIs, answer questions about charts or images. Be \
        concise. If the content is code, identify the language and explain or fix as appropriate. \
        If it's an error message, diagnose it and suggest a fix. If it's a chart or diagram, \
        explain what it shows. If it's a UI mockup, describe the design and propose how to build \
        it. Default to a 2-4 sentence response unless the user asks for more.
        """

    let apiKey: String
    let model: String

    init(apiKey: String, model: String = defaultModel) {
        self.apiKey = apiKey
        self.model = model
    }

    // MARK: Streaming

    /// Returns an `AsyncThrowingStream` that yields text delta strings as they arrive from
    /// the Anthropic Messages API via SSE.
    func stream(messages: [APIMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let request = try buildRequest(messages: messages)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        continuation.finish(throwing: AnthropicError.httpError(http.statusCode))
                        return
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if let text = parseTextDelta(from: payload) {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: Image encoding

    /// Encodes a `CGImage` as a PNG and returns the base64 string.
    static func pngBase64(from image: CGImage) throws -> String {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw ConversionError.pngFailed
        }
        return data.base64EncodedString()
    }

    // MARK: Private helpers

    private func buildRequest(messages: [APIMessage]) throws -> URLRequest {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw AnthropicError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body = APIRequest(
            model: model,
            maxTokens: 1024,
            stream: true,
            system: Self.systemPrompt,
            messages: messages
        )
        req.httpBody = try JSONEncoder().encode(body)
        return req
    }

    private func parseTextDelta(from json: String) -> String? {
        guard
            let data  = json.data(using: .utf8),
            let event = try? JSONDecoder().decode(SSEEvent.self, from: data),
            event.type == "content_block_delta",
            let delta = event.delta,
            delta.type == "text_delta",
            let text  = delta.text
        else { return nil }
        return text
    }
}

// MARK: - Request types

struct APIRequest: Encodable {
    let model: String
    let maxTokens: Int
    let stream: Bool
    let system: String
    let messages: [APIMessage]

    enum CodingKeys: String, CodingKey {
        case model, stream, system, messages
        case maxTokens = "max_tokens"
    }
}

struct APIMessage: Encodable {
    let role: String
    let content: APIContent
}

enum APIContent: Encodable {
    case text(String)
    case blocks([ContentBlock])

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let s):    try c.encode(s)
        case .blocks(let b):  try c.encode(b)
        }
    }
}

struct ContentBlock: Encodable {
    let type: String
    let text: String?
    let source: ImageSource?

    static func text(_ text: String) -> ContentBlock {
        ContentBlock(type: "text", text: text, source: nil)
    }

    static func image(mediaType: String, base64Data: String) -> ContentBlock {
        ContentBlock(
            type: "image",
            text: nil,
            source: ImageSource(type: "base64", mediaType: mediaType, data: base64Data)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        if let text   { try c.encode(text,   forKey: .text) }
        if let source { try c.encode(source, forKey: .source) }
    }

    private enum CodingKeys: String, CodingKey { case type, text, source }
}

struct ImageSource: Encodable {
    let type: String
    let mediaType: String
    let data: String

    enum CodingKeys: String, CodingKey {
        case type, data
        case mediaType = "media_type"
    }
}

// MARK: - SSE response types

struct SSEEvent: Decodable {
    let type: String
    let index: Int?
    let delta: SSEDelta?
}

struct SSEDelta: Decodable {
    let type: String
    let text: String?
}

// MARK: - Errors

enum AnthropicError: LocalizedError {
    case invalidURL
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:       return "Invalid API URL."
        case .httpError(401):   return "Invalid API key. Update it in Settings → API."
        case .httpError(429):   return "Rate limit reached. Wait a moment and try again."
        case .httpError(let c): return "API error (HTTP \(c)). Check Settings → API."
        }
    }
}

enum ConversionError: LocalizedError {
    case pngFailed
    var errorDescription: String? { "Failed to encode the captured image as PNG." }
}
