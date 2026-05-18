import AppKit
import Foundation

// MARK: - CaptureEntry

/// A single persisted capture loaded from disk.
struct CaptureEntry: Identifiable {
    let id: UUID
    let timestamp: Date
    let ocrText: String
    let aiResponse: String
    let providerType: ProviderType
    let model: String
    let imageURL: URL

    /// Small 64-pt thumbnail pre-loaded when the entry is constructed by `loadRecent`.
    let thumbnail: CGImage?

    /// Full-resolution image loaded on demand (used when reopening in the result panel).
    var image: CGImage? {
        guard let src = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

// MARK: - HistoryManager

enum HistoryManager {

    // MARK: Storage root

    static var historyDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("CircleSearch/history", isDirectory: true)
    }

    // MARK: Save

    /// Persists a completed capture to disk.
    /// Intended to be called from a background `Task`; never blocks the main thread.
    static func save(image: CGImage,
                     ocrText: String,
                     aiResponse: String,
                     providerType: ProviderType,
                     model: String) throws {
        let dir = historyDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let id  = UUID()
        let iso = ISO8601DateFormatter().string(from: Date())

        // Write PNG image.
        let imageURL = dir.appendingPathComponent("\(id.uuidString).png")
        let rep      = NSBitmapImageRep(cgImage: image)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw HistoryError.encodingFailed
        }
        try pngData.write(to: imageURL)

        // Write JSON metadata.
        let meta = CaptureMetadata(
            id:           id.uuidString,
            timestamp:    iso,
            ocrText:      ocrText,
            aiResponse:   aiResponse,
            providerType: providerType.rawValue,
            model:        model
        )
        let jsonURL  = dir.appendingPathComponent("\(id.uuidString).json")
        let jsonData = try JSONEncoder().encode(meta)
        try jsonData.write(to: jsonURL)

        NSLog("CircleSearch: HistoryManager saved %@", id.uuidString)

        // Notify observers (ContentView) to refresh on the main thread.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .captureHistorySaved, object: nil)
        }
    }

    // MARK: Load

    /// Returns up to `limit` entries sorted newest-first.
    /// Loads 64-pt thumbnails for each entry so callers can display them without further I/O.
    static func loadRecent(limit: Int = 10) -> [CaptureEntry] {
        let dir = historyDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return [] }

        let formatter = ISO8601DateFormatter()
        var entries: [CaptureEntry] = []

        for jsonURL in files where jsonURL.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: jsonURL),
                let meta = try? JSONDecoder().decode(CaptureMetadata.self, from: data),
                let id   = UUID(uuidString: meta.id),
                let ts   = formatter.date(from: meta.timestamp),
                let pt   = ProviderType(rawValue: meta.providerType)
            else { continue }

            let imageURL = dir.appendingPathComponent("\(meta.id).png")
            guard FileManager.default.fileExists(atPath: imageURL.path) else { continue }

            entries.append(CaptureEntry(
                id:           id,
                timestamp:    ts,
                ocrText:      meta.ocrText,
                aiResponse:   meta.aiResponse,
                providerType: pt,
                model:        meta.model,
                imageURL:     imageURL,
                thumbnail:    loadThumbnail(from: imageURL)
            ))
        }

        return entries
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: Delete

    /// Removes both the .png and .json files for the given entry id.
    static func delete(id: UUID) throws {
        let dir  = historyDirectory
        let base = id.uuidString
        for ext in ["json", "png"] {
            let url = dir.appendingPathComponent("\(base).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: Prune

    /// Deletes the oldest entries beyond `maxCount`. Safe to call from any thread.
    static func prune(maxCount: Int = 50) {
        let dir = historyDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }

        let formatter = ISO8601DateFormatter()
        var pairs: [(id: UUID, timestamp: Date)] = []

        for jsonURL in files where jsonURL.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: jsonURL),
                let meta = try? JSONDecoder().decode(CaptureMetadata.self, from: data),
                let id   = UUID(uuidString: meta.id),
                let ts   = formatter.date(from: meta.timestamp)
            else { continue }
            pairs.append((id: id, timestamp: ts))
        }

        guard pairs.count > maxCount else { return }

        // Sort oldest-first and delete the excess.
        let toDelete = pairs.sorted { $0.timestamp < $1.timestamp }
                           .prefix(pairs.count - maxCount)
        for pair in toDelete {
            try? delete(id: pair.id)
            NSLog("CircleSearch: HistoryManager pruned %@", pair.id.uuidString)
        }
    }

    // MARK: Private

    private static func loadThumbnail(from url: URL) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

// MARK: - Private Codable type

private struct CaptureMetadata: Codable {
    let id: String
    let timestamp: String
    let ocrText: String
    let aiResponse: String
    let providerType: String
    let model: String
}

// MARK: - Errors

enum HistoryError: LocalizedError {
    case encodingFailed
    var errorDescription: String? { "Failed to encode the capture image for storage." }
}

// MARK: - Notification

extension Notification.Name {
    static let captureHistorySaved = Notification.Name("CircleSearch.captureHistorySaved")
}
