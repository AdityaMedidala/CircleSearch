import AppKit
import SwiftUI

/// Singleton that owns the Settings NSWindow.
/// Calling `show()` when the window is already open brings it to front instead of opening a second.
@MainActor
final class SettingsWindowController: NSObject {

    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSHostingController(rootView: SettingsView())
        let win = NSWindow(contentViewController: controller)
        win.title = "CircleSearch Settings"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.setContentSize(NSSize(width: 480, height: 400))
        win.center()
        win.isReleasedWhenClosed = false

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: win
        )

        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func windowWillClose(_ note: Notification) {
        window = nil
    }
}
