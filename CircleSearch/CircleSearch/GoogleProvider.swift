import AppKit
import Foundation

// MARK: - GoogleProvider

struct GoogleProvider: AIProvider {

    // MARK: Static metadata

    static let providerType:    ProviderType = .google
    static let displayName                   = "Google Gemini"
    static let keychainAccount               = "google-api-key"
    static let consoleURL                    = URL(string: "https://aistudio.google.com/app/apikey")!
    static let models: [(id: String, label: String)] = [
        ("gemini-2.0-flash", "gemini-2.0-flash (default)"),
        ("gemini-2.5-pro",   "gemini-2.5-pro (most capable)"),
    ]
    static let defaultModel = "gemini-2.0-flash"

    // MARK: Instance

    let providerKind: ProviderType = .google
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
                    let body    = try buildBody(image: image, ocrText: ocrText, history: history)
                    let request = try buildRequest(body: body)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let http = response as? HTTPURLResponse {
                        NSLog("CircleSearch: GoogleProvider — HTTP %d", http.statusCode)
                        if http.statusCode != 200 {
                            var rawBody = Data()
                            for try await byte in bytes { rawBody.append(byte) }
                            let msg = decodeErrorMessage(from: rawBody)
                            NSLog("CircleSearch: GoogleProvider — error: %@", msg)
                            continuation.finish(throwing: ProviderError.apiError(msg))
                            return
                        }
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))

                        guard let data  = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(GSSEChunk.self, from: data)
                        else { continue }

                        // Yield text delta when present.
                        if let text = chunk.candidates?.first?.content?.parts?.first?.text,
                           !text.isEmpty {
                            continuation.yield(text)
                        }

                        // A non-empty, non-unspecified finishReason means the stream is done.
                        if let reason = chunk.candidates?.first?.finishReason,
                           !reason.isEmpty, reason != "FINISH_REASON_UNSPECIFIED" {
                            continuation.finish()
                            return
                        }
                    }
                    // Stream closed naturally (Gemini doesn't always send [DONE]).
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: Private — body building

    private func buildBody(image: CGImage, ocrText: String, history: [ChatTurn]) throws -> GRequest {
        let promptText: String
        if ocrText.isEmpty {
            promptText = "Please analyze the captured content above."
        } else {
            promptText = """
            Here is text extracted from the screen capture via OCR (use this to verify exact \
            wording, codes, or details that may be unclear in the image):
            \(ocrText)

            Please analyze the captured content above.
            """
        }

        let b64 = try pngBase64(from: image)

        // First turn: image as inline_data + prompt text.
        var contents: [GTurn] = [
            GTurn(role: "user", parts: [
                GPart.inlineData(mimeType: "image/png", data: b64),
                GPart.text(promptText),
            ])
        ]

        // Follow-up turns: Gemini uses "model" for the assistant role (not "assistant").
        for turn in history {
            contents.append(GTurn(
                role:  turn.role == .user ? "user" : "model",
                parts: [GPart.text(turn.content)]
            ))
        }

        return GRequest(
            systemInstruction: GSystemInstruction(
                parts: [GPart.text(Self.systemPrompt)]
            ),
            contents: contents,
            generationConfig: GGenerationConfig(maxOutputTokens: 1024)
        )
    }

    // MARK: Private — request building

    private func buildRequest(body: GRequest) throws -> URLRequest {
        // API key goes as a query parameter; do NOT send it as a header.
        let path = "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent"
        guard var components = URLComponents(string: path) else {
            throw ProviderError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "alt", value: "sse"),    // mandatory — without this, response is buffered
            URLQueryItem(name: "key", value: apiKey),
        ]
        guard let url = components.url else {
            throw ProviderError.invalidURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        return req
    }

    // MARK: Private — error decoding

    /// Gemini error body: {"error":{"code":403,"message":"...","status":"PERMISSION_DENIED"}}
    private func decodeErrorMessage(from data: Data) -> String {
        struct GErrorEnvelope: Decodable {
            struct GError: Decodable { let code: Int; let message: String }
            let error: GError
        }
        if let env = try? JSONDecoder().decode(GErrorEnvelope.self, from: data) {
            return "Gemini error \(env.error.code): \(env.error.message)"
        }
        return String(data: data, encoding: .utf8) ?? "(non-UTF8 error body)"
    }

    // MARK: System prompt

    private static let systemPrompt = """
        You are CircleSearch, a visual assistant. The user captured a region of their screen. \
        Analyze what they captured and provide the most useful response — explain code, summarize \
        text, translate, solve math, identify UIs, answer questions about charts or images. Be \
        concise. If the content is code, identify the language and explain or fix as appropriate. \
        If it's an error message, diagnose it and suggest a fix. If it's a chart or diagram, \
        explain what it shows. If it's a UI mockup, describe the design and propose how to build \
        it. Default to a 2-4 sentence response unless the user asks for more.
        """
}

// MARK: - Gemini request types

private struct GRequest: Encodable {
    let systemInstruction: GSystemInstruction
    let contents: [GTurn]
    let generationConfig: GGenerationConfig

    enum CodingKeys: String, CodingKey {
        case systemInstruction = "system_instruction"
        case contents
        case generationConfig
    }
}

private struct GSystemInstruction: Encodable {
    let parts: [GPart]
}

private struct GTurn: Encodable {
    let role: String
    let parts: [GPart]
}

/// A single part inside a Gemini turn — either plain text or an inline image.
private enum GPart: Encodable {
    case text(String)
    case inlineData(mimeType: String, data: String)

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try c.encode(s, forKey: .text)
        case .inlineData(let mimeType, let data):
            try c.encode(GInlineData(mimeType: mimeType, data: data), forKey: .inlineData)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case inlineData = "inline_data"
    }
}

private struct GInlineData: Encodable {
    let mimeType: String
    let data: String

    enum CodingKeys: String, CodingKey {
        case mimeType = "mime_type"
        case data
    }
}

private struct GGenerationConfig: Encodable {
    let maxOutputTokens: Int
}

// MARK: - Gemini SSE response types

private struct GSSEChunk: Decodable {
    let candidates: [GCandidate]?
}

private struct GCandidate: Decodable {
    let content: GCandidateContent?
    let finishReason: String?
}

private struct GCandidateContent: Decodable {
    let parts: [GCandidatePart]?
}

private struct GCandidatePart: Decodable {
    let text: String?
}
