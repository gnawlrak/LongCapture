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
    private let pageCount: Int

    init(image: NSImage, screenFrame: CGRect, warning: String? = nil,
         pageCount: Int = 1,
         onOpen: @escaping () -> Void, onAutoSave: @escaping () -> Void) {
        self.image = image
        self.screenFrame = screenFrame
        self.warning = warning
        self.pageCount = pageCount
        self.onOpen = onOpen
        self.onAutoSave = onAutoSave
    }

    func show() {
        let size = NSSize(width: 264, height: warning == nil ? 252 : 284)
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
                                 warning: warning, pageCount: pageCount, onClick: { [weak self] in self?.openPreview() },
                                 onHover: { [weak self] hovered in self?.lifecycle.setHovered(hovered) })
        card.onInteraction = { [weak self] active in
            guard let self else { return }
            if !active { self.lifecycle.setHovered(self.window?.frame.contains(NSEvent.mouseLocation) == true) }
            self.lifecycle.setInteracting(active)
        }
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
        statusLabel?.stringValue = "正在保存原始像素 PNG…"
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
private final class ThumbnailCard: ResultDragSourceView {
    let statusLabel = NSTextField(labelWithString: "5 秒后保存 · 点击预览 / 拖出")
    private let onHover: (Bool) -> Void
    private var tracking: NSTrackingArea?

    init(frame: NSRect, image: NSImage, warning: String?, pageCount: Int,
         onClick: @escaping () -> Void, onHover: @escaping (Bool) -> Void) {
        self.onHover = onHover
        super.init(frame: frame, image: image)
        self.onClick = onClick
        let glass = NativeGlassView(cornerRadius: 24, legacyMaterial: .popover)
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        let content = glass.contentView
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("已完成 \(pageCount) 张长截图，点击打开预览，可拖出当前图片；不操作将自动保存全部")
        toolTip = "点击预览，或拖出此图的 PNG 副本；多张截图请在预览中切换后逐张拖出"

        let preview = ThumbnailImageView(image: image)
        preview.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(preview)
        let title = NSTextField(labelWithString: pageCount > 1 ? "已完成 \(pageCount) 张长截图" : "长截图已完成")
        if pageCount > 1 { statusLabel.stringValue = "5 秒后保存全部 · 可拖出首张" }
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        let heading = NSStackView(views: [NativeUI.symbol("checkmark.circle", description: nil), title])
        heading.spacing = 6
        let stack = NSStackView(views: [heading, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        if let warning {
            let label = NSTextField(wrappingLabelWithString: warning)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .systemOrange
            label.maximumNumberOfLines = 2
            stack.addArrangedSubview(label)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            preview.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            preview.heightAnchor.constraint(equalToConstant: 164),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -12)
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
        layer?.cornerRadius = 14
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
