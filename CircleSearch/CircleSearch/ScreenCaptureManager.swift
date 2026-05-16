import AppKit
import ScreenCaptureKit

/// One-shot screen capture of a rect on a specific display using ScreenCaptureKit.
enum ScreenCaptureManager {

    // MARK: Public

    /// Captures the given rect (in global Cocoa screen coordinates) from `screen`.
    ///
    /// Coordinate systems recap:
    ///   • Cocoa / AppKit  — origin at bottom-left of the **main** screen.
    ///   • ScreenCaptureKit `sourceRect` — origin at **top-left** of the target display.
    ///
    /// So we:
    ///   1. Subtract `screen.frame.origin` to get display-local Cocoa coords.
    ///   2. Flip Y: `displayY = screen.frame.height − (localY + rect.height)`.
    static func capture(rect: NSRect, on screen: NSScreen) async throws -> CGImage {
        // Let SCShareableContent throw naturally — this triggers the modern macOS
        // permission prompt. We only map the specific permission-denied codes to
        // CaptureError.permissionDenied; all other failures are rethrown as-is so
        // they don't mislead users into toggling an unrelated privacy setting.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            let ns = error as NSError
            NSLog("CircleSearch: SCShareableContent failed — domain=%@ code=%d description=%@",
                  ns.domain, ns.code, error.localizedDescription)

            let isPermissionDenied: Bool = {
                // Explicit Swift-typed user denial.
                if let scErr = error as? SCStreamError, scErr.code == .userDeclined {
                    return true
                }
                // Older permission-related codes under com.apple.ScreenCaptureKit.
                if ns.domain == "com.apple.ScreenCaptureKit" && [-3801, -3802, -3803].contains(ns.code) {
                    return true
                }
                // Belt-and-suspenders: SCStreamErrorDomain + userDeclined raw value
                // catches the NSError-bridged form of the same denial.
                if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.Code.userDeclined.rawValue {
                    return true
                }
                return false
            }()

            if isPermissionDenied { throw CaptureError.permissionDenied }
            throw error
        }

        // Match the NSScreen to its SCDisplay via the CGDirectDisplayID.
        guard
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
            let display   = content.displays.first(where: { $0.displayID == displayID })
        else {
            throw CaptureError.displayNotFound
        }

        // Build the sourceRect in display-local, top-left-origin coordinates.
        let localX      = rect.minX - screen.frame.minX
        let localY      = rect.minY - screen.frame.minY
        let displayY    = screen.frame.height - localY - rect.height
        let sourceRect  = CGRect(x: localX, y: displayY, width: rect.width, height: rect.height)

        let config = SCStreamConfiguration()
        config.sourceRect   = sourceRect
        config.showsCursor  = false
        // Output pixel size matches the selection at the display's backing scale factor.
        let scale           = screen.backingScaleFactor
        config.width        = max(1, Int(rect.width  * scale))
        config.height       = max(1, Int(rect.height * scale))
        config.colorSpaceName = CGColorSpace.sRGB

        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // MARK: Errors

    enum CaptureError: LocalizedError {
        case permissionDenied
        case displayNotFound

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Screen recording permission is required. Enable CircleSearch in System Settings → Privacy & Security → Screen & System Audio Recording."
            case .displayNotFound:
                return "Could not match the selected screen region to a display."
            }
        }
    }
}
