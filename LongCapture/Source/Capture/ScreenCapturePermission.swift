import AppKit
import Combine
import CoreGraphics

@MainActor
final class ScreenCapturePermission: ObservableObject {
    @Published private(set) var isGranted: Bool
    @Published private(set) var isRequesting = false
    private let preflight: () -> Bool
    private let requestAccess: () -> Bool
    private let openSettings: (URL) -> Bool

    init(preflight: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         requestAccess: @escaping () -> Bool = { CGRequestScreenCaptureAccess() },
         openSettings: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.preflight = preflight
        self.requestAccess = requestAccess
        self.openSettings = openSettings
        isGranted = preflight()
    }

    @discardableResult
    func refresh() -> Bool {
        isGranted = preflight()
        return isGranted
    }

    @discardableResult
    func request() -> Bool {
        guard !isRequesting else { return isGranted }
        guard !refresh() else { return true }
        isRequesting = true
        defer { isRequesting = false }
        _ = requestAccess()
        // Approval can require a relaunch; only current-process access unlocks capture.
        return refresh()
    }

    @discardableResult
    func openSystemSettings() -> Bool {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        return openSettings(url)
    }
}
