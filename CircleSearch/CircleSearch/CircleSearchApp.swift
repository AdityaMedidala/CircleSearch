import SwiftUI
import KeyboardShortcuts

@main
struct CircleSearchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("CircleSearch", image: "MenuBarIcon") {
            ContentView()
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement in Info.plist already suppresses the Dock icon;
        // this call keeps it suppressed even if the app activates briefly.
        NSApp.setActivationPolicy(.accessory)

        KeyboardShortcuts.onKeyUp(for: .triggerCapture) {
            OverlayWindowController.shared.showOverlay()
        }
    }
}
