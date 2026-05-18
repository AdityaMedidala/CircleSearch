import AppKit
import Foundation

// MARK: - AnthropicProvider

struct AnthropicProvider: AIProvider {

    // MARK: Static metadata

    static let providerType:    ProviderType = .anthropic
    static let displayName                   = "Anthropic Claude"
    static let keychainAccount               = "anthropic-api-key"
    static let consoleURL                    = URL(string: "https://console.anthropic.com/")!
    static let models: [(id: String, label: String)] = [
        ("claude-sonnet-4-6",        "claude-sonnet-4-6 (default)"),
        ("claude-haiku-4-5-20251001", "claude-haiku-4-5-20251001 (faster)"),
        ("claude-opus-4-7",           "claude-opus-4-7 (most capable)"),
    ]
    static let defaultModel = "claude-sonnet-4-6"

    // MARK: Instance

    let providerKind: ProviderType = .anthropic
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
                        NSLog("CircleSearch: AnthropicProvider — HTTP %d", http.statusCode)
                        if http.statusCode != 200 {
                            var body = Data()
                            for try await byte in bytes { body.append(byte) }
                            NSLog("CircleSearch: AnthropicProvider — error body: %@",
                                  String(data: body, encoding: .utf8) ?? "(non-UTF8)")
                            continuation.finish(throwing: ProviderError.httpError(http.statusCode))
                            return
                        }
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))

                        if let data  = payload.data(using: .utf8),
                           let event = try? JSONDecoder().decode(ASSEEvent.self, from: data),
                           event.type == "message_stop" {
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

    private func buildMessages(image: CGImage, ocrText: String, history: [ChatTurn]) throws -> [AMessage] {
        // Turn 1 always contains the image so the model has visual context for every turn.
        // The closing instruction differs: on initial analysis ask for a summary; on follow-ups
        // just mark it as reference context so the model doesn't re-summarise unprompted.
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

        let b64 = try pngBase64(from: image)
        var messages: [AMessage] = [
            AMessage(role: "user", content: .blocks([
                ABlock.image(mediaType: "image/png", base64Data: b64),
                ABlock.text(promptText),
            ]))
        ]

        // Append follow-up turns verbatim (no image re-encoding needed).
        for turn in history {
            messages.append(AMessage(
                role:    turn.role == .user ? "user" : "assistant",
                content: .text(turn.content)
            ))
        }
        return messages
    }

    // MARK: Private — request building

    private func buildRequest(messages: [AMessage]) throws -> URLRequest {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw ProviderError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey,             forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",       forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONEncoder().encode(
            ARequest(model: model, maxTokens: 1024, stream: true,
                     system: Self.systemPrompt, messages: messages)
        )
        return req
    }

    // MARK: Private — SSE parsing

    private func textDelta(from json: String) -> String? {
        guard
            let data  = json.data(using: .utf8),
            let event = try? JSONDecoder().decode(ASSEEvent.self, from: data),
            event.type == "content_block_delta",
            let delta = event.delta,
            delta.type == "text_delta",
            let text  = delta.text
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

// MARK: - Anthropic-specific request types

private struct ARequest: Encodable {
    let model: String
    let maxTokens: Int
    let stream: Bool
    let system: String
    let messages: [AMessage]

    enum CodingKeys: String, CodingKey {
        case model, stream, system, messages
        case maxTokens = "max_tokens"
    }
}

private struct AMessage: Encodable {
    let role: String
    let content: AContent
}

private enum AContent: Encodable {
    case text(String)
    case blocks([ABlock])

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let s):   try c.encode(s)
        case .blocks(let b): try c.encode(b)
        }
    }
}

private struct ABlock: Encodable {
    let type: String
    let text: String?
    let source: AImageSource?

    static func text(_ text: String) -> ABlock {
        ABlock(type: "text", text: text, source: nil)
    }

    static func image(mediaType: String, base64Data: String) -> ABlock {
        ABlock(type: "image", text: nil,
               source: AImageSource(type: "base64", mediaType: mediaType, data: base64Data))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        if let text   { try c.encode(text,   forKey: .text) }
        if let source { try c.encode(source, forKey: .source) }
    }

    private enum CodingKeys: String, CodingKey { case type, text, source }
}

private struct AImageSource: Encodable {
    let type: String
    let mediaType: String
    let data: String

    enum CodingKeys: String, CodingKey {
        case type, data
        case mediaType = "media_type"
    }
}

// MARK: - Anthropic SSE types

private struct ASSEEvent: Decodable {
    let type: String
    let index: Int?
    let delta: ASSEDelta?
}

private struct ASSEDelta: Decodable {
    let type: String
    let text: String?
}
