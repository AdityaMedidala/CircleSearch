import SwiftUI
import MarkdownUI

/// SwiftUI content view rendered inside the frosted-glass result NSPanel.
struct ResultPanelView: View {

    let model:        ResultPanelModel
    let onDismiss:    () -> Void
    let onNewCapture: () -> Void

    // MARK: Local UI state

    @State private var appeared       = false
    @State private var isOCRExpanded: Bool
    @State private var followUpText   = ""
    @State private var copyTextLabel  = "Copy Text"
    @State private var copyAILabel    = "Copy AI"
    @FocusState private var followUpFocused: Bool

    // MARK: Init

    init(model: ResultPanelModel, onDismiss: @escaping () -> Void, onNewCapture: @escaping () -> Void) {
        self.model        = model
        self.onDismiss    = onDismiss
        self.onNewCapture = onNewCapture
        // Collapse OCR during onboarding only (provider cards need room).
        // Read-only history views use the normal expand-if-short logic.
        let inOnboarding = model.availableProviderTypes.isEmpty && !model.isReadOnly
        _isOCRExpanded = State(initialValue: inOnboarding ? false : model.ocrText.count <= 200)
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            if model.availableProviderTypes.isEmpty && !model.isReadOnly {
                // Onboarding — no API keys configured yet.
                ocrSection
                Divider().opacity(0.4)
                onboardingView
                onboardingButtonRow
            } else {
                // Normal capture or read-only history replay.
                if !model.isReadOnly && model.availableProviderTypes.count > 1 {
                    providerPickerStrip
                    Divider().opacity(0.3)
                }
                ocrSection
                Divider().opacity(0.4)
                if model.isReadOnly {
                    readOnlyBadge
                    Divider().opacity(0.3)
                }
                aiSection
                Divider().opacity(0.4)
                buttonRow
                if model.isReadOnly {
                    readOnlyFollowUpPlaceholder
                } else {
                    followUpSection
                }
            }
        }
        .frame(width: 440)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.85))
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.95, anchor: .top)
        .animation(.easeOut(duration: 0.15), value: appeared)
        .onAppear { appeared = true }
        .onChange(of: model.isStreaming) { wasStreaming, isStreaming in
            if wasStreaming && !isStreaming {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .aiResponseCopied)) { _ in
            copyAILabel = "Copied!"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copyAILabel = "Copy AI" }
        }
    }

    // MARK: Onboarding view

    private var onboardingView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to CircleSearch")
                        .font(.headline)
                    Text("Add an API key for any provider to start analyzing your captures with AI.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                ForEach(ProviderType.allCases, id: \.self) { providerType in
                    ProviderOnboardingCard(providerType: providerType) { apiKey in
                        activateProvider(providerType, apiKey: apiKey)
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .frame(minHeight: 80, maxHeight: 360)
    }

    private var onboardingButtonRow: some View {
        HStack {
            Spacer()
            Button {
                onNewCapture()
            } label: {
                Image(systemName: "viewfinder.circle")
            }
            .buttonStyle(.borderless)
            .font(.title3)
            .help("New capture (⌘⇧Space)")

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .font(.title3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func activateProvider(_ providerType: ProviderType, apiKey: String) {
        try? KeychainManager.save(apiKey, for: providerType)
        UserDefaults.standard.set(providerType.rawValue, forKey: "defaultProvider")
        model.switchProvider(to: providerType)
    }

    // MARK: Provider picker strip

    /// Thin top-right row showing the active provider with a compact Menu to switch.
    private var providerPickerStrip: some View {
        HStack {
            Spacer()
            providerPicker
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var providerPicker: some View {
        let currentKind = model.currentProvider?.providerKind
        let others = model.availableProviderTypes.filter { $0 != currentKind }

        return Menu {
            ForEach(others, id: \.self) { providerType in
                Button(shortProviderLabel(providerType)) {
                    model.switchProvider(to: providerType)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(currentKind.map(shortProviderLabel) ?? "—")
                    .font(.caption.weight(.medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.secondary.opacity(0.12))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: OCR section

    private var ocrSection: some View {
        DisclosureGroup(isExpanded: $isOCRExpanded) {
            Text(model.ocrText.isEmpty ? "No text found." : model.ocrText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                .padding(.horizontal, 4)
        } label: {
            Label("Extracted Text", systemImage: "text.alignleft")
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(.easeInOut(duration: 0.2), value: isOCRExpanded)
    }

    // MARK: AI section

    @ViewBuilder
    private var aiSection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if !model.isReadOnly && model.currentProvider == nil {
                        noKeyPlaceholder
                    } else if let err = model.streamError {
                        errorView(err)
                    } else if model.aiResponse.isEmpty && model.isStreaming {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Analyzing…")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    } else {
                        Markdown(model.aiResponse.isEmpty ? "\u{200B}" : model.aiResponse)
                            .markdownTheme(.circleSearch)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .id("aiBottom")
                    }
                }
            }
            .frame(minHeight: 80, maxHeight: 240)
            .onChange(of: model.aiResponse) { _, _ in
                withAnimation { proxy.scrollTo("aiBottom", anchor: .bottom) }
            }
        }
    }

    private var noKeyPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "key.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Add an API key in Settings to enable AI analysis.")
                .foregroundStyle(.secondary)
                .font(.callout)
            Button("Open Settings") {
                SettingsWindowController.shared.show()
            }
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private func errorView(_ message: String) -> some View {
        let providerKind = model.currentProvider?.providerKind
        return StreamErrorView(
            message:         message,
            providerName:    providerKind.map(shortProviderLabel) ?? "AI",
            consoleURL:      providerKind?.consoleURL,
            onRetry:         { model.retryAnalysis() },
            onOpenSettings:  { SettingsWindowController.shared.show() }
        )
    }

    // MARK: Read-only indicators

    private var readOnlyBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption2)
            Text("Viewing past capture")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var readOnlyFollowUpPlaceholder: some View {
        Text("Read-only — capture again to ask follow-ups.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
    }

    // MARK: Button row

    private var buttonRow: some View {
        HStack(spacing: 6) {
            Button(copyTextLabel) { copyText() }
                .buttonStyle(.bordered)
                .controlSize(.small)

            Button(copyAILabel) { copyAI() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.aiResponse.isEmpty)

            Button {
                searchGoogle()
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .disabled(model.ocrText.isEmpty)

            Spacer()

            Button {
                onNewCapture()
            } label: {
                Image(systemName: "viewfinder.circle")
            }
            .buttonStyle(.borderless)
            .font(.title3)
            .help("New capture (⌘⇧Space)")

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .font(.title3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Follow-up section

    private var followUpSection: some View {
        HStack(spacing: 8) {
            TextField("Continue the conversation…", text: $followUpText)
                .textFieldStyle(.roundedBorder)
                .focused($followUpFocused)
                .onSubmit { submitFollowUp() }
                .disabled(model.currentProvider == nil || model.isStreaming)
            Button("Send") { submitFollowUp() }
                .disabled(followUpText.trimmingCharacters(in: .whitespaces).isEmpty
                          || model.currentProvider == nil || model.isStreaming)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    // MARK: Actions

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.ocrText, forType: .string)
        copyTextLabel = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copyTextLabel = "Copy Text" }
    }

    private func copyAI() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.aiResponse, forType: .string)
        copyAILabel = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copyAILabel = "Copy AI" }
    }

    private func searchGoogle() {
        let query = model.ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              let enc = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.google.com/search?q=\(enc)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func submitFollowUp() {
        let text = followUpText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        followUpText = ""
        model.submitFollowUp(text: text)
    }

    // MARK: Helpers

    private func shortProviderLabel(_ type: ProviderType) -> String {
        switch type {
        case .anthropic: return "Claude"
        case .openai:    return "OpenAI"
        case .google:    return "Gemini"
        }
    }
}

// MARK: - StreamErrorView

/// Polished error display with classified error type, tailored copy, and action button.
private struct StreamErrorView: View {
    let message:        String
    let providerName:   String
    let consoleURL:     URL?
    let onRetry:        () -> Void
    let onOpenSettings: () -> Void

    @State private var showDetail = false

    // MARK: Error classification

    private enum ErrorKind {
        case outOfCredits
        case invalidKey
        case networkError
        case unknown(String)
    }

    private var kind: ErrorKind {
        let lower = message.lowercased()
        if lower.contains("credit balance") || lower.contains("exceeded your current quota") ||
           (lower.contains("billing") && lower.contains("error")) {
            return .outOfCredits
        }
        if lower.contains("invalid api key") || lower.contains("access denied") ||
           lower.contains("authentication") {
            return .invalidKey
        }
        if lower.contains("offline") || lower.contains("timed out") ||
           lower.contains("network connection") || lower.contains("internet connection") ||
           lower.contains("connection was lost") {
            return .networkError
        }
        return .unknown(message)
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: iconName)
                    .font(.title3)
                    .foregroundStyle(iconColor)
                    .frame(width: 22, alignment: .center)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            actionButton
                .padding(.leading, 32)   // align under text, not icon

            if case .unknown(let msg) = kind, msg.count > 80 {
                DisclosureGroup("Show details", isExpanded: $showDetail) {
                    Text(msg)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 32)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    // MARK: Derived properties

    private var iconName: String {
        switch kind {
        case .outOfCredits: return "creditcard.trianglebadge.exclamationmark"
        case .invalidKey:   return "key.slash"
        case .networkError: return "wifi.slash"
        case .unknown:      return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch kind {
        case .invalidKey: return .red
        default:          return .orange
        }
    }

    private var title: String {
        switch kind {
        case .outOfCredits: return "Out of \(providerName) credits"
        case .invalidKey:   return "API key issue with \(providerName)"
        case .networkError: return "Connection problem"
        case .unknown:      return "Something went wrong"
        }
    }

    private var subtitle: String {
        switch kind {
        case .outOfCredits: return "Add credits or switch providers using the picker above."
        case .invalidKey:   return "The saved key appears invalid. Update it in Settings."
        case .networkError: return "Check your internet connection and try again."
        case .unknown(let msg):
            return msg.count > 80 ? String(msg.prefix(80)) + "…" : msg
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if case .outOfCredits = kind, let url = consoleURL {
            Link("Get credits →", destination: url)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.purple)
        } else if case .invalidKey = kind {
            Button("Open Settings") { onOpenSettings() }
                .buttonStyle(.link)
                .font(.caption.weight(.medium))
        } else if case .networkError = kind {
            Button("Retry") { onRetry() }
                .buttonStyle(.link)
                .font(.caption.weight(.medium))
        }
    }
}

// MARK: - ProviderOnboardingCard

private struct ProviderOnboardingCard: View {
    let providerType: ProviderType
    let onActivate: (String) -> Void

    @State private var keyText  = ""
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(displayName)
                    .font(.callout.weight(.semibold))
                Spacer()
                Link("Get free API key →", destination: consoleURL)
                    .font(.caption)
            }
            Text(providerDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                SecureField("Paste API key…", text: $keyText)
                    .textFieldStyle(.roundedBorder)
                Button("Save & Activate") {
                    let trimmed = keyText.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    isSaving = true
                    onActivate(trimmed)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }
        }
        .padding(12)
        .background(.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
    }

    private var displayName: String {
        switch providerType {
        case .anthropic: return "Claude (Anthropic)"
        case .openai:    return "GPT (OpenAI)"
        case .google:    return "Gemini (Google)"
        }
    }

    private var providerDescription: String {
        switch providerType {
        case .anthropic: return "Thoughtful analysis with Claude — great for code and detailed explanations."
        case .openai:    return "Versatile GPT models from OpenAI, ideal for diverse tasks."
        case .google:    return "Gemini's fast multimodal understanding from Google."
        }
    }

    private var consoleURL: URL {
        switch providerType {
        case .anthropic: return URL(string: "https://console.anthropic.com/")!
        case .openai:    return URL(string: "https://platform.openai.com/api-keys")!
        case .google:    return URL(string: "https://aistudio.google.com/app/apikey")!
        }
    }
}

// MARK: - Adaptive color helpers (light + dark mode)

/// Dynamic NSColor-backed Colors that adapt to the system appearance.
/// Used by Theme.circleSearch for code blocks so the panel looks right in both modes.
private extension Color {
    /// Code block container background — near-black in dark mode, near-white in light.
    static let codeBlockBackground = Color(NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.10, alpha: 1)
            : NSColor(white: 0.88, alpha: 1)
    })
    /// Code block border — subtle in both modes.
    static let codeBlockBorder = Color(NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.28, alpha: 1)
            : NSColor(white: 0.72, alpha: 1)
    })
    /// Inline code chip background — slightly tinted in both modes.
    static let inlineCodeBackground = Color(NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.16, alpha: 1)
            : NSColor(white: 0.84, alpha: 1)
    })
}

// MARK: - MarkdownUI custom theme

extension Theme {
    /// Dark-panel–friendly theme with adaptive light-mode variants.
    static let circleSearch = Theme()

        // Body text — adaptive primary colour, 14 pt SF Pro.
        .text {
            ForegroundColor(.primary)
            FontSize(14)
        }

        // Links — purple accent, visible in both modes.
        .link {
            ForegroundColor(Color.purple)
        }

        // Inline code chip.
        .code {
            ForegroundColor(.primary)
            BackgroundColor(.inlineCodeBackground)
            FontFamilyVariant(.monospaced)
            FontSize(12)
        }

        // Fenced code block — scrollable, with corner radius and border.
        .codeBlock { config in
            ScrollView(.horizontal, showsIndicators: false) {
                config.label
                    .relativeLineSpacing(.em(0.3))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(13)
                        ForegroundColor(.primary)
                    }
                    .padding(12)
            }
            .background(Color.codeBlockBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.codeBlockBorder, lineWidth: 1)
            )
            .markdownMargin(top: 6, bottom: 6)
        }

        // Blockquote — purple left bar, muted italic text, 8 pt left indent.
        .blockquote { config in
            HStack(spacing: 0) {
                Color.purple.opacity(0.75)
                    .frame(width: 3)
                    .clipShape(Capsule())
                config.label
                    .markdownTextStyle {
                        ForegroundColor(.secondary)
                        FontStyle(.italic)
                    }
                    .padding(.leading, 8)
            }
            .markdownMargin(top: 4, bottom: 4)
        }

        // Headings — bold/semibold with generous top spacing for hierarchy.
        .heading1 { config in
            config.label
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(24)
                    ForegroundColor(.primary)
                }
                .markdownMargin(top: 16, bottom: 6)
        }
        .heading2 { config in
            config.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(20)
                    ForegroundColor(.primary)
                }
                .markdownMargin(top: 16, bottom: 4)
        }
        .heading3 { config in
            config.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(17)
                    ForegroundColor(.primary)
                }
                .markdownMargin(top: 14, bottom: 4)
        }
        .heading4 { config in
            config.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(15)
                    ForegroundColor(.primary)
                }
                .markdownMargin(top: 12, bottom: 4)
        }

        // Horizontal rule — thin separator with vertical breathing room.
        .thematicBreak {
            Divider()
                .padding(.vertical, 8)
        }
}
