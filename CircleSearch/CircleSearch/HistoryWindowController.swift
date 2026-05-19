import AppKit
import SwiftUI

// MARK: - HistoryWindowController

/// Singleton that manages the full Capture History browser window.
@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate {

    static let shared = HistoryWindowController()

    private var window: NSWindow?

    // MARK: Public

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(rootView: HistoryWindowView())
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable],
            backing:     .buffered,
            defer:       false
        )
        w.title          = "Capture History"
        w.minSize        = NSSize(width: 480, height: 400)
        w.contentView    = hostingView
        w.delegate       = self
        w.isReleasedWhenClosed = false

        // Restore saved frame, or centre on screen.
        if !w.setFrameUsingName("HistoryWindow") {
            w.center()
        }
        w.setFrameAutosaveName("HistoryWindow")

        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in self.window = nil }
    }
}

// MARK: - HistoryWindowView

private struct HistoryWindowView: View {

    @State private var entries: [CaptureEntry] = []
    @State private var searchText = ""

    private var filtered: [CaptureEntry] {
        guard !searchText.isEmpty else { return entries }
        let q = searchText.lowercased()
        return entries.filter { $0.ocrText.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search captures…", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            if filtered.isEmpty {
                emptyState
            } else {
                List(filtered) { entry in
                    HistoryRowView(entry: entry, onDelete: { deleteEntry(entry) })
                        .contentShape(Rectangle())
                        .onTapGesture { openCapture(entry) }
                        .listRowSeparator(.visible)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
                .listStyle(.plain)
            }
        }
        .onAppear { loadEntries() }
        .onReceive(NotificationCenter.default.publisher(for: .captureHistorySaved)) { _ in
            loadEntries()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(searchText.isEmpty ? "No captures yet." : "No results for \"\(searchText)\".")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func loadEntries() {
        Task.detached(priority: .userInitiated) {
            let all = HistoryManager.loadRecent(limit: 50)
            await MainActor.run { entries = all }
        }
    }

    private func openCapture(_ entry: CaptureEntry) {
        Task { @MainActor in
            ResultPanelController.shared.showFromHistory(entry: entry)
        }
    }

    private func deleteEntry(_ entry: CaptureEntry) {
        Task.detached(priority: .userInitiated) {
            try? HistoryManager.delete(id: entry.id)
            let all = HistoryManager.loadRecent(limit: 50)
            await MainActor.run { entries = all }
        }
    }
}

// MARK: - HistoryRowView

private struct HistoryRowView: View {
    let entry: CaptureEntry
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            thumbnailView

            VStack(alignment: .leading, spacing: 3) {
                Text(ocrSnippet)
                    .font(.callout)
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    Text(formattedDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(entry.providerType.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .contextMenu {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var thumbnailView: some View {
        Group {
            if let cg = entry.thumbnail {
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.secondary.opacity(0.15))
            }
        }
        .frame(width: 96, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var ocrSnippet: String {
        let text = entry.ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "[No text detected]" }
        if text.count <= 60 { return text }
        return String(text.prefix(60)) + "…"
    }

    private var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: entry.timestamp)
    }
}

