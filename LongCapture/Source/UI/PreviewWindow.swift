import AppKit

@MainActor
final class PreviewWindowController: NSWindowController, NSWindowDelegate {
    private let image: NSImage
    private let onSave: () async throws -> URL
    private let onDiscard: () -> Bool
    private let onChooseDirectory: () -> Void
    private let lifecycle = ResultLifecycle(presentation: .preview)
    private var resolved = false
    private var actionButtons: [NSButton] = []
    private let statusLabel = NSTextField(labelWithString: "原始像素 PNG · 关闭窗口也会保存")
    private let scrollView = NSScrollView()
    private let zoomMenu = NSPopUpButton()

    init(image: NSImage, warning: String? = nil,
         onSave: @escaping () async throws -> URL, onDiscard: @escaping () -> Bool,
         onChooseDirectory: @escaping () -> Void) {
        self.image = image
        self.onSave = onSave
        self.onDiscard = onDiscard
        self.onChooseDirectory = onChooseDirectory
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 650),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "长截图预览"
        window.minSize = NSSize(width: 650, height: 420)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildContent(warning: warning)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        fitWidth()
    }

    func closeAfterResolution() {
        guard !resolved else { return }
        resolved = true
        lifecycle.saved()
        window?.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !resolved else { return true }
        Task { await saveAndClose() }
        return false
    }

    private func buildContent(warning: String?) {
        guard let window else { return }
        let root = NSView()
        window.contentView = root
        let dimensions = NSTextField(labelWithString: "\(Int(image.size.width)) × \(Int(image.size.height)) 像素")
        dimensions.textColor = .secondaryLabelColor
        dimensions.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let copy = NSButton(title: "复制", image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)!,
                            target: self, action: #selector(copyClicked))
        copy.keyEquivalent = "c"
        copy.keyEquivalentModifierMask = [.command]
        for (name, tag) in [("适合宽度", 0), ("25%", 25), ("50%", 50), ("100%", 100), ("200%", 200), ("400%", 400)] {
            zoomMenu.addItem(withTitle: name)
            zoomMenu.lastItem?.tag = tag
        }
        zoomMenu.target = self
        zoomMenu.action = #selector(zoomChanged)
        zoomMenu.setAccessibilityLabel("预览缩放")
        let top = NSStackView(views: [dimensions, NSView(), copy, zoomMenu])
        top.orientation = .horizontal
        top.spacing = 12
        top.alignment = .centerY

        let document = CaptureImageView(image: image)
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.01
        scrollView.maxMagnification = 8

        let folder = NSButton(title: "保存位置…", target: self, action: #selector(chooseDirectoryClicked))
        let discard = NSButton(title: "丢弃", target: self, action: #selector(discardClicked))
        let save = NSButton(title: "保存 PNG", target: self, action: #selector(saveClicked))
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = [.command]
        let done = NSButton(title: "完成", target: self, action: #selector(saveClicked))
        done.keyEquivalent = "\r"
        actionButtons = [folder, discard, save, done]
        let actions = NSStackView(views: [folder, NSView(), discard, save, done])
        actions.orientation = .horizontal
        actions.spacing = 10
        actions.alignment = .centerY
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        stack.addArrangedSubview(top)
        if let warning {
            let label = NSTextField(wrappingLabelWithString: "截图提示：\(warning)\n仅包含已确认匹配的部分。")
            label.textColor = .systemOrange
            label.font = .systemFont(ofSize: 12)
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            stack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.addArrangedSubview(scrollView)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(actions)
        for view in [top, scrollView, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        top.heightAnchor.constraint(equalToConstant: 30).isActive = true
        actions.heightAnchor.constraint(equalToConstant: 30).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])
    }

    private func fitWidth() {
        window?.contentView?.layoutSubtreeIfNeeded()
        let available = max(1, scrollView.contentSize.width - 4)
        scrollView.magnification = min(1, max(0.01, available / max(1, image.size.width)))
        scrollView.documentView?.scroll(.zero)
        zoomMenu.selectItem(withTag: 0)
    }

    @objc private func zoomChanged() {
        guard let item = zoomMenu.selectedItem else { return }
        if item.tag == 0 { fitWidth() }
        else { scrollView.magnification = CGFloat(item.tag) / 100 }
    }

    @objc private func copyClicked() {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        statusLabel.stringValue = "已复制到剪贴板 · 原始像素 PNG"
    }

    @objc private func chooseDirectoryClicked() { onChooseDirectory() }
    @objc private func saveClicked() { Task { await saveAndClose() } }

    @objc private func discardClicked() {
        guard lifecycle.state != .saving, lifecycle.state != .resolved,
              onDiscard(), lifecycle.discard() else { return }
        guard !resolved else { return }
        resolved = true
        window?.close()
    }

    private func saveAndClose() async {
        guard lifecycle.beginSave(), !resolved else { return }
        actionButtons.forEach { $0.isEnabled = false }
        statusLabel.stringValue = "正在保存 PNG…"
        do {
            _ = try await onSave()
            lifecycle.saved()
            closeAfterResolution()
        } catch {
            lifecycle.saveFailed()
            actionButtons.forEach { $0.isEnabled = true }
            statusLabel.stringValue = "保存失败，截图仍然保留。可重试或选择其他目录。"
            statusLabel.textColor = .systemRed
            let alert = NSAlert()
            alert.messageText = "无法保存 PNG"
            alert.informativeText = error.localizedDescription + "\n截图仍保留在此窗口，不会被下一次截图覆盖。"
            alert.addButton(withTitle: "重试")
            alert.addButton(withTitle: "选择其他目录…")
            alert.addButton(withTitle: "稍后")
            guard let window else { return }
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                if response == .alertFirstButtonReturn { Task { await self.saveAndClose() } }
                if response == .alertSecondButtonReturn { self.onChooseDirectory() }
            }
        }
    }
}

@MainActor
private final class CaptureImageView: NSView {
    private let image: NSImage
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    init(image: NSImage) {
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: image.size))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: nil)
    }
}
