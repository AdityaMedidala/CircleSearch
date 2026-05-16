import SwiftUI
import KeyboardShortcuts

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text("CircleSearch")
                    .font(.headline)
                Spacer()
                Button {
                    SettingsWindowController.shared.show()
                } label: {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }

            Divider()

            KeyboardShortcuts.Recorder("Capture shortcut:", name: .triggerCapture)

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
