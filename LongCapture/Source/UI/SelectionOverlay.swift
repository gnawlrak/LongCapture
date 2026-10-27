import AppKit

final class SelectionOverlay: NSWindowController {
    private let displayRect: CGRect
    private let onBegin: (CGRect) -> Void
    private let onCancel: () -> Void
    private let selectionView: SelectionView
    private var resolved = false

    init(displayRect: CGRect, onBegin: @escaping (CGRect) -> Void, onCancel: @escaping () -> Void) {
        self.displayRect = displayRect
        self.onBegin = onBegin
        self.onCancel = onCancel
        self.selectionView = SelectionView(frame: CGRect(origin: .zero, size: displayRect.size))
        let window = SelectionWindow(contentRect: displayRect, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = selectionView
        selectionView.onBegin = { [weak self] in self?.begin() }
        selectionView.onCancel = { [weak self] in self?.cancelSelection() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var currentSelection: CGRect? {
        selectionView.selection.map { $0.offsetBy(dx: displayRect.minX, dy: displayRect.minY) }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(selectionView)
    }

    func begin() {
        guard !resolved, let rect = currentSelection, rect.width >= 24, rect.height >= 24 else { NSSound.beep(); return }
        resolved = true
        close()
        onBegin(rect)
    }

    private func cancelSelection() {
        guard !resolved else { return }
        resolved = true
        close()
        onCancel()
    }
}

private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class SelectionView: NSView {
    var selection: CGRect? { didSet { needsDisplay = true } }
    var onBegin: (() -> Void)?
    var onCancel: (() -> Void)?
    private var dragStart: CGPoint?
    private var initialRect: CGRect = .zero
    private var dragMode: DragMode = .new
    private enum DragMode { case new, move, resize(Int) }

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        initialRect = selection ?? CGRect(origin: point, size: .zero)
        if let rect = selection, let handle = hitHandle(point, rect: rect) { dragMode = .resize(handle) }
        else if selection?.contains(point) == true { dragMode = .move }
        else { dragMode = .new; selection = CGRect(origin: point, size: .zero) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let raw = convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: min(max(raw.x, 0), bounds.maxX), y: min(max(raw.y, 0), bounds.maxY))
        switch dragMode {
        case .new:
            selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                               width: abs(start.x - point.x), height: abs(start.y - point.y))
        case .move:
            let x = min(max(0, initialRect.minX + point.x - start.x), bounds.width - initialRect.width)
            let y = min(max(0, initialRect.minY + point.y - start.y), bounds.height - initialRect.height)
            selection = CGRect(origin: CGPoint(x: x, y: y), size: initialRect.size)
        case .resize(let handle):
            var left = initialRect.minX, right = initialRect.maxX
            var bottom = initialRect.minY, top = initialRect.maxY
            if handle & 1 != 0 { left = point.x }
            if handle & 2 != 0 { right = point.x }
            if handle & 4 != 0 { bottom = point.y }
            if handle & 8 != 0 { top = point.y }
            selection = CGRect(x: min(left, right), y: min(bottom, top), width: abs(right - left), height: abs(top - bottom))
        }
    }

    override func mouseUp(with event: NSEvent) { dragStart = nil }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onBegin?()
        case 53: onCancel?()
        default: super.keyDown(with: event)
        }
    }

    private func hitHandle(_ point: CGPoint, rect: CGRect) -> Int? {
        var mask = 0
        if abs(point.x - rect.minX) <= 8 { mask |= 1 }
        else if abs(point.x - rect.maxX) <= 8 { mask |= 2 }
        if abs(point.y - rect.minY) <= 8 { mask |= 4 }
        else if abs(point.y - rect.maxY) <= 8 { mask |= 8 }
        return mask != 0 && rect.insetBy(dx: -8, dy: -8).contains(point) ? mask : nil
    }

    override func draw(_ dirtyRect: CGRect) {
        let dim = NSBezierPath(rect: bounds)
        if let selection { dim.appendRect(selection) }
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.40).setFill()
        dim.fill()
        if let rect = selection, rect.width > 0, rect.height > 0 {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 1.5
            border.stroke()
            for x in [rect.minX, rect.midX, rect.maxX] {
                for y in [rect.minY, rect.midY, rect.maxY] where !(x == rect.midX && y == rect.midY) {
                    NSColor.white.setFill()
                    NSBezierPath(ovalIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)).fill()
                }
            }
        }
        let title = selection == nil ? "拖动框选滚动区域" : "拖动内部移动 · 拖动边缘调整 · 回车开始 · Esc 取消"
        let note = "只框正文，避开固定标题栏、侧栏、输入框和持续动画。仅支持单屏纵向滚动。"
        let center = NSMutableParagraphStyle(); center.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .paragraphStyle: center]
        let box = CGRect(x: 20, y: bounds.height - 62, width: bounds.width - 40, height: 26)
        (title as NSString).draw(in: box, withAttributes: attributes)
        var smaller = attributes; smaller[.font] = NSFont.systemFont(ofSize: 12)
        (note as NSString).draw(in: box.offsetBy(dx: 0, dy: -26), withAttributes: smaller)
    }
}
