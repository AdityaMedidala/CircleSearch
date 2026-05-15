import AppKit

/// Full-screen transparent view that captures mouse drags and draws a rubber-band selection.
///
/// Drawing strategy: an even-odd NSBezierPath with the full bounds as the outer rect and the
/// selection as the inner rect produces a "frame" fill — the selection area stays transparent,
/// revealing actual screen content through the non-opaque window.
final class SelectionOverlayView: NSView {

    // MARK: Callbacks

    /// Called on mouseUp with the selected rect in view-local coordinates.
    var onSelectionComplete: ((NSRect) -> Void)?
    /// Called when the user cancels (Escape or single click with no drag).
    var onCancel: (() -> Void)?

    // MARK: Private state

    private var startPoint: NSPoint = .zero
    private var selectionRect: NSRect = .zero
    private var isDragging = false

    // MARK: NSView

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // --- Overlay ---
        let overlayPath = NSBezierPath()
        overlayPath.windingRule = .evenOdd
        overlayPath.appendRect(bounds)
        if isDragging && !selectionRect.isEmpty {
            overlayPath.appendRect(selectionRect)   // punched-out hole
        }
        NSColor.black.withAlphaComponent(0.45).setFill()
        overlayPath.fill()

        // --- Selection border + dimensions label ---
        guard isDragging && !selectionRect.isEmpty else { return }

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(selectionRect)

        // Dimension label
        let label = "\(Int(selectionRect.width)) × \(Int(selectionRect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let labelSize = str.size()

        // Prefer drawing above the selection; fall back to below if at the top.
        let labelY: CGFloat
        let above = selectionRect.maxY + 4
        if above + labelSize.height <= bounds.maxY {
            labelY = above
        } else {
            labelY = selectionRect.minY - labelSize.height - 4
        }
        let labelOrigin = NSPoint(
            x: (selectionRect.midX - labelSize.width / 2).rounded(),
            y: labelY
        )
        str.draw(at: labelOrigin)
    }

    // MARK: Mouse events

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        selectionRect = .zero
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let current = convert(event.locationInWindow, from: nil)
        selectionRect = NSRect(
            x: min(startPoint.x, current.x),
            y: min(startPoint.y, current.y),
            width: abs(current.x - startPoint.x),
            height: abs(current.y - startPoint.y)
        )
        isDragging = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            isDragging = false
            selectionRect = .zero
            needsDisplay = true
        }

        // Require a meaningful drag; ignore accidental clicks.
        if isDragging && selectionRect.width > 4 && selectionRect.height > 4 {
            onSelectionComplete?(selectionRect)
        } else {
            onCancel?()
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
        }
    }
}
