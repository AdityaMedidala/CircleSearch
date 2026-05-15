import AppKit

/// Creates one borderless, transparent, screen-saver-level NSWindow per display,
/// runs the rubber-band selection flow, then hands the captured rect off to
/// ScreenCaptureManager → OCRManager → ResultPanelController.
@MainActor
final class OverlayWindowController: NSObject {

    static let shared = OverlayWindowController()

    // MARK: Private state

    private var overlayWindows: [NSWindow] = []
    /// The app that was frontmost before the overlay appeared; restored on dismiss.
    private var previousApp: NSRunningApplication?

    // MARK: Public

    func showOverlay() {
        guard overlayWindows.isEmpty else { return }

        previousApp = NSWorkspace.shared.frontmostApplication

        for screen in NSScreen.screens {
            let window = makeOverlayWindow(for: screen)
            overlayWindows.append(window)
        }

        // Activate the app so our window can become key and receive keyboard events.
        NSApp.activate(ignoringOtherApps: true)
        overlayWindows.first?.makeKeyAndOrderFront(nil)
    }

    // MARK: Private

    private func makeOverlayWindow(for screen: NSScreen) -> NSWindow {
        // Window frame = entire screen in global Cocoa coordinates.
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let view = SelectionOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))

        view.onSelectionComplete = { [weak self] viewRect in
            self?.handleSelection(viewRect, on: screen)
        }
        view.onCancel = { [weak self] in
            self?.dismissOverlay()
        }

        window.contentView = view
        window.orderFrontRegardless()
        return window
    }

    private func handleSelection(_ viewRect: NSRect, on screen: NSScreen) {
        dismissOverlay()

        // Convert from view-local coordinates to global Cocoa screen coordinates.
        // The overlay window's content area starts at screen.frame.origin, so:
        let globalRect = NSRect(
            x: screen.frame.minX + viewRect.minX,
            y: screen.frame.minY + viewRect.minY,
            width: viewRect.width,
            height: viewRect.height
        )

        Task {
            do {
                let image = try await ScreenCaptureManager.capture(rect: globalRect, on: screen)
                let text  = try await OCRManager.recognizeText(in: image)
                ResultPanelController.shared.show(text: text, near: globalRect)
            } catch {
                NSLog("CircleSearch: capture/OCR error — %@", error.localizedDescription)
            }
        }
    }

    private func dismissOverlay() {
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()

        // Return focus to whatever the user was doing before.
        previousApp?.activate(options: [])
        previousApp = nil
    }
}
