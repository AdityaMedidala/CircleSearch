import SwiftUI
import KeyboardShortcuts

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            KeyboardShortcuts.Recorder("Capture shortcut:", name: .triggerCapture)
                .padding(.bottom, 2)
            Divider()
            Button("Quit CircleSearch") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding()
        .frame(width: 260)
    }
}
