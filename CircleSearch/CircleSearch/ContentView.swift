import SwiftUI
import KeyboardShortcuts

struct ContentView: View {

    @State private var history: [CaptureEntry] = []
    @State private var totalCount: Int = 0

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

            // Recent captures
            Text("Recent Captures")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            if history.isEmpty {
                Text("No captures yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(history) { entry in
                        Button {
                            openCapture(entry)
                        } label: {
                            CaptureHistoryRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if totalCount > 4 {
                    Button {
                        HistoryWindowController.shared.show()
                    } label: {
                        HStack(spacing: 4) {
                            Text("Show all (\(totalCount))")
                                .font(.callout)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }

            Divider()

            Button("Quit CircleSearch") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding()
        .frame(width: 300)
        .onAppear { loadHistory() }
        .onReceive(NotificationCenter.default.publisher(for: .captureHistorySaved)) { _ in
            loadHistory()
        }
    }

    private func loadHistory() {
        Task.detached(priority: .userInitiated) {
            let entries = HistoryManager.loadRecent(limit: 4)
            let count   = HistoryManager.countAll()
            await MainActor.run {
                history    = entries
                totalCount = count
            }
        }
    }

    private func openCapture(_ entry: CaptureEntry) {
        Task { @MainActor in
            ResultPanelController.shared.showFromHistory(entry: entry)
        }
    }
}

// MARK: - CaptureHistoryRow

private struct CaptureHistoryRow: View {
    let entry: CaptureEntry

    var body: some View {
        HStack(spacing: 8) {
            thumbnailView
            VStack(alignment: .leading, spacing: 2) {
                Text(ocrSnippet)
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(relativeTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private var thumbnailView: some View {
        Group {
            if let cg = entry.thumbnail {
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.secondary.opacity(0.2))
            }
        }
        .frame(width: 64, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var ocrSnippet: String {
        let text = entry.ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "[No text detected]" }
        if text.count <= 40 { return text }
        return String(text.prefix(40)) + "…"
    }

    private var relativeTime: String {
        let secs = Date().timeIntervalSince(entry.timestamp)
        if secs < 60      { return "just now" }
        if secs < 3600    { return "\(Int(secs / 60)) min ago" }
        if secs < 7200    { return "1 hour ago" }
        if secs < 86400   { return "\(Int(secs / 3600)) hours ago" }
        if secs < 172800  { return "yesterday" }
        return "\(Int(secs / 86400)) days ago"
    }
}
