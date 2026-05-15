import AppKit
import SwiftUI

/// Manages the floating NSPanel that displays OCR results.
@MainActor
final class ResultPanelController: NSObject {

    static let shared = ResultPanelController()

    private var panel: NSPanel?

    // MARK: Public

    func show(text: String, near selectionRect: NSRect) {
        panel?.close()

        let resultView = ResultView(text: text) { [weak self] in
            self?.panel?.orderOut(nil)
        }

        let hosting = NSHostingView(rootView: resultView)
        hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 260)

        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.title = "Extracted Text"
        newPanel.isFloatingPanel = true
        newPanel.level = .floating
        newPanel.isReleasedWhenClosed = false
        newPanel.contentView = hosting

        position(newPanel, near: selectionRect)
        newPanel.orderFront(nil)
        panel = newPanel
    }

    // MARK: Private

    private func position(_ panel: NSPanel, near rect: NSRect) {
        let panelSize = panel.frame.size
        let margin: CGFloat = 12

        // Find which screen owns the selection.
        let screen = NSScreen.screens.first { $0.frame.contains(rect) }
                  ?? NSScreen.main
                  ?? NSScreen.screens[0]
        let visible = screen.visibleFrame

        // Try below the selection first, then above.
        var origin = NSPoint(
            x: rect.midX - panelSize.width / 2,
            y: rect.minY - panelSize.height - margin
        )
        if origin.y < visible.minY {
            origin.y = rect.maxY + margin
        }

        // Clamp horizontally to the visible frame.
        origin.x = max(visible.minX,
                       min(origin.x, visible.maxX - panelSize.width))

        panel.setFrameOrigin(origin)
    }
}

// MARK: - ResultView

private struct ResultView: View {
    let text: String
    let onClose: () -> Void

    @State private var copyLabel = "Copy"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                Text(text.isEmpty ? "No text recognised." : text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button(copyLabel) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copyLabel = "Copied!"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copyLabel = "Copy"
                    }
                }
                .disabled(text.isEmpty)
                .keyboardShortcut("c", modifiers: .command)
            }
        }
        .padding()
        .frame(minWidth: 340, minHeight: 220)
    }
}
