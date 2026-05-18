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

    // Panel content — fixed for the lifetime of this capture session.
    let ocrText: String
    let image:   CGImage

    /// All provider types that had a saved API key when this capture was taken.
    /// Used by the picker to enumerate what the user can switch to.
    /// Grows when the user activates a provider via the in-panel onboarding cards.
    private(set) var availableProviderTypes: [ProviderType]

    /// The provider currently generating responses. Changes when the user switches providers.
    private(set) var currentProvider: (any AIProvider)?

    // AI streaming state — observed by ResultPanelView
    var aiResponse  = ""
    var isStreaming  = false
    var streamError: String?

    /// True when the model is displaying a historical capture rather than a live session.
    /// In this state streaming is disabled and follow-up is hidden.
    let isReadOnly: Bool

    // Follow-up conversation history (assistant + user turns after initial analysis).
    // Does NOT include the initial image turn; always reconstructed from image/ocrText.
    private var chatHistory: [ChatTurn] = []
    private var streamTask: Task<Void, Never>?

    init(ocrText: String, image: CGImage,
         provider: (any AIProvider)?, availableProviderTypes: [ProviderType]) {
        self.ocrText                = ocrText
        self.image                  = image
        self.currentProvider        = provider
        self.availableProviderTypes = availableProviderTypes
        self.isReadOnly             = false
    }

    /// Initialises a read-only model for replaying a historical capture.
    init(ocrText: String, image: CGImage, aiResponse: String) {
        self.ocrText                = ocrText
        self.image                  = image
        self.currentProvider        = nil
        self.availableProviderTypes = []
        self.aiResponse             = aiResponse
        self.isReadOnly             = true
    }

    // MARK: Actions

    func startInitialAnalysis() {
        guard currentProvider != nil else { return }
        chatHistory = []
        runStream()
    }

    func submitFollowUp(text: String) {
        guard currentProvider != nil else { return }
        if !aiResponse.isEmpty {
            chatHistory.append(ChatTurn(role: .assistant, content: aiResponse, image: nil))
        }
        chatHistory.append(ChatTurn(role: .user, content: text, image: nil))
        aiResponse = ""
        runStream()
    }

    /// Switches to a different provider mid-session.
    /// Cancels any active stream, clears history + response, and re-runs the initial analysis
    /// so the user immediately sees the new provider's take on the same captured image.
    func switchProvider(to providerType: ProviderType) {
        // No-op if already using this provider.
        guard currentProvider?.providerKind != providerType else { return }

        guard let apiKey = KeychainManager.load(for: providerType) else { return }
        let modelKey = "selectedModel_\(providerType.rawValue)"
        let modelID  = UserDefaults.standard.string(forKey: modelKey) ?? providerType.defaultModel

        streamTask?.cancel()
        streamTask      = nil
        chatHistory     = []
        aiResponse      = ""
        streamError     = nil
        currentProvider = makeProvider(providerType, apiKey: apiKey, model: modelID)
        if !availableProviderTypes.contains(providerType) {
            availableProviderTypes.append(providerType)
        }
        startInitialAnalysis()
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: Private

    private func runStream() {
        guard let provider = currentProvider else { return }
        streamTask?.cancel()
        isStreaming = true
        streamError = nil

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
                    if tokenCount >= 5 || now.timeIntervalSince(lastFlush) >= 0.05 {
                        aiResponse += buffer
                        buffer      = ""
                        tokenCount  = 0
                        lastFlush   = now
                    }
                }
                if !buffer.isEmpty { aiResponse += buffer }

                // Persist the initial analysis to history after a clean stream completion.
                // Skip follow-up turns (historyCopy non-empty) and cancelled/errored runs.
                if !Task.isCancelled && historyCopy.isEmpty {
                    let img  = image
                    let ocr  = ocrText
                    let ai   = aiResponse
                    let kind = provider.providerKind
                    let mdl  = provider.model
                    Task.detached(priority: .background) {
                        try? HistoryManager.save(image: img, ocrText: ocr,
                                                 aiResponse: ai, providerType: kind, model: mdl)
                        HistoryManager.prune()
                    }
                }
            } catch is CancellationError {
                // Silently cancelled — e.g. provider switch, new capture, or panel dismissed.
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
    private var localKeyMonitor: Any?

    // MARK: Public

    func show(image: CGImage, ocrText: String, near selectionRect: NSRect) {
        dismiss()

        // All provider types that currently have a saved key — used for the picker.
        let availableTypes = ProviderType.allCases.filter {
            KeychainManager.load(for: $0) != nil
        }

        // Resolve the default provider from AppStorage, falling back to Anthropic.
        let defaultType = ProviderType(
            rawValue: UserDefaults.standard.string(forKey: "defaultProvider") ?? "anthropic"
        ) ?? .anthropic

        let apiKey = KeychainManager.load(for: defaultType)
        NSLog("CircleSearch: ResultPanelController.show — provider=%@ key=%@ available=%@",
              defaultType.rawValue,
              apiKey == nil ? "nil" : "loaded \(apiKey!.count) chars",
              availableTypes.map(\.rawValue).joined(separator: ","))

        let perProviderKey = "selectedModel_\(defaultType.rawValue)"
        let modelID = UserDefaults.standard.string(forKey: perProviderKey)
            ?? (defaultType == .anthropic
                    ? UserDefaults.standard.string(forKey: "selectedModel") : nil)
            ?? defaultType.defaultModel

        let activeProvider: (any AIProvider)? = apiKey.map {
            makeProvider(defaultType, apiKey: $0, model: modelID)
        }

        let newModel = ResultPanelModel(
            ocrText:                ocrText,
            image:                  image,
            provider:               activeProvider,
            availableProviderTypes: availableTypes
        )
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

        newPanel.alphaValue = 0
        newPanel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration       = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            newPanel.animator().alphaValue = 1
        }

        panel = newPanel
        installMonitors()
        newModel.startInitialAnalysis()
    }

    /// Reopens a historical capture in read-only mode (no streaming, no follow-up).
    func showFromHistory(entry: CaptureEntry) {
        // Load the full-resolution image first (synchronous, local file, typically < 100 ms).
        guard let cgImage = entry.image else {
            NSLog("CircleSearch: showFromHistory — could not load image for %@",
                  entry.id.uuidString)
            return
        }
        dismiss()

        let historyModel = ResultPanelModel(
            ocrText:    entry.ocrText,
            image:      cgImage,
            aiResponse: entry.aiResponse
        )
        model = historyModel

        let panelView = ResultPanelView(
            model:        historyModel,
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
        positionAtScreenCenter(newPanel)

        newPanel.alphaValue = 0
        newPanel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration       = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            newPanel.animator().alphaValue = 1
        }

        panel = newPanel
        installMonitors()
        // No startInitialAnalysis() — read-only model is pre-populated.
    }

    func dismiss() {
        removeMonitors()
        model?.cancel()
        model = nil
        panel?.orderOut(nil)
        panel = nil
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

    private func positionAtScreenCenter(_ panel: NSPanel) {
        let size   = panel.frame.size
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vis    = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: vis.midX - size.width  / 2,
            y: vis.midY - size.height / 2 + 50
        ))
    }

    // MARK: Private — event monitors

    private func installMonitors() {
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
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let aiResponseCopied = Notification.Name("CircleSearch.aiResponseCopied")
}
