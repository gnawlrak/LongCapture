import Combine
import ServiceManagement

/// System registration, not a separate preference, is the source of truth.
@MainActor
final class LoginItemSettings: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var isChanging = false
    @Published private(set) var errorMessage: String?
    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () throws -> Void
    private let openSettings: () -> Void

    init(readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
         unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() },
         openSettings: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }) {
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
        self.openSettings = openSettings
        status = readStatus()
    }

    // A pending request stays on so the user can cancel it; the label distinguishes approval from enabled.
    var isRegistered: Bool { status == .enabled || status == .requiresApproval }

    func refresh() {
        let current = readStatus()
        if current != status { errorMessage = nil }
        status = current
    }

    func setEnabled(_ enabled: Bool) {
        guard !isChanging else { return }
        refresh()
        errorMessage = nil
        guard enabled != isRegistered else { return }
        isChanging = true
        defer { isChanging = false }
        do {
            if enabled { try register() }
            else { try unregister() }
            refresh()
            if enabled != isRegistered {
                errorMessage = "系统尚未确认更改，请检查登录项设置后重试。"
            }
        } catch {
            refresh()
            errorMessage = "无法\(enabled ? "开启" : "关闭")登录时启动：\(error.localizedDescription)"
        }
    }

    func openSystemSettings() { openSettings() }
}
