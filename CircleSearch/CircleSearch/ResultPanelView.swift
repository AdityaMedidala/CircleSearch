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
        // Collapse OCR by default during onboarding so the provider cards have more room.
        let inOnboarding = model.availableProviderTypes.isEmpty
        _isOCRExpanded = State(initialValue: inOnboarding ? false : model.ocrText.count <= 200)
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            if model.availableProviderTypes.isEmpty {
                ocrSection
                Divider().opacity(0.4)
                onboardingView
                onboardingButtonRow
            } else {
                // Provider chip — only visible when the user has ≥ 2 providers configured.
                if model.availableProviderTypes.count > 1 {
                    providerPickerStrip
                    Divider().opacity(0.3)
                }
                ocrSection
                Divider().opacity(0.4)
                aiSection
                Divider().opacity(0.4)
                buttonRow
                followUpSection
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
                    if model.currentProvider == nil {
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
                            .markdownTheme(.gitHub)
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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
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
