import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let triggerCapture = Self(
        "triggerCapture",
        default: .init(.space, modifiers: [.command, .shift])
    )
}
