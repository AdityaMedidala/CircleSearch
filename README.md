# CircleSearch

Circle to Search for macOS. Open source. OCR + multimodal AI on any screen region.

Press `Cmd+Shift+Space`, drag a rectangle around anything on your screen, and get:
- Instant OCR via Apple's Vision framework (on-device, free, private)
- Vision-based AI analysis via Claude (BYOK)

## Status

🚧 Active development. MVP working. Multi-provider support (OpenAI, Gemini) and polish coming next.

## Setup

1. Clone, open in Xcode 16+
2. Build & run (macOS 14+)
3. Grant Screen Recording permission when prompted
4. Settings → API → paste your Anthropic API key from console.anthropic.com

## Tech

Swift, SwiftUI, ScreenCaptureKit, Vision, Anthropic Messages API with SSE streaming.

## License

MIT
