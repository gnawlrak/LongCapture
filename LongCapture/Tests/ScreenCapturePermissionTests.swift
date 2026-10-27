import Foundation
import XCTest
@testable import LongCapture

@MainActor
final class ScreenCapturePermissionTests: XCTestCase {
    func testCheckingStatusDoesNotRequestPermissionOrOpenSettings() async {
        var requests = 0
        var settingsOpened = 0
        let permission = ScreenCapturePermission(preflight: { false }, requestAccess: {
            requests += 1
            return false
        }, openSettings: { _ in settingsOpened += 1; return true })

        XCTAssertFalse(permission.isGranted)
        XCTAssertFalse(permission.refresh())
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(settingsOpened, 0)
    }

    func testAlreadyGrantedDoesNotRequestAgain() async {
        var requests = 0
        let permission = ScreenCapturePermission(preflight: { true }, requestAccess: {
            requests += 1
            return true
        }, openSettings: { _ in XCTFail("No settings needed"); return false })

        XCTAssertTrue(permission.request())
        XCTAssertTrue(permission.isGranted)
        XCTAssertEqual(requests, 0)
    }

    func testRequestRefreshesTheActualRunningProcessAccess() async {
        var granted = false
        var requests = 0
        let permission = ScreenCapturePermission(preflight: { granted }, requestAccess: {
            requests += 1
            granted = true
            return true
        }, openSettings: { _ in false })

        XCTAssertTrue(permission.request())
        XCTAssertTrue(permission.isGranted)
        XCTAssertFalse(permission.isRequesting)
        XCTAssertEqual(requests, 1)
    }

    func testDeniedRequestKeepsCaptureBlockedWithoutOpeningSettingsAutomatically() async {
        var settingsOpened = 0
        let permission = ScreenCapturePermission(preflight: { false }, requestAccess: { false },
            openSettings: { _ in settingsOpened += 1; return true })

        XCTAssertFalse(permission.request())
        XCTAssertFalse(permission.isGranted)
        XCTAssertFalse(permission.isRequesting)
        XCTAssertEqual(settingsOpened, 0)
    }

    func testRequestAcknowledgementAloneDoesNotClaimAccessBeforeRestart() async {
        let permission = ScreenCapturePermission(preflight: { false }, requestAccess: { true },
            openSettings: { _ in false })

        XCTAssertFalse(permission.request(), "The current process must pass preflight before capture")
        XCTAssertFalse(permission.isGranted)
    }

    func testRefreshDetectsExternalGrantAndRevocationWithoutRequesting() async {
        var granted = false
        let permission = ScreenCapturePermission(preflight: { granted }, requestAccess: {
            XCTFail("Refreshing must never prompt")
            return false
        }, openSettings: { _ in false })

        granted = true
        XCTAssertTrue(permission.refresh())
        XCTAssertTrue(permission.isGranted)
        granted = false
        XCTAssertFalse(permission.refresh())
        XCTAssertFalse(permission.isGranted)
    }

    func testReentrantRequestCannotPresentASecondSystemPrompt() async {
        var requests = 0
        var permission: ScreenCapturePermission!
        permission = ScreenCapturePermission(preflight: { false }, requestAccess: {
            requests += 1
            XCTAssertTrue(permission.isRequesting)
            XCTAssertFalse(permission.request())
            return false
        }, openSettings: { _ in false })

        XCTAssertFalse(permission.request())
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(permission.isRequesting)
    }

    func testSystemSettingsUsesScreenRecordingPaneAndReportsOpenFailure() async {
        var openedURLs: [URL] = []
        let permission = ScreenCapturePermission(preflight: { false }, requestAccess: {
            XCTFail("Opening settings must not request permission")
            return false
        }, openSettings: { url in openedURLs.append(url); return false })

        XCTAssertFalse(permission.openSystemSettings())
        XCTAssertEqual(openedURLs.map(\.absoluteString), [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ])
        XCTAssertFalse(permission.isGranted)
    }
}
