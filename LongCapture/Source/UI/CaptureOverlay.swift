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

    init(displayRect: CGRect, region: CGRect, onDone: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onDone = onDone
        self.onCancel = onCancel
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
        background.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.contentView.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: background.contentView.trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: background.contentView.centerYAnchor)
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
        doneButton.isEnabled = false
        status.stringValue = "正在处理尾帧并合成长图…"
        detail.stringValue = "请稍候，正在保留最后一帧"
        setSymbol("hourglass", color: .secondaryLabelColor)
    }

    func update(_ update: StitchUpdate) {
        doneButton.isEnabled = true
        status.textColor = update.action == .needsRecovery ? .systemOrange : .labelColor
        if update.action == .needsRecovery {
            status.stringValue = "匹配暂停，请往回滚动恢复"
            detail.stringValue = "已确认内容仍保留，不会跳过缺失部分"
            setSymbol("arrow.uturn.backward", color: .systemOrange)
        } else {
            status.stringValue = "已确认 \(update.height) px · 手动滚动"
            detail.stringValue = "再次按截图快捷键或点完成，结束采集"
            setSymbol("arrow.up.and.down", color: .controlAccentColor)
        }
        status.toolTip = update.message ?? "再次按截图快捷键或点完成，结束采集。"
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
