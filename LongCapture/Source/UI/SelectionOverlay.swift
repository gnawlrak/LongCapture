import AppKit

enum SelectionStartMode: Equatable { case confirmation, onRelease }

final class SelectionOverlay: NSWindowController {
    private let displayRect: CGRect
    private let onBegin: (CGRect) -> Void
    private let onCancel: () -> Void
    private let selectionView: SelectionView
    let startMode: SelectionStartMode
    private var resolved = false

    init(displayRect: CGRect, safeTopInset: CGFloat? = nil, startMode: SelectionStartMode = .confirmation,
         scale: CGFloat? = nil,
         onBegin: @escaping (CGRect) -> Void, onCancel: @escaping () -> Void) {
        self.displayRect = displayRect
        self.startMode = startMode
        self.onBegin = onBegin
        self.onCancel = onCancel
        let screen = NSScreen.screens.first { $0.frame == displayRect }
        let pixelScale = scale ?? screen?.backingScaleFactor ?? 1
        // The menu bar can be taller than the notch safe area, or hidden independently of it.
        let systemTopInset = screen.map { max($0.frame.maxY - $0.visibleFrame.maxY, $0.safeAreaInsets.top) } ?? 0
        self.selectionView = SelectionView(frame: CGRect(origin: .zero, size: displayRect.size),
            safeTopInset: max(0, safeTopInset ?? systemTopInset), startMode: startMode,
            geometryForSelection: { rect in
                try? CaptureGeometry(displayID: 0, displayFrame: displayRect,
                    selection: rect.offsetBy(dx: displayRect.minX, dy: displayRect.minY), scale: pixelScale)
            })
        let window = SelectionWindow(contentRect: displayRect, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = selectionView
        selectionView.onBegin = { [weak self] in self?.resolveSelection() }
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
        guard startMode == .confirmation else { return }
        resolveSelection()
    }

    private func resolveSelection() {
        guard !resolved, !selectionView.isDragging else { return }
        guard selectionView.hasValidSelection, let rect = currentSelection else { NSSound.beep(); return }
        close()
        onBegin(rect)
    }

    override func close() {
        resolved = true
        selectionView.deactivate()
        super.close()
    }

    private func cancelSelection() {
        guard !resolved else { return }
        close()
        onCancel()
    }
}

private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class SelectionView: NSView {
    var selection: CGRect? { didSet { updateSelectionPresentation(); needsDisplay = true } }
    var onBegin: (() -> Void)?
    var onCancel: (() -> Void)?
    private let instructions = NativeGlassView(cornerRadius: 24)
    private let dimensions = NativeGlassView(cornerRadius: 12, interactive: false)
    private let titleLabel = NSTextField(labelWithString: "框选后直接滚动 · 自动识别横向或纵向")
    private let noteLabel = NSTextField(wrappingLabelWithString: "只框正文，避开固定栏和动画；采集中不能混合横纵滚动。")
    private let dimensionLabel = NSTextField(labelWithString: "")
    private var beginButton: NSButton!
    private var dragStart: CGPoint?
    private let startMode: SelectionStartMode
    private let geometryForSelection: (CGRect) -> CaptureGeometry?
    private var active = true
    var isDragging: Bool { dragStart != nil }
    var hasValidSelection: Bool { selection.flatMap(geometryForSelection) != nil }
    private var initialRect: CGRect = .zero
    private var dragMode: DragMode = .new
    private enum DragMode { case new, move, resize(Int) }
    init(frame frameRect: NSRect, safeTopInset: CGFloat, startMode: SelectionStartMode,
         geometryForSelection: @escaping (CGRect) -> CaptureGeometry?) {
        self.startMode = startMode
        self.geometryForSelection = geometryForSelection
        super.init(frame: frameRect)
        if startMode == .confirmation { configureInstructions(safeTopInset: safeTopInset) }
        dimensionLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        dimensionLabel.translatesAutoresizingMaskIntoConstraints = false
        dimensions.contentView.addSubview(dimensionLabel)
        dimensions.frame = NSRect(x: 0, y: 0, width: 160, height: 28)
        dimensions.isHidden = true
        addSubview(dimensions)
        NSLayoutConstraint.activate([
            dimensionLabel.leadingAnchor.constraint(equalTo: dimensions.contentView.leadingAnchor, constant: 12),
            dimensionLabel.trailingAnchor.constraint(equalTo: dimensions.contentView.trailingAnchor, constant: -12),
            dimensionLabel.centerYAnchor.constraint(equalTo: dimensions.contentView.centerYAnchor)
        ])
        setAccessibilityLabel(startMode == .onRelease
            ? "拖动框选滚动区域，松手开始，Esc 取消，自动识别横向或纵向"
            : "拖动框选滚动区域，回车开始，Esc 取消，自动识别横向或纵向")
    }

    private func configureInstructions(safeTopInset: CGFloat) {
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.maximumNumberOfLines = 2
        let labels = NSStackView(views: [titleLabel, noteLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 5
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        NativeUI.styleAction(cancel)
        cancel.keyEquivalent = "\u{1b}"
        beginButton = NSButton(title: "开始截图", target: self, action: #selector(beginClicked))
        NativeUI.styleAction(beginButton, prominent: true)
        beginButton.keyEquivalent = "\r"
        beginButton.isEnabled = false
        let stack = NSStackView(views: [NativeUI.symbol("viewfinder"), labels, NSView(), cancel, beginButton])
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        instructions.contentView.addSubview(stack)
        instructions.translatesAutoresizingMaskIntoConstraints = false
        addSubview(instructions)
        let preferredWidth = instructions.widthAnchor.constraint(equalToConstant: 740)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            instructions.topAnchor.constraint(equalTo: topAnchor, constant: safeTopInset + 16),
            instructions.centerXAnchor.constraint(equalTo: centerXAnchor),
            instructions.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            preferredWidth,
            stack.leadingAnchor.constraint(equalTo: instructions.contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: instructions.contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: instructions.contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: instructions.contentView.bottomAnchor, constant: -16)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        guard active else { return }
        let point = boundedPoint(event)
        dragStart = point
        initialRect = selection ?? CGRect(origin: point, size: .zero)
        if startMode == .onRelease { dragMode = .new; selection = CGRect(origin: point, size: .zero) }
        else if let rect = selection, let handle = hitHandle(point, rect: rect) { dragMode = .resize(handle) }
        else if selection?.contains(point) == true { dragMode = .move }
        else { dragMode = .new; selection = CGRect(origin: point, size: .zero) }
    }

    override func mouseDragged(with event: NSEvent) {
        updateDrag(to: boundedPoint(event))
    }

    private func boundedPoint(_ event: NSEvent) -> CGPoint {
        let raw = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(raw.x, 0), bounds.maxX), y: min(max(raw.y, 0), bounds.maxY))
    }

    private func updateDrag(to point: CGPoint) {
        guard active, let start = dragStart else { return }
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

    override func mouseUp(with event: NSEvent) {
        guard active, isDragging else { return }
        updateDrag(to: boundedPoint(event))
        dragStart = nil
        if startMode == .onRelease {
            if hasValidSelection { onBegin?() }
            else { selection = nil }
        }
    }

    func deactivate() { active = false; dragStart = nil }

    override func keyDown(with event: NSEvent) {
        guard active else { return }
        switch event.keyCode {
        case 36, 76: if startMode == .confirmation { onBegin?() }
        case 53: onCancel?()
        default: super.keyDown(with: event)
        }
    }

    @objc private func beginClicked() { onBegin?() }
    @objc private func cancelClicked() { onCancel?() }

    private func updateSelectionPresentation() {
        let geometry = selection.flatMap(geometryForSelection)
        let valid = geometry != nil
        beginButton?.isEnabled = valid
        titleLabel.stringValue = valid ? "调整范围，回车开始 · 自动识别横纵方向" : "框选后直接滚动 · 自动识别横向或纵向"
        noteLabel.stringValue = valid ? "拖动内部移动 · 拖动边缘调整 · Esc 取消" : "只框正文，避开固定栏和动画；采集中不能混合横纵滚动。"
        dimensions.isHidden = !valid
        guard let geometry, let selection else { return }
        dimensionLabel.stringValue = "\(geometry.pixelWidth) × \(geometry.pixelHeight) px"
        let width = dimensionLabel.intrinsicContentSize.width + 24
        dimensions.frame = NSRect(x: min(max(8, selection.midX - width / 2), bounds.width - width - 8),
                                  y: max(8, selection.minY - 38), width: width, height: 28)
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
        NSColor.black.withAlphaComponent(0.24).setFill()
        dim.fill()
        if let rect = selection, rect.width > 0, rect.height > 0 {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 1.5
            border.stroke()
            if startMode == .confirmation {
                for x in [rect.minX, rect.midX, rect.maxX] {
                    for y in [rect.minY, rect.midY, rect.maxY] where !(x == rect.midX && y == rect.midY) {
                        NSColor.white.setFill()
                        NSBezierPath(ovalIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)).fill()
                    }
                }
            }
        }
    }
}
