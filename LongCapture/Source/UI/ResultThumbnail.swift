import AppKit

@MainActor
final class ResultThumbnail {
    private var window: NSPanel?
    private var timer: Timer?
    private let image: NSImage
    private let screenFrame: CGRect
    private let warning: String?
    private let onOpen: () -> Void
    private let onAutoSave: () -> Void
    private let lifecycle = ResultLifecycle()
    private var statusLabel: NSTextField?

    init(image: NSImage, screenFrame: CGRect, warning: String? = nil,
         onOpen: @escaping () -> Void, onAutoSave: @escaping () -> Void) {
        self.image = image
        self.screenFrame = screenFrame
        self.warning = warning
        self.onOpen = onOpen
        self.onAutoSave = onAutoSave
    }

    func show() {
        let size = NSSize(width: 220, height: warning == nil ? 208 : 236)
        let screen = NSScreen.screens.first(where: { $0.frame == screenFrame })
        let placement = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? screenFrame
        let frame = NSRect(x: placement.maxX - size.width - 20, y: placement.minY + 20,
                           width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let card = ThumbnailCard(frame: NSRect(origin: .zero, size: size), image: image,
                                 warning: warning, onClick: { [weak self] in self?.openPreview() },
                                 onHover: { [weak self] hovered in self?.lifecycle.setHovered(hovered) })
        statusLabel = card.statusLabel
        panel.contentView = card
        window = panel
        panel.orderFrontRegardless()
        lifecycle.setHovered(panel.frame.contains(NSEvent.mouseLocation))
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        guard lifecycle.tick() else { return }
        timer?.invalidate()
        timer = nil
        statusLabel?.stringValue = "正在保存…"
        onAutoSave()
    }

    private func openPreview() {
        guard lifecycle.openPreview() else { return }
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        onOpen()
    }

    func showSaveFailure(_ message: String) {
        lifecycle.saveFailed()
        timer?.invalidate()
        timer = nil
        statusLabel?.stringValue = "保存失败 · 点击打开预览"
        statusLabel?.textColor = .systemRed
        window?.contentView?.toolTip = message
        window?.orderFrontRegardless()
    }

    func finish() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window = nil
    }
}

@MainActor
private final class ThumbnailCard: NSVisualEffectView {
    let statusLabel = NSTextField(labelWithString: "5 秒后自动保存 · 点击预览")
    private let onClick: () -> Void
    private let onHover: (Bool) -> Void
    private var tracking: NSTrackingArea?

    init(frame: NSRect, image: NSImage, warning: String?,
         onClick: @escaping () -> Void, onHover: @escaping (Bool) -> Void) {
        self.onClick = onClick
        self.onHover = onHover
        super.init(frame: frame)
        material = .popover
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("长截图已完成，点击打开预览；不操作将自动保存")

        let preview = ThumbnailImageView(image: image)
        preview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(preview)
        let title = NSTextField(labelWithString: "长截图已完成")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        if let warning {
            let label = NSTextField(wrappingLabelWithString: warning)
            label.font = .systemFont(ofSize: 10)
            label.textColor = .systemOrange
            label.maximumNumberOfLines = 2
            stack.addArrangedSubview(label)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            preview.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            preview.heightAnchor.constraint(equalToConstant: 140),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 9),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -9)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                 owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }
}

@MainActor
private final class ThumbnailImageView: NSView {
    private let image: NSImage

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                              width: size.width, height: size.height))
    }
}
