import AppKit
import SwiftUI

// MARK: - ResultPanel

/// NSPanel subclass that allows the panel to become key window so SwiftUI controls
/// (e.g. TextField) inside it can receive keyboard focus, while still using
/// `.nonactivatingPanel` so the panel doesn't steal app activation from the user's work.
private final class ResultPanel: NSPanel {
    override var canBecomeKey: Bool  { true  }
    override var canBecomeMain: Bool { false }
}

// MARK: - ResultPanelModel

/// Observable model that drives the result panel UI.
/// Owned by `ResultPanelController`; cancelled and replaced on each new capture.
@Observable
@MainActor
final class ResultPanelModel {

    // Panel content
    let ocrText:  String
    let image:    CGImage
    let provider: (any AIProvider)?

    // AI streaming state — observed by ResultPanelView
    var aiResponse  = ""
    var isStreaming  = false
    var streamError: String?

    // Follow-up conversation history (assistant + user turns after initial analysis).
    // Does NOT include the initial image turn; that is always reconstructed from `image`/`ocrText`.
    private var chatHistory: [ChatTurn] = []

    private var streamTask: Task<Void, Never>?

    init(ocrText: String, image: CGImage, provider: (any AIProvider)?) {
        self.ocrText   = ocrText
        self.image     = image
        self.provider  = provider
    }

    // MARK: Actions

    func startInitialAnalysis() {
        guard provider != nil else { return }
        chatHistory = []
        runStream()
    }

    func submitFollowUp(text: String) {
        guard provider != nil else { return }
        // Append the previous assistant turn before adding the new user message.
        if !aiResponse.isEmpty {
            chatHistory.append(ChatTurn(role: .assistant, content: aiResponse, image: nil))
        }
        chatHistory.append(ChatTurn(role: .user, content: text, image: nil))
        aiResponse = ""
        runStream()
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: Private

    private func runStream() {
        guard let provider else { return }
        streamTask?.cancel()
        isStreaming = true
        streamError = nil

        // Capture history snapshot so the task closure is isolated.
        let historyCopy = chatHistory

        streamTask = Task {
            defer { isStreaming = false }
            do {
                var buffer     = ""
                var tokenCount = 0
                var lastFlush  = Date()

                for try await token in provider.stream(image: image, ocrText: ocrText, history: historyCopy) {
                    guard !Task.isCancelled else { break }
                    buffer     += token
                    tokenCount += 1
                    let now = Date()
                    // Flush every 5 tokens or 50 ms, whichever comes first.
                    if tokenCount >= 5 || now.timeIntervalSince(lastFlush) >= 0.05 {
                        aiResponse += buffer
                        buffer      = ""
                        tokenCount  = 0
                        lastFlush   = now
                    }
                }
                if !buffer.isEmpty { aiResponse += buffer }
            } catch is CancellationError {
                // Silently cancelled — e.g. new capture or panel dismissed.
            } catch {
                streamError = error.localizedDescription
            }
        }
    }
}

// MARK: - ResultPanelController

/// Manages the lifecycle of the frosted-glass result NSPanel:
/// creation, positioning, animation, and event monitors.
@MainActor
final class ResultPanelController: NSObject {

    static let shared = ResultPanelController()

    private var panel: NSPanel?
    private var model: ResultPanelModel?
    private var globalClickMonitor: Any?
    private var localKeyMonitor:    Any?

    // MARK: Public

    func show(image: CGImage, ocrText: String, near selectionRect: NSRect) {
        dismiss()

        // Resolve the default provider from AppStorage, falling back to Anthropic.
        let defaultType = ProviderType(
            rawValue: UserDefaults.standard.string(forKey: "defaultProvider") ?? "anthropic"
        ) ?? .anthropic

        let apiKey = KeychainManager.load(for: defaultType)
        NSLog("CircleSearch: ResultPanelController.show — provider=%@ key=%@",
              defaultType.rawValue,
              apiKey == nil ? "nil" : "loaded \(apiKey!.count) chars")

        // Per-provider model key, with a fallback to the legacy "selectedModel" key for Anthropic.
        let perProviderKey = "selectedModel_\(defaultType.rawValue)"
        let modelID = UserDefaults.standard.string(forKey: perProviderKey)
            ?? (defaultType == .anthropic ? UserDefaults.standard.string(forKey: "selectedModel") : nil)
            ?? defaultType.defaultModel

        let provider: (any AIProvider)? = apiKey.flatMap { key in
            makeProvider(type: defaultType, apiKey: key, model: modelID)
        }

        let newModel = ResultPanelModel(ocrText: ocrText, image: image, provider: provider)
        model = newModel

        // Build the visual hierarchy.
        let panelView = ResultPanelView(
            model:        newModel,
            onDismiss:    { [weak self] in self?.dismiss() },
            onNewCapture: { [weak self] in
                self?.dismiss()
                OverlayWindowController.shared.showOverlay()
            }
        )

        let effectView = makeEffectView()
        let hosting    = NSHostingView(rootView: panelView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: effectView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
        ])

        let newPanel = makePanel()
        newPanel.contentView = effectView
        newPanel.setContentSize(NSSize(width: 440, height: 400))

        position(newPanel, near: selectionRect)

        // Fade in — scale is handled inside ResultPanelView via .scaleEffect onAppear.
        newPanel.alphaValue = 0
        newPanel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration        = 0.15
            ctx.timingFunction  = CAMediaTimingFunction(name: .easeOut)
            newPanel.animator().alphaValue = 1
        }

        panel = newPanel
        installMonitors()
        newModel.startInitialAnalysis()
    }

    func dismiss() {
        removeMonitors()
        model?.cancel()
        model = nil
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: Private — provider factory

    private func makeProvider(type: ProviderType, apiKey: String, model: String) -> (any AIProvider)? {
        switch type {
        case .anthropic: return AnthropicProvider(apiKey: apiKey, model: model)
        case .openai:    return OpenAIProvider(apiKey: apiKey, model: model)
        case .google:    return GoogleProvider(apiKey: apiKey, model: model)
        }
    }

    // MARK: Private — panel construction

    private func makePanel() -> NSPanel {
        let p = ResultPanel(
            contentRect: .zero,
            styleMask:   [.nonactivatingPanel, .borderless],
            backing:     .buffered,
            defer:       false
        )
        p.backgroundColor             = .clear
        p.isOpaque                    = false
        p.hasShadow                   = true
        p.isFloatingPanel             = true
        p.level                       = .floating
        p.isReleasedWhenClosed        = false
        p.isMovableByWindowBackground = true
        p.becomesKeyOnlyIfNeeded      = true
        p.collectionBehavior          = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return p
    }

    private func makeEffectView() -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material      = .hudWindow
        v.blendingMode  = .behindWindow
        v.state         = .active
        v.wantsLayer    = true
        v.layer?.cornerRadius  = 14
        v.layer?.masksToBounds = true
        return v
    }

    // MARK: Private — positioning

    private func position(_ panel: NSPanel, near rect: NSRect) {
        let size    = panel.frame.size
        let margin  = CGFloat(12)
        let screen  = NSScreen.screens.first { $0.frame.contains(rect) }
                   ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame

        var origin = NSPoint(
            x: rect.midX - size.width / 2,
            y: rect.minY - size.height - margin
        )
        if origin.y < visible.minY { origin.y = rect.maxY + margin }
        origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
        panel.setFrameOrigin(origin)
    }

    // MARK: Private — event monitors

    private func installMonitors() {
        // Global left-click outside any visible app window → dismiss.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self else { return }
            let loc = NSEvent.mouseLocation
            let insideApp = NSApp.windows.contains { $0.isVisible && $0.frame.contains(loc) }
            if !insideApp {
                Task { @MainActor in self.dismiss() }
            }
        }
        // Local key monitor: Escape → dismiss; Cmd+C → copy AI response if non-empty.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in self?.dismiss() }
                return nil
            }
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "c" {
                let response = MainActor.assumeIsolated { self?.model?.aiResponse ?? "" }
                if !response.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(response, forType: .string)
                    NotificationCenter.default.post(name: .aiResponseCopied, object: nil)
                    return nil
                }
            }
            return event
        }
    }

    private func removeMonitors() {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        if let m = localKeyMonitor    { NSEvent.removeMonitor(m); localKeyMonitor    = nil }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let aiResponseCopied = Notification.Name("CircleSearch.aiResponseCopied")
}
