import AppKit

/// The border is wholly click-through; only the separate nonactivating toolbar receives clicks.
@MainActor
final class CaptureOverlay {
    private let borderWindow: NSWindow
    private let toolbar: NSPanel
    private let status = NSTextField(labelWithString: "正在准备选区…")
    private let detail = NSTextField(labelWithString: "无需切换窗口，在原应用中手动滚动")
    private let stateIcon = NativeUI.symbol("rectangle.dashed")
    private let onDone: () -> Void
    private let onCancel: () -> Void
    private var doneButton: NSButton!
    private let referenceView = NSImageView()
    private let recoveryRow = NSStackView()
    private var normalToolbarFrame: CGRect = .zero
    private let displayRect: CGRect
    private var recoveredUntil: TimeInterval = 0

    init(displayRect: CGRect, region: CGRect, onDone: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onDone = onDone
        self.onCancel = onCancel
        self.displayRect = displayRect
        borderWindow = NSWindow(contentRect: region.insetBy(dx: -2, dy: -2), styleMask: .borderless, backing: .buffered, defer: false)
        borderWindow.isOpaque = false
        borderWindow.backgroundColor = .clear
        borderWindow.ignoresMouseEvents = true
        borderWindow.level = .floating
        borderWindow.sharingType = .none
        borderWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        borderWindow.isReleasedWhenClosed = false
        borderWindow.contentView = CaptureBorder(frame: CGRect(origin: .zero, size: borderWindow.frame.size))
        let width = min(560.0, displayRect.width - 24)
        let x = min(max(region.midX - width / 2, displayRect.minX + 12), displayRect.maxX - width - 12)
        let y: CGFloat
        if region.minY - 84 > displayRect.minY + 24 { y = region.minY - 84 }
        else if region.maxY + 84 < displayRect.maxY - 24 { y = region.maxY + 12 }
        else { y = displayRect.minY + 30 }
        toolbar = NSPanel(contentRect: CGRect(x: x, y: y, width: width, height: 72),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        toolbar.isOpaque = false
        toolbar.backgroundColor = .clear
        toolbar.level = .floating
        toolbar.hasShadow = true
        toolbar.hidesOnDeactivate = false
        toolbar.becomesKeyOnlyIfNeeded = true
        toolbar.isReleasedWhenClosed = false
        toolbar.sharingType = .none
        toolbar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        normalToolbarFrame = toolbar.frame
        let background = NativeGlassView(cornerRadius: 24)
        background.frame = CGRect(origin: .zero, size: toolbar.frame.size)
        toolbar.contentView = background
        status.font = .systemFont(ofSize: 13, weight: .semibold)
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.toolTip = "手动滚动原应用。快捷键再次按下可完成；匹配暂停时，请向回滚动恢复。"
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let labels = NSStackView(views: [status, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelPressed))
        NativeUI.styleAction(cancel)
        doneButton = NSButton(title: "完成", target: self, action: #selector(donePressed))
        NativeUI.styleAction(doneButton, prominent: true)
        doneButton.isEnabled = false
        let stack = NSStackView(views: [stateIcon, labels, NSView(), cancel, doneButton])
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        referenceView.imageScaling = .scaleProportionallyUpOrDown
        referenceView.setAccessibilityLabel("最后确认的画面参考图")
        referenceView.translatesAutoresizingMaskIntoConstraints = false
        let recoveryHelp = NSTextField(wrappingLabelWithString: "最后确认的画面\n往回滚到左侧内容，再小幅滚动继续。\n无法确认时不会跳过内容。")
        recoveryHelp.font = .systemFont(ofSize: 12)
        recoveryRow.addArrangedSubview(referenceView)
        recoveryRow.addArrangedSubview(recoveryHelp)
        recoveryRow.spacing = 12
        recoveryRow.isHidden = true
        let column = NSStackView(views: [stack, recoveryRow])
        column.orientation = .vertical
        column.spacing = 12
        column.alignment = .leading
        column.translatesAutoresizingMaskIntoConstraints = false
        background.contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: background.contentView.leadingAnchor, constant: 18),
            column.trailingAnchor.constraint(equalTo: background.contentView.trailingAnchor, constant: -14),
            column.centerYAnchor.constraint(equalTo: background.contentView.centerYAnchor),
            stack.widthAnchor.constraint(equalTo: column.widthAnchor),
            recoveryRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            referenceView.widthAnchor.constraint(equalToConstant: 160),
            referenceView.heightAnchor.constraint(equalToConstant: 94)
        ])
    }

    func show() { borderWindow.orderFrontRegardless(); toolbar.orderFrontRegardless() }
    func close() { borderWindow.close(); toolbar.close() }

    func setReady() {
        doneButton.isEnabled = true
        status.stringValue = "请手动滚动 · 再按快捷键完成"
        stateIcon.contentTintColor = .controlAccentColor
    }

    func setFinishing() {
        showReference(nil)
        doneButton.isEnabled = false
        status.stringValue = "正在处理尾帧并合成长图…"
        detail.stringValue = "请稍候，正在保留最后一帧"
        setSymbol("hourglass", color: .secondaryLabelColor)
    }

    func update(_ update: StitchUpdate) {
        doneButton.isEnabled = true
        status.textColor = update.action == .needsRecovery ? .systemOrange : .labelColor
        if update.axis == .automatic && update.action != .needsRecovery {
            status.stringValue = "请直接滚动 · 正在自动识别方向"
            detail.stringValue = "确认后锁定横向或纵向，无需手动切换"
            status.toolTip = "沿一个方向滚动；轻微抖动不会立即锁定，已确认的微小位移会在结束时保留。"
            setSymbol("arrow.up.left.and.arrow.down.right", color: .controlAccentColor)
            showReference(nil)
            return
        }
        let extent = "\(update.axis.title)第 \(update.pageCount) 张 · \(update.height) / \(update.maximumHeight) px"
        if update.action == .needsRecovery {
            status.stringValue = "匹配暂停，请往回滚动恢复"
            detail.stringValue = update.message ?? (update.axis == .automatic
                ? "尚未锁定滚动方向 · 起始画面仍保留"
                : "\(extent) · 已确认内容仍保留")
            setSymbol("arrow.uturn.backward", color: .systemOrange)
            showReference(update.referenceImage)
        } else {
            showReference(nil)
            if update.progress == .recovered { recoveredUntil = ProcessInfo.processInfo.systemUptime + 2 }
            switch update.progress {
            case .revisiting: status.stringValue = "反向回看 · 已有内容不变"
            case .continued: status.stringValue = "已自动续到第 \(update.pageCount) 张 · 继续滚动"
            default:
                if ProcessInfo.processInfo.systemUptime < recoveredUntil { status.stringValue = "已恢复匹配 · 可继续滚动" }
                else if update.progress == .unchanged { status.stringValue = "画面未新增 · 等待滚动" }
                else { status.stringValue = "正在增长 · 手动滚动" }
            }
            detail.stringValue = extent + (update.height * 100 >= update.maximumHeight * 85
                ? " · 接近单张上限，将自动续张" : " · 再按快捷键完成")
            setSymbol(update.progress == .revisiting ? "arrow.uturn.backward" : update.axis == .horizontal ? "arrow.left.and.right" : "arrow.up.and.down", color: .controlAccentColor)
        }
        status.toolTip = update.message ?? "再次按截图快捷键或点完成，结束采集。"
    }

    private func showReference(_ image: CGImage?) {
        let show = image != nil
        referenceView.image = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        guard recoveryRow.isHidden == show else { return }
        recoveryRow.isHidden = !show
        var frame = normalToolbarFrame
        if show {
            frame.size.height = 188
            frame.origin.y = max(displayRect.minY + 12, min(normalToolbarFrame.maxY - 188, displayRect.maxY - 200))
        }
        toolbar.setFrame(frame, display: true)
    }

    @objc private func donePressed() { onDone() }
    @objc private func cancelPressed() { onCancel() }

    private func setSymbol(_ name: String, color: NSColor) {
        stateIcon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        stateIcon.contentTintColor = color
    }
}

private final class CaptureBorder: NSView {
    override func draw(_ dirtyRect: CGRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.95).setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()
    }
}
