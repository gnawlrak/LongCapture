import AppKit

@MainActor
final class PreviewWindowController: NSWindowController, NSWindowDelegate {
    private var image: NSImage
    private let onSave: () async throws -> URL
    private let onDiscard: () -> Bool
    private let onChooseDirectory: () -> Void
    private let onShare: ((NSImage, NSView) -> Void)?
    private var sharePicker: NSSharingServicePicker?
    private let lifecycle = ResultLifecycle(presentation: .preview)
    private var resolved = false
    private var actionButtons: [NSButton] = []
    private let statusLabel = NSTextField(labelWithString: "原始像素 PNG · 关闭窗口也会保存")
    private let scrollView = NSScrollView()
    private let zoomMenu = NSPopUpButton()
    private let pageMenu = NSPopUpButton()
    private let dimensions = NSTextField(labelWithString: "")
    private let pageCount: Int
    private let axis: CaptureAxis
    private let loadPage: ((Int) async throws -> NSImage)?
    private let onExport: ((SegmentExportOptions) async throws -> URL)?
    private var isExporting = false
    private var isLoadingPage = false
    private var isTransferring = false
    private var currentPageIndex = 0

    init(image: NSImage, warning: String? = nil,
         onSave: @escaping () async throws -> URL, onDiscard: @escaping () -> Bool,
         onChooseDirectory: @escaping () -> Void, pageCount: Int = 1, axis: CaptureAxis = .vertical,
         loadPage: ((Int) async throws -> NSImage)? = nil,
         onExport: ((SegmentExportOptions) async throws -> URL)? = nil,
         onShare: ((NSImage, NSView) -> Void)? = nil) {
        self.image = image
        self.onSave = onSave
        self.onDiscard = onDiscard
        self.onChooseDirectory = onChooseDirectory
        self.onShare = onShare
        self.pageCount = pageCount; self.loadPage = loadPage; self.onExport = onExport
        self.axis = axis
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 650),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "长截图预览"
        window.minSize = NSSize(width: 700, height: 460)
        window.isReleasedWhenClosed = false
        NativeUI.prepareWindow(window)
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
        fitDefault()
    }

    func closeAfterResolution() {
        guard !resolved else { return }
        resolved = true
        lifecycle.saved()
        window?.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !resolved else { return true }
        guard !isExporting, !isTransferring else { return false }
        Task { await saveAndClose() }
        return false
    }

    private func buildContent(warning: String?) {
        guard let window else { return }
        let surface = NativeGlassView(cornerRadius: 0, interactive: false, legacyMaterial: .windowBackground)
        window.contentView = surface
        let root = surface.contentView
        dimensions.stringValue = "\(Int(image.size.width)) × \(Int(image.size.height)) 像素"
        dimensions.textColor = .secondaryLabelColor
        dimensions.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let copy = NSButton(title: "复制", image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)!,
                            target: self, action: #selector(copyClicked))
        NativeUI.styleAction(copy)
        copy.toolTip = "复制当前显示的一张长图，不是整组"
        copy.keyEquivalent = "c"
        copy.keyEquivalentModifierMask = [.command]
        let share = NSButton(title: "分享", image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)!,
                             target: self, action: #selector(shareClicked(_:)))
        NativeUI.styleAction(share)
        share.toolTip = "使用 macOS 原生分享菜单发送当前一张的副本；原图仍需保存或明确丢弃"
        for (name, tag) in [(axis == .horizontal ? "适合高度" : "适合宽度", 0), ("25%", 25), ("50%", 50), ("100%", 100), ("200%", 200), ("400%", 400)] {
            zoomMenu.addItem(withTitle: name)
            zoomMenu.lastItem?.tag = tag
        }
        zoomMenu.target = self
        zoomMenu.action = #selector(zoomChanged)
        NativeUI.styleAction(zoomMenu)
        zoomMenu.setAccessibilityLabel("预览缩放")
        zoomMenu.controlSize = .large
        let heading = NSTextField(labelWithString: "长截图")
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        let imageInfo = NSStackView(views: [heading, dimensions])
        imageInfo.orientation = .vertical
        imageInfo.alignment = .leading
        imageInfo.spacing = 3
        for index in 0..<pageCount { pageMenu.addItem(withTitle: "第 \(index + 1) / \(pageCount) 张") }
        pageMenu.target = self
        pageMenu.action = #selector(pageChanged)
        pageMenu.setAccessibilityLabel("长截图分页，按阅读顺序排列")
        NativeUI.styleAction(pageMenu)
        pageMenu.isHidden = pageCount < 2
        let top = NSStackView(views: [imageInfo, NSView(), pageMenu, copy, share, zoomMenu])
        top.orientation = .horizontal
        top.spacing = 12
        top.alignment = .centerY

        let document = makeImageView(image)
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.01
        scrollView.maxMagnification = 8
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 14
        scrollView.layer?.masksToBounds = true
        scrollView.setAccessibilityLabel("长截图原始图像，可滚动及缩放，也可拖出当前图片的 PNG 副本")

        let folder = NSButton(title: "保存位置…", target: self, action: #selector(chooseDirectoryClicked))
        let discard = NSButton(title: "丢弃", target: self, action: #selector(discardClicked))
        let save = NSButton(title: "保存 PNG", target: self, action: #selector(saveClicked))
        if pageCount > 1 { save.title = "保存全部 PNG" }
        let export = NSButton(title: "分段导出…", target: self, action: #selector(exportClicked))
        NativeUI.styleAction(export)
        export.image = NSImage(systemSymbolName: axis == .horizontal ? "rectangle.split.3x1" : "rectangle.split.1x3", accessibilityDescription: nil)
        export.imagePosition = .imageLeading
        export.toolTip = "另存适合分享的短图，不替代原始长图；原图仍需保存或明确丢弃"
        export.isEnabled = onExport != nil
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = [.command]
        let done = NSButton(title: "完成", target: self, action: #selector(saveClicked))
        done.keyEquivalent = "\r"
        for button in [folder, discard, save] { NativeUI.styleAction(button) }
        NativeUI.styleAction(done, prominent: true)
        folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        discard.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        save.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
        for button in [folder, discard, save] { button.imagePosition = .imageLeading }
        discard.toolTip = "丢弃未保存的原始截图；已明确导出的副本不会删除"
        actionButtons = [folder, discard, save, done, copy, share, export]
        let actions = NSStackView(views: [folder, export, NSView(), discard, save, done])
        actions.orientation = .horizontal
        actions.spacing = 10
        actions.alignment = .centerY
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if pageCount > 1 { statusLabel.stringValue = "共 \(pageCount) 张，按\(axis == .horizontal ? "从左到右" : "从上到下")排列 · 关闭窗口保存全部" }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 14
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
        statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(actions)
        for view in [top, scrollView, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        top.heightAnchor.constraint(equalToConstant: 46).isActive = true
        actions.heightAnchor.constraint(equalToConstant: 36).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])
    }

    private func fitDefault() {
        window?.contentView?.layoutSubtreeIfNeeded()
        let available = max(1, (axis == .horizontal ? scrollView.contentSize.height : scrollView.contentSize.width) - 4)
        let length = axis == .horizontal ? image.size.height : image.size.width
        scrollView.magnification = min(1, max(0.01, available / max(1, length)))
        scrollView.documentView?.scroll(.zero)
        zoomMenu.selectItem(withTag: 0)
    }

    @objc private func zoomChanged() {
        guard let item = zoomMenu.selectedItem else { return }
        if item.tag == 0 { fitDefault() }
        else { scrollView.magnification = CGFloat(item.tag) / 100 }
    }

    @objc private func copyClicked() {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        statusLabel.stringValue = "已复制到剪贴板 · 原始像素 PNG"
    }

    @objc private func shareClicked(_ sender: NSButton) {
        guard !resolved, !isExporting, !isLoadingPage, !isTransferring, lifecycle.state == .preview,
              let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let sharedImage = NSImage(cgImage: pixels, size: NSSize(width: pixels.width, height: pixels.height))
        statusLabel.stringValue = "分享当前第 \(currentPageIndex + 1) 张的副本 · 原图仍需保存或丢弃"
        if let onShare { onShare(sharedImage, sender) }
        else {
            let picker = NSSharingServicePicker(items: [sharedImage])
            sharePicker = picker
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    private func makeImageView(_ image: NSImage) -> CaptureImageView {
        let view = CaptureImageView(image: image)
        view.toolTip = "拖出当前一张的原始像素 PNG 副本；不会替代保存或丢弃"
        view.canDrag = { [weak self] in
            guard let self else { return false }
            return !self.resolved && !self.isExporting && !self.isLoadingPage && self.lifecycle.state == .preview
        }
        view.onInteraction = { [weak self] active in
            guard let self else { return }
            self.isTransferring = active
            let enabled = !active && !self.resolved && !self.isExporting && self.lifecycle.state == .preview
            self.setActionsEnabled(enabled)
            self.pageMenu.isEnabled = enabled && !self.isLoadingPage
        }
        return view
    }

    private func setActionsEnabled(_ enabled: Bool) {
        for button in actionButtons {
            let imageAction = button.action == #selector(shareClicked(_:)) || button.action == #selector(copyClicked)
            let exportAction = button.action == #selector(exportClicked)
            button.isEnabled = enabled && (!imageAction || !isLoadingPage) && (!exportAction || onExport != nil)
        }
    }

    @objc private func chooseDirectoryClicked() { onChooseDirectory() }
    @objc private func saveClicked() { Task { await saveAndClose() } }

    @objc private func discardClicked() {
        guard !isExporting, !isTransferring, lifecycle.state != .saving, lifecycle.state != .resolved,
              onDiscard(), lifecycle.discard() else { return }
        guard !resolved else { return }
        resolved = true
        window?.close()
    }

    private func saveAndClose() async {
        guard !isExporting, !isTransferring, lifecycle.beginSave(), !resolved else { return }
        setActionsEnabled(false)
        pageMenu.isEnabled = false
        statusLabel.stringValue = "正在保存 PNG…"
        do {
            _ = try await onSave()
            lifecycle.saved()
            closeAfterResolution()
        } catch {
            lifecycle.saveFailed()
            setActionsEnabled(true)
            pageMenu.isEnabled = !isLoadingPage
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

    @objc private func pageChanged() {
        guard !resolved, !isLoadingPage, !isExporting, !isTransferring, lifecycle.state == .preview, let loadPage else { return }
        let index = pageMenu.indexOfSelectedItem
        isLoadingPage = true
        setActionsEnabled(true)
        pageMenu.isEnabled = false
        statusLabel.stringValue = "正在读取第 \(index + 1) 张…"
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isLoadingPage = false
                self.pageMenu.isEnabled = !self.isExporting && self.lifecycle.state == .preview && !self.resolved
                self.setActionsEnabled(!self.isExporting && !self.isTransferring && self.lifecycle.state == .preview && !self.resolved)
            }
            do {
                let image = try await loadPage(index)
                guard !self.resolved else { return }
                self.image = image
                self.currentPageIndex = index
                self.scrollView.documentView = self.makeImageView(image)
                self.dimensions.stringValue = "\(Int(image.size.width)) × \(Int(image.size.height)) 像素"
                if !self.isExporting && self.lifecycle.state == .preview {
                    self.statusLabel.stringValue = "第 \(index + 1) / \(self.pageCount) 张 · 复制仅复制当前张，保存会保存全部"
                }
                self.fitDefault()
            } catch {
                self.pageMenu.selectItem(at: self.currentPageIndex)
                guard !self.resolved, !self.isExporting, self.lifecycle.state == .preview else { return }
                self.statusLabel.stringValue = "读取失败，结果仍保留：\(error.localizedDescription)"
                self.statusLabel.textColor = .systemRed
            }
        }
    }

    @objc private func exportClicked() {
        guard !resolved, !isExporting, !isTransferring, lifecycle.state == .preview, onExport != nil, let window else { return }
        let alert = NSAlert()
        alert.messageText = "另存分段 PNG"
        alert.informativeText = "按原始像素\(axis.lengthTitle)分段，保留相邻重叠，方便分享。所有续张都会导出到同一个新文件夹；原始长图不变。"
        let height = NSTextField(string: "2400")
        let overlap = NSTextField(string: "120")
        height.setAccessibilityLabel("分段\(axis.lengthTitle)，像素")
        overlap.setAccessibilityLabel("相邻重叠，像素")
        let form = NSStackView(views: [NSTextField(labelWithString: "分段\(axis.lengthTitle)（256–20,000 像素）"), height,
                                      NSTextField(labelWithString: "重叠像素（不超过分段长度的一半）"), overlap])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        form.frame = CGRect(x: 0, y: 0, width: 320, height: 132)
        height.widthAnchor.constraint(equalToConstant: 300).isActive = true
        overlap.widthAnchor.constraint(equalToConstant: 300).isActive = true
        alert.accessoryView = form
        alert.addButton(withTitle: "导出")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            guard let h = Int(height.stringValue), let o = Int(overlap.stringValue) else {
                self.statusLabel.stringValue = SegmentExportError.invalidOptions.localizedDescription
                return
            }
            let options = SegmentExportOptions(length: h, overlap: o)
            do { _ = try options.ranges(imageLength: 1) }
            catch { self.statusLabel.stringValue = error.localizedDescription; return }
            Task { await self.exportSegments(options) }
        }
    }

    func exportSegments(_ options: SegmentExportOptions) async {
        guard !resolved, !isExporting, !isTransferring, lifecycle.state == .preview, let onExport else { return }
        isExporting = true
        setActionsEnabled(false)
        pageMenu.isEnabled = false
        statusLabel.stringValue = "正在另存分段 PNG，原始长图仍保留…"
        defer {
            isExporting = false
            setActionsEnabled(true)
            pageMenu.isEnabled = !isLoadingPage
        }
        do {
            let url = try await onExport(options)
            statusLabel.stringValue = "已导出：\(url.lastPathComponent) · 原始长图仍需保存或丢弃"
            statusLabel.toolTip = url.path
            statusLabel.textColor = .secondaryLabelColor
        } catch {
            statusLabel.stringValue = "分段导出失败，原图仍保留：\(error.localizedDescription)"
            statusLabel.textColor = .systemRed
        }
    }
}

@MainActor
private final class CaptureImageView: ResultDragSourceView {
    private let image: NSImage
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    init(image: NSImage) {
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: image.size), image: image)
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
