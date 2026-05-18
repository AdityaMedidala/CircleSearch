import AppKit
import Foundation

// MARK: - OpenAIProvider

struct OpenAIProvider: AIProvider {

    // MARK: Static metadata

    static let providerType:    ProviderType = .openai
    static let displayName                   = "OpenAI"
    static let keychainAccount               = "openai-api-key"
    static let consoleURL                    = URL(string: "https://platform.openai.com/api-keys")!
    static let models: [(id: String, label: String)] = [
        ("gpt-4o-mini", "gpt-4o-mini (default)"),
        ("gpt-4o",      "gpt-4o"),
        ("gpt-4.1",     "gpt-4.1"),
    ]
    static let defaultModel = "gpt-4o-mini"

    // MARK: Instance

    let providerKind: ProviderType = .openai
    let apiKey: String
    let model: String

    init(apiKey: String, model: String = defaultModel) {
        self.apiKey = apiKey
        self.model  = model
    }

    // MARK: AIProvider.stream

    func stream(image: CGImage, ocrText: String, history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let messages = try buildMessages(image: image, ocrText: ocrText, history: history)
                    let request  = try buildRequest(messages: messages)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let http = response as? HTTPURLResponse {
                        NSLog("CircleSearch: OpenAIProvider — HTTP %d", http.statusCode)
                        if http.statusCode != 200 {
                            var body = Data()
                            for try await byte in bytes { body.append(byte) }
                            NSLog("CircleSearch: OpenAIProvider — error body: %@",
                                  String(data: body, encoding: .utf8) ?? "(non-UTF8)")
                            continuation.finish(throwing: ProviderError.httpError(http.statusCode))
                            return
                        }
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))

                        // OpenAI signals end-of-stream with the literal string "[DONE]".
                        if payload == "[DONE]" {
                            continuation.finish()
                            return
                        }

                        if let text = textDelta(from: payload) {
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

    // MARK: Private — message building

    private func buildMessages(image: CGImage, ocrText: String, history: [ChatTurn]) throws -> [OAMessage] {
        var messages: [OAMessage] = []

        // System message goes first in the messages array for OpenAI.
        messages.append(OAMessage(role: "system", content: .text(Self.systemPrompt)))

        // First user message: image (as data URI) + prompt with optional OCR block.
        let closing = history.isEmpty
            ? "Please analyze the captured content above."
            : "The above is the screen capture for reference."

        let promptText: String
        if ocrText.isEmpty {
            promptText = closing
        } else {
            promptText = """
            Here is text extracted from the screen capture via OCR (use this to verify exact \
            wording, codes, or details that may be unclear in the image):
            \(ocrText)

            \(closing)
            """
        }

        let b64     = try pngBase64(from: image)
        let dataURI = "data:image/png;base64,\(b64)"

        messages.append(OAMessage(role: "user", content: .parts([
            .imageURL(dataURI),
            .text(promptText),
        ])))

        // Follow-up turns are plain text on both sides.
        for turn in history {
            messages.append(OAMessage(
                role:    turn.role == .user ? "user" : "assistant",
                content: .text(turn.content)
            ))
        }
        return messages
    }

    // MARK: Private — request building

    private func buildRequest(messages: [OAMessage]) throws -> URLRequest {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw ProviderError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json",    forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)",    forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(
            OARequest(model: model, maxTokens: 1024, stream: true, messages: messages)
        )
        return req
    }

    // MARK: Private — SSE parsing

    /// Extracts the text delta from a chat.completions SSE chunk.
    /// Returns `nil` for role-only deltas (first event) and finish-reason events.
    private func textDelta(from json: String) -> String? {
        guard
            let data  = json.data(using: .utf8),
            let chunk = try? JSONDecoder().decode(OASSEChunk.self, from: data),
            let text  = chunk.choices.first?.delta.content,
            !text.isEmpty
        else { return nil }
        return text
    }

    // MARK: System prompt

    private static let systemPrompt = """
        You are an AI assistant helping the user understand and explore content from their screen. \
        They've captured a region of their screen and may ask questions about it.

        For initial analysis: provide a clear, useful summary of what's in the capture.

        For follow-up questions: use your general knowledge to help the user. The captured content \
        is context, not a constraint. If they ask about related topics not visible in the capture, \
        answer from your training knowledge while staying helpful.

        Format responses with markdown when helpful (headers, lists, code blocks). Be concise but thorough.
        """
}

// MARK: - OpenAI-specific request types

private struct OARequest: Encodable {
    let model: String
    let maxTokens: Int
    let stream: Bool
    let messages: [OAMessage]

    enum CodingKeys: String, CodingKey {
        case model, stream, messages
        case maxTokens = "max_tokens"
    }
}

private struct OAMessage: Encodable {
    let role: String
    let content: OAContent
}

private enum OAContent: Encodable {
    case text(String)
    case parts([OAPart])

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let s):   try c.encode(s)
        case .parts(let p):  try c.encode(p)
        }
    }
}

/// A single element in a multipart user message content array.
private enum OAPart: Encodable {
    case text(String)
    case imageURL(String)   // full data URI: "data:image/png;base64,..."

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try c.encode("text", forKey: .type)
            try c.encode(s,      forKey: .text)
        case .imageURL(let url):
            try c.encode("image_url",      forKey: .type)
            try c.encode(["url": url],     forKey: .imageURL)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }
}

// MARK: - OpenAI SSE response types

private struct OASSEChunk: Decodable {
    let choices: [OAChoice]
}

private struct OAChoice: Decodable {
    let delta: OADelta
}

private struct OADelta: Decodable {
    let content: String?
}
