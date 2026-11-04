import AppKit

@MainActor
final class CaptureSelectionWindow: NSWindow {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
final class CaptureSelectionOverlayView: NSView {
    private let screenFrame: CGRect
    private let showsHint: Bool
    private let onChange: (CGRect) -> Void
    private let onFinish: (CGRect) -> Void
    private let onCancel: () -> Void
    private var dragOrigin: CGPoint?
    var selectionRect: CGRect?

    init(
        frame: NSRect,
        screenFrame: CGRect,
        showsHint: Bool,
        onChange: @escaping (CGRect) -> Void,
        onFinish: @escaping (CGRect) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.screenFrame = screenFrame
        self.showsHint = showsHint
        self.onChange = onChange
        self.onFinish = onFinish
        self.onCancel = onCancel
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel()
        } else {
            super.keyDown(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.34).setFill()
        bounds.fill()

        if let selectionRect {
            let local = CGRect(
                x: selectionRect.minX - screenFrame.minX,
                y: screenFrame.maxY - selectionRect.maxY,
                width: selectionRect.width,
                height: selectionRect.height
            )
            NSColor.white.withAlphaComponent(0.1).setFill()
            NSBezierPath(rect: local).fill()
            NSColor.systemBlue.setStroke()
            let outline = NSBezierPath(rect: local.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 2
            outline.stroke()
        }

        guard showsHint else { return }
        let label = "Drag to select  •  Esc to cancel"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = (label as NSString).size(withAttributes: attributes)
        let box = CGRect(x: 18, y: 18, width: textSize.width + 26, height: 34)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        (label as NSString).draw(at: CGPoint(x: box.minX + 13, y: box.minY + 9), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        dragOrigin = point
        let rect = CGRect(origin: point, size: .zero)
        selectionRect = rect
        onChange(rect)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        let rect = CGRect(
            x: min(dragOrigin.x, NSEvent.mouseLocation.x),
            y: min(dragOrigin.y, NSEvent.mouseLocation.y),
            width: abs(dragOrigin.x - NSEvent.mouseLocation.x),
            height: abs(dragOrigin.y - NSEvent.mouseLocation.y)
        )
        onChange(rect)
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragOrigin else { return }
        self.dragOrigin = nil
        let current = NSEvent.mouseLocation
        onFinish(CGRect(
            x: min(dragOrigin.x, current.x),
            y: min(dragOrigin.y, current.y),
            width: abs(dragOrigin.x - current.x),
            height: abs(dragOrigin.y - current.y)
        ))
    }
}
