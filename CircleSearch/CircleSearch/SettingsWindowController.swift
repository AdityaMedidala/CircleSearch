import AppKit
import SwiftUI

// MARK: - SettingsWindow

/// Custom NSWindow subclass that:
/// - closes on Escape (when the window is key)
/// - reports canBecomeKey so keyboard navigation inside Forms works
private final class SettingsWindow: NSWindow {
    override var canBecomeKey:  Bool { true  }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // Escape
            close()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - SettingsWindowController

/// Singleton that owns the Settings NSWindow.
///
/// Design goals:
/// - **Non-blocking**: opening Settings does NOT steal focus from the user's active app.
/// - **Floating**: the window appears above normal app windows via `.floating` level,
///   but well below the capture overlay which uses `.screenSaver`.
/// - **Dismissable**: Escape closes it; clicking outside all app windows closes it.
/// - **Capture-safe**: the hotkey and overlay flow work identically whether Settings
///   is open or not — the overlay at `.screenSaver` always appears on top.
@MainActor
final class SettingsWindowController: NSObject {

    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var clickMonitor: Any?

    // MARK: Public

    func show() {
        if let existing = window {
            // Already open — bring to front without taking focus away from the user's work.
            existing.orderFrontRegardless()
            return
        }

        let win = buildWindow()
        window = win

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: win
        )

        // orderFrontRegardless makes the window appear even when our app is not the
        // frontmost application — crucially, it does NOT call NSApp.activate(), so the
        // user's current app stays focused.
        win.orderFrontRegardless()
        installClickMonitor()
    }

    // MARK: Private — window construction

    private func buildWindow() -> NSWindow {
        let controller = NSHostingController(rootView: SettingsView())
        let win = SettingsWindow(contentViewController: controller)

        win.title = "CircleSearch Settings"

        // fullSizeContentView lets content extend into the titlebar area.
        // We compensate in setContentSize by adding ~28 pt for the titlebar height,
        // so the SwiftUI frame(width:height:) in SettingsView still gets 500 pt of
        // usable vertical space after safe-area insets are applied.
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.titleVisibility             = .hidden
        win.isMovableByWindowBackground = true

        // .floating (z-order 3) sits above normal app windows but far below the
        // capture overlay (.screenSaver ≈ 1000) and result panel (.floating + ordered front).
        win.level = .floating

        win.setContentSize(NSSize(width: 480, height: 528))  // 500 visible + ~28 titlebar
        win.center()
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        return win
    }

    // MARK: Private — click-outside monitor

    /// Closes Settings when the user clicks outside all visible app windows
    /// (result panel, Settings, etc.). Clicking on the result panel or the capture
    /// overlay does NOT close Settings — those are also app windows.
    private func installClickMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self else { return }
            let loc       = NSEvent.mouseLocation
            let insideApp = NSApp.windows.contains { $0.isVisible && $0.frame.contains(loc) }
            if !insideApp {
                Task { @MainActor in self.window?.close() }
            }
        }
    }

    // MARK: Private — cleanup

    @objc private func windowWillClose(_ note: Notification) {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        window = nil
    }
}
