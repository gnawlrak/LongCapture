import Foundation
import ServiceManagement
import XCTest
@testable import LongCapture

@MainActor
final class LoginItemSettingsTests: XCTestCase {
    func testInitializationAndRefreshNeverChangeTheLoginItem() {
        for status in [SMAppService.Status.notRegistered, .enabled, .requiresApproval, .notFound] {
            let settings = LoginItemSettings(readStatus: { status }, register: {
                XCTFail("Reading status must not register")
            }, unregister: {
                XCTFail("Reading status must not unregister")
            }, openSettings: { XCTFail("Reading status must not open System Settings") })
            settings.refresh()
            XCTAssertEqual(settings.status, status)
            XCTAssertEqual(settings.isRegistered, status == .enabled || status == .requiresApproval)
            XCTAssertNil(settings.errorMessage)
        }
    }

    func testEnablingAndDisablingUseTheSystemStatusAndAreIdempotent() {
        var status = SMAppService.Status.notRegistered
        var registrations = 0
        var removals = 0
        let settings = LoginItemSettings(readStatus: { status }, register: {
            registrations += 1
            status = .enabled
        }, unregister: {
            removals += 1
            status = .notRegistered
        }, openSettings: { XCTFail("No implicit settings navigation") })

        XCTAssertFalse(settings.isRegistered)
        settings.setEnabled(true)
        settings.setEnabled(true)
        XCTAssertTrue(settings.isRegistered)
        XCTAssertEqual(settings.status, .enabled)
        XCTAssertEqual(registrations, 1)
        settings.setEnabled(false)
        settings.setEnabled(false)
        XCTAssertFalse(settings.isRegistered)
        XCTAssertEqual(removals, 1)
        XCTAssertFalse(settings.isChanging)
    }

    func testPendingApprovalIsNotReportedAsEnabledAndCanBeCancelled() {
        var status = SMAppService.Status.notRegistered
        var registrations = 0
        var removals = 0
        let settings = LoginItemSettings(readStatus: { status }, register: {
            registrations += 1
            status = .requiresApproval
        }, unregister: {
            removals += 1
            status = .notRegistered
        }, openSettings: { XCTFail("Opening System Settings requires a separate user action") })

        settings.setEnabled(true)
        XCTAssertEqual(settings.status, .requiresApproval)
        XCTAssertTrue(settings.isRegistered, "The pending request remains cancellable")
        XCTAssertNil(settings.errorMessage)
        settings.setEnabled(true)
        XCTAssertEqual(registrations, 1, "Do not repeatedly register an item awaiting approval")
        settings.setEnabled(false)
        XCTAssertFalse(settings.isRegistered)
        XCTAssertEqual(removals, 1)
    }

    func testRegistrationErrorKeepsSwitchOffAndRetryCanSucceed() {
        var status = SMAppService.Status.notRegistered
        var shouldFail = true
        let settings = LoginItemSettings(readStatus: { status }, register: {
            if shouldFail { throw TestError.denied }
            status = .enabled
        }, unregister: {}, openSettings: { XCTFail("Failures must not navigate automatically") })

        settings.setEnabled(true)
        XCTAssertFalse(settings.isRegistered)
        XCTAssertNotNil(settings.errorMessage)
        XCTAssertFalse(settings.isChanging)
        shouldFail = false
        settings.setEnabled(true)
        XCTAssertEqual(settings.status, .enabled)
        XCTAssertNil(settings.errorMessage)
    }

    func testUnregisterErrorKeepsActualRegistrationAndRetryCanSucceed() {
        var status = SMAppService.Status.enabled
        var shouldFail = true
        let settings = LoginItemSettings(readStatus: { status }, register: {}, unregister: {
            if shouldFail { throw TestError.denied }
            status = .notRegistered
        }, openSettings: {})

        settings.setEnabled(false)
        XCTAssertTrue(settings.isRegistered)
        XCTAssertNotNil(settings.errorMessage)
        XCTAssertFalse(settings.isChanging)
        shouldFail = false
        settings.setEnabled(false)
        XCTAssertFalse(settings.isRegistered)
        XCTAssertNil(settings.errorMessage)
    }

    func testSuccessfulCallAloneDoesNotClaimRegistration() {
        let settings = LoginItemSettings(readStatus: { .notRegistered }, register: {}, unregister: {}, openSettings: {})
        settings.setEnabled(true)
        XCTAssertFalse(settings.isRegistered)
        XCTAssertNotNil(settings.errorMessage, "A status mismatch must not silently claim success")
    }

    func testErrorStillRefreshesAPartiallyRegisteredService() {
        var status = SMAppService.Status.notRegistered
        let settings = LoginItemSettings(readStatus: { status }, register: {
            status = .requiresApproval
            throw TestError.denied
        }, unregister: {}, openSettings: {})
        settings.setEnabled(true)
        XCTAssertEqual(settings.status, .requiresApproval)
        XCTAssertTrue(settings.isRegistered)
        XCTAssertNotNil(settings.errorMessage)
    }

    func testRefreshReflectsExternalApprovalAndRevocationWithoutReregistering() {
        var status = SMAppService.Status.notRegistered
        let settings = LoginItemSettings(readStatus: { status }, register: {
            XCTFail("Never undo a change made in System Settings")
        }, unregister: { XCTFail("Refresh must not remove an item") }, openSettings: {})

        for externalStatus in [SMAppService.Status.requiresApproval, .enabled, .requiresApproval, .notRegistered] {
            status = externalStatus
            settings.refresh()
            XCTAssertEqual(settings.status, externalStatus)
        }
    }

    func testUnavailableServiceDoesNotPretendToBeEnabled() {
        let settings = LoginItemSettings(readStatus: { .notFound }, register: { throw TestError.denied },
                                         unregister: {}, openSettings: {})
        settings.setEnabled(true)
        XCTAssertEqual(settings.status, .notFound)
        XCTAssertFalse(settings.isRegistered)
        XCTAssertNotNil(settings.errorMessage)
    }

    func testReentrantChangeCannotSubmitAnotherRequest() {
        var status = SMAppService.Status.notRegistered
        var registrations = 0
        var settings: LoginItemSettings!
        settings = LoginItemSettings(readStatus: { status }, register: {
            registrations += 1
            XCTAssertTrue(settings.isChanging)
            settings.setEnabled(true)
            status = .enabled
        }, unregister: { XCTFail("No nested removal") }, openSettings: {})
        settings.setEnabled(true)
        XCTAssertEqual(registrations, 1)
        XCTAssertFalse(settings.isChanging)
    }

    func testLoginItemsSettingsOpenOnlyOnExplicitRequest() {
        var opened = 0
        let settings = LoginItemSettings(readStatus: { .requiresApproval }, register: {
            XCTFail("Opening settings must not register")
        }, unregister: { XCTFail("Opening settings must not unregister") }, openSettings: { opened += 1 })
        XCTAssertEqual(opened, 0)
        settings.openSystemSettings()
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(settings.status, .requiresApproval)
    }

    private enum TestError: LocalizedError {
        case denied
        var errorDescription: String? { "模拟系统拒绝" }
    }
}
