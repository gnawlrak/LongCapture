import AppKit
import CoreGraphics

@MainActor
final class AppController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var selectionOverlay: SelectionOverlay?
    private var captureOverlay: CaptureOverlay?
    private var thumbnail: ResultThumbnail?
    private var preview: PreviewWindowController?
    private var settings: SettingsWindowController?
    private var coordinator: SessionCoordinator!
    private var hotKey: HotKey?
    private var shortcut: HotKeyShortcut = .defaultShortcut
    private var originalApplication: NSRunningApplication?
    private var activeResult: SessionResult?
    private var saveTask: Task<URL, Error>?
    private var isExporting = false
    private let screenCapturePermission = ScreenCapturePermission()
    private let loginItemSettings = LoginItemSettings()
    private var isPresentingPermissionAlert = false
    private var isRecordingShortcut = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var saveDirectory = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    private let saveDirectoryKey = "LongCapture.saveDirectory"
    private let shortcutKey = "LongCapture.shortcut"
    private let beginMenuItem = NSMenuItem(title: "开始长截图", action: #selector(beginSelection), keyEquivalent: "")

    override init() {
        super.init()
        if let path = UserDefaults.standard.string(forKey: saveDirectoryKey) {
            saveDirectory = URL(fileURLWithPath: path, isDirectory: true)
        }
        if let data = UserDefaults.standard.data(forKey: shortcutKey),
           let stored = try? JSONDecoder().decode(HotKeyShortcut.self, from: data) { shortcut = stored }
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: "长截图")
        statusItem.button?.toolTip = "长截图 · \(shortcut.displayName)"
        let menu = NSMenu()
        beginMenuItem.target = self
        menu.addItem(beginMenuItem)
        let horizontal = NSMenuItem(title: "开始横向长截图", action: #selector(beginHorizontalSelection), keyEquivalent: "")
        horizontal.target = self
        menu.addItem(horizontal)
        let permissionItem = NSMenuItem(title: "屏幕录制权限…", action: #selector(showPermissionSettings), keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出长截图", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
        coordinator = SessionCoordinator(onResult: { [weak self] in self?.showResult($0) },
            onError: { [weak self] in self?.showCaptureError($0) },
            onUpdate: { [weak self] in self?.captureOverlay?.update($0) },
            onStateChanged: { [weak self] in self?.stateChanged($0) })
        registerShortcut(reportFailure: true)
        observeInterruptions()
    }

    @objc func beginSelection() {
        presentSelection(axis: .vertical)
    }

    @objc private func beginHorizontalSelection() { presentSelection(axis: .horizontal) }

    private func presentSelection(axis: CaptureAxis) {
        if activeResult != nil { openPreview(); return }
        if coordinator.state == .capturing { Task { await coordinator.complete() }; return }
        guard coordinator.state == .idle, !screenCapturePermission.isRequesting, !isPresentingPermissionAlert else { return }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }
        originalApplication = NSWorkspace.shared.frontmostApplication
        guard requestScreenCapturePermission(), coordinator.state == .idle else { return }
        coordinator.prepareForSelection()
        let displayFrame = screen.frame, scale = screen.backingScaleFactor
        selectionOverlay = SelectionOverlay(displayRect: displayFrame, initialAxis: axis, onBegin: { [weak self] rect in
            guard let self else { return }
            let axis = self.selectionOverlay?.selectedAxis ?? axis
            self.selectionOverlay = nil
            do {
                let geometry = try CaptureGeometry(displayID: displayID, displayFrame: displayFrame, selection: rect, scale: scale)
                self.startCapture(geometry: geometry, axis: axis)
            } catch {
                Task { await self.coordinator.cancel(); self.showCaptureError(error) }
            }
        }, onCancel: { [weak self] in
            guard let self else { return }
            self.selectionOverlay = nil
            self.originalApplication?.activate()
            Task { await self.coordinator.cancel() }
        })
        selectionOverlay?.show()
    }

    private func startCapture(geometry: CaptureGeometry, axis: CaptureAxis) {
        selectionOverlay?.close()
        selectionOverlay = nil
        captureOverlay = CaptureOverlay(displayRect: geometry.displayFrame, region: geometry.globalRect,
            onDone: { [weak self] in Task { await self?.coordinator.complete() } },
            onCancel: { [weak self] in
                self?.captureOverlay?.close()
                self?.captureOverlay = nil
                Task { await self?.coordinator.cancel() }
            })
        captureOverlay?.show()
        originalApplication?.activate()
        Task { await coordinator.beginCapture(geometry: geometry, axis: axis) }
    }

    private func shortcutPressed() {
        guard !isRecordingShortcut else { return }
        if activeResult != nil { openPreview() }
        else if let selectionOverlay { selectionOverlay.begin() }
        else if coordinator.state == .capturing { Task { await coordinator.complete() } }
        else if coordinator.state == .idle { beginSelection() }
    }

    private func stateChanged(_ state: SessionCoordinator.State) {
        switch state {
        case .idle:
            captureOverlay?.close(); captureOverlay = nil
            beginMenuItem.title = "开始长截图"
        case .capturing:
            captureOverlay?.setReady()
            beginMenuItem.title = "完成长截图"
        case .finishing:
            captureOverlay?.setFinishing()
            beginMenuItem.title = "正在合成…"
        case .result: beginMenuItem.title = "打开待处理截图"
        case .selecting: beginMenuItem.title = "正在框选…"
        case .starting: beginMenuItem.title = "正在准备…"
        }
    }

    @objc func showSettings() {
        screenCapturePermission.refresh()
        if let settings { settings.showWindow(nil); NSApp.activate(ignoringOtherApps: true); return }
        settings = SettingsWindowController(saveDirectory: saveDirectory, shortcut: shortcut,
            permission: screenCapturePermission, loginItem: loginItemSettings,
            onRequestPermission: { [weak self] in _ = self?.requestScreenCapturePermission() },
            onOpenPermissionSettings: { [weak self] in self?.openScreenCaptureSettings() },
            onDirectoryChanged: { [weak self] url in self?.setSaveDirectory(url) },
            onShortcutChanged: { [weak self] value in self?.changeShortcut(value) },
            onRecordingChanged: { [weak self] recording in
                guard let self else { return }
                self.isRecordingShortcut = recording
                if recording { self.hotKey?.unregister() }
                else { self.registerShortcut(reportFailure: true) }
            })
        settings?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showPermissionSettings() { showSettings() }

    private func requestScreenCapturePermission() -> Bool {
        guard !screenCapturePermission.isRequesting, !isPresentingPermissionAlert else { return false }
        if screenCapturePermission.refresh() { return true }
        NSApp.activate(ignoringOtherApps: true)
        if screenCapturePermission.request() { return true }
        presentPermissionGuidance()
        return false
    }

    private func presentPermissionGuidance() {
        guard !isPresentingPermissionAlert else { return }
        isPresentingPermissionAlert = true
        defer { isPresentingPermissionAlert = false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要屏幕录制权限"
        let applicationName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "长截图"
        alert.informativeText = "请在系统设置 → 隐私与安全性 → 屏幕录制（或屏幕与系统录音录制）中允许「\(applicationName)」。正式版与调试版分别授权；设置页会显示当前应用路径。若开关已打开仍不可用，请移除旧条目后重新添加当前应用，再退出重开。应用只读取所选区域，不采集音频。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "暂不")
        if alert.runModal() == .alertFirstButtonReturn { openScreenCaptureSettings() }
    }

    private func openScreenCaptureSettings() {
        if !screenCapturePermission.openSystemSettings() {
            alert(title: "无法打开系统设置", message: "请手动打开系统设置 → 隐私与安全性 → 屏幕录制，并允许「长截图」。")
        }
    }

    private func changeShortcut(_ value: HotKeyShortcut) {
        shortcut = value
        settings?.update(saveDirectory: saveDirectory, shortcut: value)
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: shortcutKey) }
        if !isRecordingShortcut { registerShortcut(reportFailure: true) }
    }

    private func registerShortcut(reportFailure: Bool) {
        hotKey?.unregister()
        let key = HotKey(shortcut: shortcut) { [weak self] in
            Task { @MainActor in self?.shortcutPressed() }
        }
        hotKey = key
        do { try key.register() }
        catch {
            if reportFailure {
                DispatchQueue.main.async { [weak self] in self?.alert(title: "快捷键不可用", message: error.localizedDescription) }
            }
        }
        statusItem.button?.toolTip = "长截图 · \(shortcut.displayName)"
    }

    private func setSaveDirectory(_ url: URL) {
        saveDirectory = url
        settings?.update(saveDirectory: url, shortcut: shortcut)
        UserDefaults.standard.set(url.path, forKey: saveDirectoryKey)
    }

    private func showResult(_ result: SessionResult) {
        guard activeResult == nil else { return }
        activeResult = result
        captureOverlay?.close(); captureOverlay = nil
        let warning = result.incomplete ? "不完整：\(result.notice ?? "仅保留已确认部分。")" : result.notice
        thumbnail = ResultThumbnail(image: displayImage(result), screenFrame: result.screenFrame, warning: warning,
            pageCount: result.document.pages.count,
            onOpen: { [weak self] in self?.openPreview() }, onAutoSave: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    do { _ = try await self.saveResult() }
                    catch { self.thumbnail?.showSaveFailure(error.localizedDescription) }
                }
            })
        thumbnail?.show()
    }

    private func displayImage(_ result: SessionResult) -> NSImage {
        NSImage(cgImage: result.image, size: NSSize(width: CGFloat(result.image.width), height: CGFloat(result.image.height)))
    }

    private func openPreview() {
        guard saveTask == nil, let result = activeResult else { return }
        thumbnail?.finish(); thumbnail = nil
        if let preview { preview.show(); return }
        let warning = result.incomplete ? "不完整：\(result.notice ?? "仅保留已确认部分。")" : result.notice
        preview = PreviewWindowController(image: displayImage(result), warning: warning,
            onSave: { [weak self] in
                guard let self else { throw CaptureSessionError.cancelled }
                return try await self.saveResult()
            }, onDiscard: { [weak self] in self?.discardResult() ?? false },
            onChooseDirectory: { [weak self] in self?.chooseSaveDirectory() },
            pageCount: result.document.pages.count, axis: result.document.axis,
            loadPage: { index in
                let image = try await Task.detached(priority: .userInitiated) {
                    try result.document.pages[index].load()
                }.value
                return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }, onExport: { [weak self] options in
                guard let self else { throw CaptureSessionError.cancelled }
                return try await self.exportSegments(options)
            })
        preview?.show()
    }

    private func saveResult() async throws -> URL {
        guard !isExporting else { throw SegmentExportError.busy }
        if let saveTask { return try await saveTask.value }
        guard let result = activeResult else { throw CaptureSessionError.noFrames }
        let directory = saveDirectory
        let task = Task.detached(priority: .userInitiated) {
            try ResultStore().save(document: result.document, to: directory, capturedAt: result.capturedAt)
        }
        saveTask = task
        do {
            let url = try await task.value
            saveTask = nil
            thumbnail?.finish(); thumbnail = nil
            preview?.closeAfterResolution(); preview = nil
            activeResult = nil
            coordinator.resolveResult()
            return url
        } catch {
            saveTask = nil
            throw error
        }
    }

    private func exportSegments(_ options: SegmentExportOptions) async throws -> URL {
        guard saveTask == nil, let result = activeResult else { throw SegmentExportError.busy }
        let directory = saveDirectory
        isExporting = true
        let task = Task.detached(priority: .userInitiated) {
            try ResultStore().save(document: result.document, to: directory, capturedAt: result.capturedAt, segments: options)
        }
        saveTask = task
        defer { saveTask = nil; isExporting = false }
        return try await task.value
    }

    private func discardResult() -> Bool {
        guard saveTask == nil else { return false }
        thumbnail?.finish(); thumbnail = nil
        preview?.closeAfterResolution(); preview = nil
        activeResult = nil
        coordinator.resolveResult()
        return true
    }

    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = saveDirectory
        panel.prompt = "选择保存目录"
        if panel.runModal() == .OK, let url = panel.url { setSaveDirectory(url) }
    }

    private func showCaptureError(_ error: Error) {
        captureOverlay?.close(); captureOverlay = nil
        selectionOverlay?.close(); selectionOverlay = nil
        if let captureError = error as? ScreenCaptureError, case .permissionDenied = captureError {
            screenCapturePermission.refresh()
            presentPermissionGuidance()
            return
        }
        alert(title: "长截图未完成", message: error.localizedDescription)
    }

    private func alert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func observeInterruptions() {
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.screenCapturePermission.refresh()
                    self?.loginItemSettings.refresh()
                }
            }))
        observers.append((center, center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.interrupted("显示器配置发生变化。") }
            }))
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.interrupted("系统或屏幕进入睡眠。") }
            }))
        }
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.interrupted("屏幕已锁定。") }
            }))
    }

    private func interrupted(_ message: String) async {
        selectionOverlay?.close(); selectionOverlay = nil
        await coordinator.interrupt(reason: message)
    }

    /// Returning false keeps a failed save or an interrupted capture alive instead of losing it on Quit.
    func requestTermination() async -> Bool {
        if isExporting {
            alert(title: "正在分段导出", message: "请等待导出完成后再退出，原始长图仍保留。")
            return false
        }
        if coordinator.state == .starting || coordinator.state == .capturing || coordinator.state == .finishing {
            alert(title: "请先完成或取消截图", message: "当前正在采集或合成长图，处理完成后再退出。")
            return false
        }
        if activeResult != nil {
            do { _ = try await saveResult() }
            catch { openPreview(); alert(title: "保存失败，应用尚未退出", message: error.localizedDescription); return false }
        }
        await coordinator.cancel()
        return true
    }

    @objc func quit() { NSApp.terminate(nil) }
}
