import AppKit

/// The border is wholly click-through; only the separate nonactivating toolbar receives clicks.
final class CaptureOverlay {
    private let borderWindow: NSWindow
    private let toolbar: NSPanel
    private let status = NSTextField(labelWithString: "正在准备选区…")
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
        let width = min(500.0, displayRect.width - 24)
        let x = min(max(region.midX - width / 2, displayRect.minX + 12), displayRect.maxX - width - 12)
        let y: CGFloat
        if region.minY - 64 > displayRect.minY + 24 { y = region.minY - 64 }
        else if region.maxY + 64 < displayRect.maxY - 24 { y = region.maxY + 12 }
        else { y = displayRect.minY + 30 }
        toolbar = NSPanel(contentRect: CGRect(x: x, y: y, width: width, height: 52),
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
        let background = NSVisualEffectView(frame: CGRect(origin: .zero, size: toolbar.frame.size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        toolbar.contentView = background
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.toolTip = "手动滚动原应用。快捷键再次按下可完成；匹配暂停时，请向回滚动恢复。"
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded
        doneButton = NSButton(title: "完成", target: self, action: #selector(donePressed))
        doneButton.bezelStyle = .rounded
        doneButton.isEnabled = false
        let stack = NSStackView(views: [status, cancel, doneButton])
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])
    }

    func show() { borderWindow.orderFrontRegardless(); toolbar.orderFrontRegardless() }
    func close() { borderWindow.close(); toolbar.close() }

    func setReady() {
        doneButton.isEnabled = true
        status.stringValue = "请手动滚动 · 再按快捷键完成"
    }

    func setFinishing() {
        doneButton.isEnabled = false
        status.stringValue = "正在处理尾帧并合成长图…"
    }

    func update(_ update: StitchUpdate) {
        doneButton.isEnabled = true
        status.textColor = update.action == .needsRecovery ? .systemOrange : .labelColor
        if update.action == .needsRecovery {
            status.stringValue = "匹配暂停，请往回滚动恢复"
        } else {
            status.stringValue = "已确认 \(update.height) px · 手动滚动"
        }
        status.toolTip = update.message ?? "再次按截图快捷键或点完成，结束采集。"
    }

    @objc private func donePressed() { onDone() }
    @objc private func cancelPressed() { onCancel() }
}

private final class CaptureBorder: NSView {
    override func draw(_ dirtyRect: CGRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.95).setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()
    }
}
