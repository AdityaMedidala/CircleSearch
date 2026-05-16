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
    let ocrText: String
    let image: CGImage
    let client: AnthropicClient?

    // AI streaming state — observed by ResultPanelView
    var aiResponse  = ""
    var isStreaming  = false
    var streamError: String?
    private(set) var conversationHistory: [APIMessage] = []

    private var streamTask: Task<Void, Never>?

    init(ocrText: String, image: CGImage, client: AnthropicClient?) {
        self.ocrText = ocrText
        self.image   = image
        self.client  = client
    }

    // MARK: Actions

    func startInitialAnalysis() {
        guard let client else { return }
        do {
            let b64  = try AnthropicClient.pngBase64(from: image)
            let msgs = [APIMessage(
                role: "user",
                content: .blocks([
                    ContentBlock.image(mediaType: "image/png", base64Data: b64),
                    ContentBlock.text("Analyze this screen capture."),
                ])
            )]
            conversationHistory = msgs
            runStream(messages: msgs, client: client)
        } catch {
            streamError = error.localizedDescription
        }
    }

    func submitFollowUp(text: String) {
        guard let client else { return }
        // Append assistant turn, then new user message.
        if !aiResponse.isEmpty {
            conversationHistory.append(
                APIMessage(role: "assistant", content: .text(aiResponse))
            )
        }
        conversationHistory.append(APIMessage(role: "user", content: .text(text)))
        aiResponse = ""
        runStream(messages: conversationHistory, client: client)
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: Private

    private func runStream(messages: [APIMessage], client: AnthropicClient) {
        streamTask?.cancel()
        isStreaming = true
        streamError = nil

        streamTask = Task {
            defer { isStreaming = false }
            do {
                var buffer     = ""
                var tokenCount = 0
                var lastFlush  = Date()

                for try await token in client.stream(messages: messages) {
                    guard !Task.isCancelled else { break }
                    buffer += token
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
    private var localKeyMonitor: Any?

    // MARK: Public

    func show(image: CGImage, ocrText: String, near selectionRect: NSRect) {
        dismiss()

        // Diagnostic: surface Keychain load result and service identity.
        let rawKey = KeychainManager.load()
        NSLog("CircleSearch: ResultPanelController.show — KeychainManager.load() = %@",
              rawKey == nil ? "nil" : "loaded \(rawKey!.count) chars")

        // Build the model for this capture session.
        let apiKey     = rawKey
        let modelID    = UserDefaults.standard.string(forKey: "selectedModel")
                      ?? AnthropicClient.defaultModel
        let client     = apiKey.map { AnthropicClient(apiKey: $0, model: modelID) }
        let newModel   = ResultPanelModel(ocrText: ocrText, image: image, client: client)
        model          = newModel

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
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
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
        // Checking all app windows (result panel, Settings, etc.) prevents the
        // monitor from dismissing the panel when the user clicks within our own UI.
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
            if event.keyCode == 53 {   // Escape (keyCode is correct for non-character keys)
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
