import AppKit
import Carbon
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let recorder: ShortcutRecordingState
    private let form: SettingsFormState
    private let loginItem: LoginItemSettings

    init(saveDirectory: URL, shortcut: HotKeyShortcut, permission: ScreenCapturePermission, loginItem: LoginItemSettings,
         onRequestPermission: @escaping () -> Void,
         onOpenPermissionSettings: @escaping () -> Void,
         onDirectoryChanged: @escaping (URL) -> Void,
         onShortcutChanged: @escaping (HotKeyShortcut) -> Void,
         onRecordingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.loginItem = loginItem
        recorder = ShortcutRecordingState(onRecordingChanged: onRecordingChanged)
        form = SettingsFormState(saveDirectory: saveDirectory, shortcut: shortcut)
        let view = SettingsView(form: form, recorder: recorder, permission: permission, loginItem: loginItem,
                                onRequestPermission: onRequestPermission,
                                onOpenPermissionSettings: onOpenPermissionSettings,
                                onDirectoryChanged: onDirectoryChanged, onShortcutChanged: onShortcutChanged)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 720),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let surface = NativeGlassView(cornerRadius: 0, interactive: false, legacyMaterial: .windowBackground)
        let container = NSViewController()
        container.view = surface
        container.addChild(hosting)
        let hosted = hosting.view
        hosted.translatesAutoresizingMaskIntoConstraints = false
        surface.contentView.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: surface.contentView.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: surface.contentView.trailingAnchor),
            hosted.topAnchor.constraint(equalTo: surface.contentView.topAnchor),
            hosted.bottomAnchor.constraint(equalTo: surface.contentView.bottomAnchor)
        ])
        window.contentViewController = container
        window.title = "长截图设置"
        window.setContentSize(NSSize(width: 570, height: 720))
        window.contentMinSize = NSSize(width: 530, height: 620)
        NativeUI.prepareWindow(window)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(saveDirectory: URL, shortcut: HotKeyShortcut) {
        form.saveDirectory = saveDirectory
        form.shortcut = shortcut
    }

    override func showWindow(_ sender: Any?) {
        loginItem.refresh()
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(sender)
    }

    func windowWillClose(_ notification: Notification) { recorder.cancel() }
}

@MainActor
private struct SettingsView: View {
    @ObservedObject var form: SettingsFormState
    @ObservedObject var recorder: ShortcutRecordingState
    @ObservedObject var permission: ScreenCapturePermission
    @ObservedObject var loginItem: LoginItemSettings
    let onRequestPermission: () -> Void
    let onOpenPermissionSettings: () -> Void
    let onDirectoryChanged: (URL) -> Void
    let onShortcutChanged: (HotKeyShortcut) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("长截图").font(.title2.weight(.semibold))
                    Text("框选，滚动，留住完整内容。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 8)
            settingsForm
        }
        .background(.clear)
    }

    private var settingsForm: some View {
        Form {
            Section("通用") {
                Toggle(isOn: Binding(get: { loginItem.isRegistered }, set: { enabled in
                    recorder.cancel()
                    loginItem.setEnabled(enabled)
                })) {
                    Text("登录时启动")
                    Text("登录 Mac 后在菜单栏待命，不自动开始截图。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .accessibilityLabel("登录时启动")
                .disabled(loginItem.isChanging)
                HStack {
                    Text(loginItemStatus)
                        .font(.caption)
                        .foregroundStyle(loginItem.status == .requiresApproval ? Color.orange : Color.secondary)
                    Spacer()
                    GlassSettingsButton("打开登录项设置") {
                        recorder.cancel()
                        loginItem.openSystemSettings()
                    }
                    .controlSize(.small)
                }
                if let error = loginItem.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            Section("权限") {
                LabeledContent("屏幕录制") {
                    Label(permission.isGranted ? "已允许" : "当前版本尚未获得权限",
                          systemImage: permission.isGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(permission.isGranted ? Color.green : Color.secondary)
                }
                Text("读取所选区域以拼接长图，不采集音频。允许后若仍不可用，请退出并重新打开应用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("当前应用", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "长截图")
                VStack(alignment: .leading, spacing: 4) {
                    Text(Bundle.main.bundleIdentifier ?? "未知应用标识")
                    Text(Bundle.main.bundleURL.path)
                        .lineLimit(3)
                    Text("系统按应用身份授权，正式版与调试版分别授权。请确认允许的是上方这份应用。")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                HStack {
                    if !permission.isGranted {
                        GlassSettingsButton(permission.isRequesting ? "正在申请…" : "申请屏幕录制权限", prominent: true) {
                            recorder.cancel()
                            onRequestPermission()
                        }
                        .disabled(permission.isRequesting)
                    }
                    GlassSettingsButton("打开系统设置") {
                        recorder.cancel()
                        onOpenPermissionSettings()
                    }
                    GlassSettingsButton("检查状态") { permission.refresh() }
                        .disabled(permission.isRequesting)
                }
            }
            Section("保存") {
                LabeledContent("默认位置") {
                    HStack {
                        Text(form.saveDirectory.path)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        GlassSettingsButton("选择…", action: chooseDirectory)
                    }
                }
                Text("输出原始像素分辨率 PNG，不覆盖同名文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("全局快捷键") {
                LabeledContent("开始 / 完成截图") {
                    ShortcutRecorderButton(shortcut: form.shortcut, recorder: recorder) { value in
                        form.shortcut = value
                        onShortcutChanged(value)
                    }
                    .frame(width: 185, height: 28)
                }
                HStack {
                    Text(recorder.message ?? "点击后按下快捷键；至少包含 Control、Option 或 Command。")
                        .font(.caption)
                        .foregroundStyle(recorder.message == nil ? Color.secondary : Color.orange)
                    Spacer()
                    GlassSettingsButton("恢复默认") {
                        recorder.cancel()
                        form.shortcut = .defaultShortcut
                        onShortcutChanged(form.shortcut)
                    }
                    .controlSize(.small)
                }
            }
            Text("手动滚动 · 仅申请屏幕录制权限 · 不自动复制到剪贴板")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(.clear)
    }

    private var loginItemStatus: String {
        switch loginItem.status {
        case .notRegistered: return "未开启"
        case .enabled: return "已开启"
        case .requiresApproval: return "等待系统允许，请在登录项设置中开启。"
        case .notFound: return "登录项不可用，请使用签名完整的应用。"
        @unknown default: return "无法读取登录项状态，请检查系统设置。"
        }
    }

    private func chooseDirectory() {
        recorder.cancel()
        let panel = NSOpenPanel()
        panel.title = "选择长截图保存位置"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = form.saveDirectory
        if panel.runModal() == .OK, let url = panel.url {
            form.saveDirectory = url
            onDirectoryChanged(url)
        }
    }
}

@MainActor
private struct GlassSettingsButton: View {
    private let title: String
    private let prominent: Bool
    private let action: () -> Void

    init(_ title: String, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            if prominent { Button(title, action: action).buttonStyle(.glassProminent) }
            else { Button(title, action: action).buttonStyle(.glass) }
        } else {
            Button(title, action: action).buttonStyle(.bordered)
        }
    }
}

@MainActor
private final class SettingsFormState: ObservableObject {
    @Published var saveDirectory: URL
    @Published var shortcut: HotKeyShortcut

    init(saveDirectory: URL, shortcut: HotKeyShortcut) {
        self.saveDirectory = saveDirectory
        self.shortcut = shortcut
    }
}

@MainActor
private final class ShortcutRecordingState: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var message: String?
    private let onRecordingChanged: (Bool) -> Void
    private var monitor: Any?
    private weak var recordingWindow: NSWindow?
    private var onRecord: ((HotKeyShortcut) -> Void)?

    init(onRecordingChanged: @escaping (Bool) -> Void) { self.onRecordingChanged = onRecordingChanged }

    func begin(in window: NSWindow, onRecord: @escaping (HotKeyShortcut) -> Void) {
        cancel()
        self.recordingWindow = window
        self.onRecord = onRecord
        recording = true
        message = "正在录入；按 Esc 取消。"
        onRecordingChanged(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            var result: NSEvent? = event
            MainActor.assumeIsolated { result = self.handle(event) }
            return result
        }
    }

    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onRecord = nil
        recordingWindow = nil
        if recording { onRecordingChanged(false) }
        recording = false
        message = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard recording, event.window == recordingWindow else { return event }
        if event.keyCode == 53 { cancel(); return nil }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.intersection([.command, .control, .option]).isEmpty else {
            message = "请同时按住 Control、Option 或 Command；Esc 取消。"
            return nil
        }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let callback = onRecord
        let value = HotKeyShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        cancel()
        callback?(value)
        return nil
    }
}

@MainActor
private struct ShortcutRecorderButton: NSViewRepresentable {
    let shortcut: HotKeyShortcut
    @ObservedObject var recorder: ShortcutRecordingState
    let onRecord: (HotKeyShortcut) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: shortcut.displayName, target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        NativeUI.styleAction(button)
        button.controlSize = .regular
        button.setAccessibilityLabel("录入全局快捷键")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.title = recorder.recording ? "请按快捷键…" : shortcut.displayName
        button.state = recorder.recording ? .on : .off
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ShortcutRecorderButton
        init(parent: ShortcutRecorderButton) { self.parent = parent }

        @objc func clicked(_ sender: NSButton) {
            guard let window = sender.window else { return }
            if parent.recorder.recording { parent.recorder.cancel() }
            else { parent.recorder.begin(in: window, onRecord: parent.onRecord) }
        }
    }
}
