<div align="center">

# CircleSearch

**Drag a box around anything on your Mac's screen. Get instant AI analysis.**

[![macOS](https://img.shields.io/badge/macOS-14%2B-000000?style=flat&logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.0-FA7343?style=flat&logo=swift&logoColor=white)](https://swift.org)
[![License](https://img.shields.io/github/license/AdityaMedidala/CircleSearch?style=flat&color=4c1)](LICENSE)
[![Stars](https://img.shields.io/github/stars/AdityaMedidala/CircleSearch?style=flat&logo=github)](https://github.com/AdityaMedidala/CircleSearch/stargazers)
[![Issues](https://img.shields.io/github/issues/AdityaMedidala/CircleSearch?style=flat&color=blue)](https://github.com/AdityaMedidala/CircleSearch/issues)
[![Last commit](https://img.shields.io/github/last-commit/AdityaMedidala/CircleSearch?style=flat&color=informational)](https://github.com/AdityaMedidala/CircleSearch/commits/main)

![Demo](docs/screenshots/hero-demo.gif)

</div>

---

Press `⌘⇧Space`, drag a rectangle around anything — an article, a chart, code, a foreign menu — and get an instant analysis from Claude, ChatGPT, or Gemini. OCR is on-device. Your API keys never leave your Mac.

## ✨ Features

- 🔍 **Region capture from any app** with a global hotkey
- 📝 **On-device OCR** via Apple Vision — instant, private, free
- 🤖 **Three AI providers** — Claude, ChatGPT, Gemini (bring your own key)
- 🔄 **Switch providers mid-conversation** to compare answers
- 💬 **Follow-up questions** that keep the image in context
- 🕐 **Searchable history** of your last 50 captures
- 🌗 **Light + dark mode**, frosted-glass panels, menu bar agent

## 📥 Install

```bash
git clone https://github.com/AdityaMedidala/CircleSearch.git
cd CircleSearch
open CircleSearch/CircleSearch.xcodeproj
```

In Xcode: set signing to your personal Apple ID, then `⌘R`. Grant Screen Recording when prompted.

> **Requires:** macOS 14+, Xcode 16+, an API key for at least one provider.

## 🔑 Get an API key

| Provider | Get a key | Best for |
|---|---|---|
| **Claude** | [console.anthropic.com](https://console.anthropic.com) | Careful reasoning |
| **ChatGPT** | [platform.openai.com](https://platform.openai.com/api-keys) | Speed + cost |
| **Gemini** | [aistudio.google.com](https://aistudio.google.com/apikey) | Free tier |

Paste your key into the onboarding screen on first launch. Keys are stored in macOS Keychain.

## 🚀 Usage

| Action | Shortcut |
|---|---|
| Capture region | `⌘⇧Space` |
| Copy AI response | `⌘C` (with panel focused) |
| Close panel | `Esc` or click ✕ |
| Open history | Click menu bar icon |

## 🔒 Privacy

No backend. No telemetry. No accounts. Captures go directly from your Mac to the AI provider you've selected — same as if you opened their app yourself. Keys live in your Keychain. History lives on your disk.

## 🛠 Tech

Swift 6, SwiftUI, ScreenCaptureKit, Apple Vision, SSE streaming. Protocol-based provider abstraction means adding a new AI provider is a single ~250-line file.

## 📋 Status

Active development. Working: capture, OCR, three providers, streaming, history, onboarding. [Open issues](https://github.com/AdityaMedidala/CircleSearch/issues) welcome.

## 📄 License

[MIT](LICENSE)

---

<div align="center">
<sub>Built by <a href="https://github.com/AdityaMedidala">Aditya Medidala</a> · Pair-programmed with <a href="https://claude.com/product/claude-code">Claude Code</a></sub>
</div>