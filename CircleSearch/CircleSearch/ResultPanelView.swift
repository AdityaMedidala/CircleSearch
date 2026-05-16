import SwiftUI
import MarkdownUI

/// SwiftUI content view rendered inside the frosted-glass result NSPanel.
struct ResultPanelView: View {

    let model:        ResultPanelModel
    let onDismiss:    () -> Void
    let onNewCapture: () -> Void

    // MARK: Local UI state

    @State private var appeared       = false
    @State private var isOCRExpanded: Bool          // initialized in init based on OCR length
    @State private var followUpText   = ""
    @State private var copyTextLabel  = "Copy Text"
    @State private var copyAILabel    = "Copy AI"
    @FocusState private var followUpFocused: Bool

    // MARK: Init

    init(model: ResultPanelModel, onDismiss: @escaping () -> Void, onNewCapture: @escaping () -> Void) {
        self.model        = model
        self.onDismiss    = onDismiss
        self.onNewCapture = onNewCapture
        // Auto-expand OCR section for short captures (≤ 200 chars).
        _isOCRExpanded = State(initialValue: model.ocrText.count <= 200)
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            ocrSection
            Divider().opacity(0.4)
            aiSection
            Divider().opacity(0.4)
            buttonRow
            followUpSection
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
                    if model.client == nil {
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
            Text("Connect to Claude for AI analysis.")
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
            // Copy OCR text
            Button(copyTextLabel) { copyText() }
                .buttonStyle(.bordered)
                .controlSize(.small)

            // Copy AI response
            Button(copyAILabel) { copyAI() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.aiResponse.isEmpty)

            // Search Google (searches OCR text)
            Button {
                searchGoogle()
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .disabled(model.ocrText.isEmpty)

            Spacer()

            // New capture
            Button {
                onNewCapture()
            } label: {
                Image(systemName: "viewfinder.circle")
            }
            .buttonStyle(.borderless)
            .font(.title3)
            .help("New capture (⌘⇧Space)")

            // Dismiss
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
                .disabled(model.client == nil || model.isStreaming)
            Button("Send") { submitFollowUp() }
                .disabled(followUpText.trimmingCharacters(in: .whitespaces).isEmpty
                          || model.client == nil || model.isStreaming)
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
}
