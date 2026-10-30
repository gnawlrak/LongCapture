import Carbon
import Foundation
import XCTest
@testable import LongCapture

@MainActor
final class CaptureShortcutTests: XCTestCase {
    func testDefaultsAreDistinctAndInitializationDoesNotWritePreferencesOrRegister() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let before = defaults.persistentDomain(forName: suite) ?? [:]
        let shortcuts = CaptureShortcuts(defaults: defaults, factory: { _, _, _ in
            XCTFail("Loading preferences must not register a hotkey")
            return FakeShortcutRegistration(callback: {})
        }, onAction: { _ in XCTFail("Loading preferences must not start a capture") })

        XCTAssertEqual(shortcuts.shortcut(for: .confirmation), .defaultShortcut)
        XCTAssertEqual(shortcuts.shortcut(for: .quick), .defaultQuickShortcut)
        XCTAssertNotEqual(shortcuts.shortcut(for: .confirmation), shortcuts.shortcut(for: .quick))
        XCTAssertEqual(shortcuts.shortcut(for: .confirmation)?.displayName, "⌃⌥S")
        XCTAssertEqual(shortcuts.shortcut(for: .quick)?.displayName, "⌃⌥⇧S")
        XCTAssertTrue(shortcuts.messages.isEmpty)
        XCTAssertEqual(NSDictionary(dictionary: defaults.persistentDomain(forName: suite) ?? [:]),
                       NSDictionary(dictionary: before))
    }

    func testLegacyCustomShortcutRetainsItsStorageKeyAndValue() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let custom = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey | optionKey))
        let data = try JSONEncoder().encode(custom)
        defaults.set(data, forKey: "LongCapture.shortcut")
        let before = defaults.persistentDomain(forName: suite) ?? [:]
        let shortcuts = makeShortcuts(defaults: defaults)

        XCTAssertEqual(CaptureShortcutAction.confirmation.storageKey, "LongCapture.shortcut")
        XCTAssertEqual(CaptureShortcutAction.quick.storageKey, "LongCapture.quickShortcut")
        XCTAssertEqual(shortcuts.shortcut(for: .confirmation), custom)
        XCTAssertEqual(shortcuts.shortcut(for: .quick), .defaultQuickShortcut)
        XCTAssertEqual(defaults.data(forKey: "LongCapture.shortcut"), data)
        XCTAssertNil(defaults.data(forKey: "LongCapture.quickShortcut"))
        XCTAssertEqual(NSDictionary(dictionary: defaults.persistentDomain(forName: suite) ?? [:]),
                       NSDictionary(dictionary: before))
    }

    func testLegacyCollisionPreservesExistingShortcutAndLeavesQuickMenuAvailable() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacyData = try JSONEncoder().encode(HotKeyShortcut.defaultQuickShortcut)
        defaults.set(legacyData, forKey: CaptureShortcutAction.confirmation.storageKey)
        var registered: [CaptureShortcutAction] = []
        let shortcuts = CaptureShortcuts(defaults: defaults, factory: { action, _, callback in
            registered.append(action)
            return FakeShortcutRegistration(callback: callback)
        }, onAction: { _ in })

        XCTAssertEqual(shortcuts.shortcut(for: .confirmation), .defaultQuickShortcut)
        XCTAssertNil(shortcuts.shortcut(for: .quick))
        XCTAssertNotNil(shortcuts.messages[.quick])
        shortcuts.register()
        XCTAssertEqual(registered, [.confirmation])
        XCTAssertNotNil(shortcuts.messages[.quick])
        XCTAssertEqual(defaults.data(forKey: CaptureShortcutAction.confirmation.storageKey), legacyData)
        XCTAssertNil(defaults.data(forKey: CaptureShortcutAction.quick.storageKey))
        XCTAssertEqual(CaptureShortcutAction.quick.intent(state: .idle, hasResult: false, selectionMode: nil),
                       .select(.onRelease), "A missing global hotkey must not disable the menu action")

        let replacement = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(controlKey | optionKey))
        XCTAssertTrue(shortcuts.change(replacement, for: .quick))
        XCTAssertEqual(shortcuts.shortcut(for: .confirmation), .defaultQuickShortcut)
        XCTAssertEqual(shortcuts.shortcut(for: .quick), replacement)
        XCTAssertNil(shortcuts.messages[.quick])
        XCTAssertEqual(defaults.data(forKey: CaptureShortcutAction.confirmation.storageKey), legacyData)
    }

    func testDuplicateAssignmentsAreRejectedWithoutReplacingEitherPreference() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcuts = makeShortcuts(defaults: defaults)
        XCTAssertTrue(shortcuts.change(.defaultShortcut, for: .confirmation))
        XCTAssertTrue(shortcuts.change(.defaultQuickShortcut, for: .quick))
        let before = defaults.persistentDomain(forName: suite) ?? [:]

        for action in CaptureShortcutAction.allCases {
            let other: CaptureShortcutAction = action == .confirmation ? .quick : .confirmation
            XCTAssertFalse(shortcuts.change(try XCTUnwrap(shortcuts.shortcut(for: other)), for: action))
            XCTAssertNotNil(shortcuts.messages[action])
            XCTAssertEqual(shortcuts.shortcut(for: .confirmation), .defaultShortcut)
            XCTAssertEqual(shortcuts.shortcut(for: .quick), .defaultQuickShortcut)
            XCTAssertEqual(NSDictionary(dictionary: defaults.persistentDomain(forName: suite) ?? [:]),
                           NSDictionary(dictionary: before))
        }
    }

    func testEachShortcutPersistsAndReloadsIndependently() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcuts = makeShortcuts(defaults: defaults)
        let confirmation = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | cmdKey))
        let quick = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(optionKey | shiftKey))
        XCTAssertTrue(shortcuts.change(confirmation, for: .confirmation))
        let originalData = defaults.data(forKey: CaptureShortcutAction.confirmation.storageKey)
        XCTAssertNil(defaults.data(forKey: CaptureShortcutAction.quick.storageKey))
        XCTAssertTrue(shortcuts.change(quick, for: .quick))
        XCTAssertEqual(defaults.data(forKey: CaptureShortcutAction.confirmation.storageKey), originalData)

        let loaded = makeShortcuts(defaults: defaults)
        XCTAssertEqual(loaded.shortcut(for: .confirmation), confirmation)
        XCTAssertEqual(loaded.shortcut(for: .quick), quick)
        XCTAssertEqual(try JSONDecoder().decode(HotKeyShortcut.self,
            from: XCTUnwrap(defaults.data(forKey: CaptureShortcutAction.quick.storageKey))), quick)
    }

    func testDuplicateRecordedWhileSuspendedKeepsWarningAfterResume() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcuts = makeShortcuts(defaults: defaults)
        shortcuts.register()
        shortcuts.setSuspended(true)
        XCTAssertFalse(shortcuts.change(.defaultShortcut, for: .quick))
        shortcuts.setSuspended(false)
        XCTAssertTrue(shortcuts.messages[.quick]?.contains("不能相同") == true)
        XCTAssertEqual(shortcuts.shortcut(for: .quick), .defaultQuickShortcut)
        XCTAssertNil(defaults.data(forKey: CaptureShortcutAction.quick.storageKey))
        XCTAssertTrue(shortcuts.change(.defaultQuickShortcut, for: .quick))
        XCTAssertNil(shortcuts.messages[.quick])
    }

    func testFailureOfEitherRegistrationDoesNotDisableOtherShortcutAndCanRetry() async throws {
        for failedAction in CaptureShortcutAction.allCases {
            let (defaults, suite) = try isolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            var shouldFail = true
            var registrations: [CaptureShortcutAction: FakeShortcutRegistration] = [:]
            var actions: [CaptureShortcutAction] = []
            let shortcuts = CaptureShortcuts(defaults: defaults, factory: { action, _, callback in
                let registration = FakeShortcutRegistration(callback: callback,
                    shouldFail: action == failedAction && shouldFail)
                registrations[action] = registration
                return registration
            }, onAction: { actions.append($0) })
            shortcuts.register()
            let other: CaptureShortcutAction = failedAction == .confirmation ? .quick : .confirmation
            XCTAssertNotNil(shortcuts.messages[failedAction])
            XCTAssertNil(shortcuts.messages[other])
            XCTAssertEqual(registrations[failedAction]?.unregisterCount, 1)
            registrations[failedAction]?.fire()
            registrations[other]?.fire()
            await drainCallbacks()
            XCTAssertEqual(actions, [other])

            shouldFail = false
            shortcuts.register()
            XCTAssertTrue(shortcuts.messages.isEmpty)
            registrations[.confirmation]?.fire()
            await drainCallbacks()
            registrations[.quick]?.fire()
            await drainCallbacks()
            XCTAssertEqual(actions, [other, .confirmation, .quick])
        }
    }

    func testRecordingSuspendsBothAndIgnoresCallbacksFromOldRegistrationsAfterResume() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var registrations: [CaptureShortcutAction: FakeShortcutRegistration] = [:]
        var actions: [CaptureShortcutAction] = []
        var factoryCount = 0
        let shortcuts = CaptureShortcuts(defaults: defaults, factory: { action, _, callback in
            factoryCount += 1
            let registration = FakeShortcutRegistration(callback: callback)
            registrations[action] = registration
            return registration
        }, onAction: { actions.append($0) })
        shortcuts.register()
        let oldConfirmation = try XCTUnwrap(registrations[.confirmation])
        let oldQuick = try XCTUnwrap(registrations[.quick])
        XCTAssertEqual(factoryCount, 2)

        oldConfirmation.fire() // Its actor callback is still queued when recording starts.
        shortcuts.setSuspended(true)
        shortcuts.setSuspended(true)
        XCTAssertTrue(shortcuts.isSuspended)
        XCTAssertEqual(oldConfirmation.unregisterCount, 1)
        XCTAssertEqual(oldQuick.unregisterCount, 1)
        oldQuick.fire()
        await drainCallbacks()
        XCTAssertTrue(actions.isEmpty)
        shortcuts.register()
        XCTAssertEqual(factoryCount, 2, "Explicit registration must respect shortcut recording")

        shortcuts.setSuspended(false)
        shortcuts.setSuspended(false)
        XCTAssertFalse(shortcuts.isSuspended)
        XCTAssertEqual(factoryCount, 4)
        oldConfirmation.fire()
        oldQuick.fire()
        await drainCallbacks()
        XCTAssertTrue(actions.isEmpty, "Late callbacks must not be mistaken for the new registrations")
        registrations[.confirmation]?.fire()
        await drainCallbacks()
        registrations[.quick]?.fire()
        await drainCallbacks()
        XCTAssertEqual(actions, [.confirmation, .quick])
    }

    func testShortcutChangeWhileRecordingWaitsForResumeAndInvalidatesPriorCallbacks() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var registrations: [(CaptureShortcutAction, HotKeyShortcut, FakeShortcutRegistration)] = []
        var actions: [CaptureShortcutAction] = []
        let shortcuts = CaptureShortcuts(defaults: defaults, factory: { action, shortcut, callback in
            let registration = FakeShortcutRegistration(callback: callback)
            registrations.append((action, shortcut, registration))
            return registration
        }, onAction: { actions.append($0) })
        shortcuts.register()
        let oldQuick = try XCTUnwrap(registrations.first { $0.0 == .quick }?.2)
        shortcuts.setSuspended(true)
        let replacement = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey))
        XCTAssertTrue(shortcuts.change(replacement, for: .quick))
        XCTAssertEqual(registrations.count, 2)
        shortcuts.setSuspended(false)
        XCTAssertEqual(registrations.count, 4)
        XCTAssertEqual(registrations.last { $0.0 == .quick }?.1, replacement)
        oldQuick.fire()
        await drainCallbacks()
        XCTAssertTrue(actions.isEmpty)
        registrations.last { $0.0 == .quick }?.2.fire()
        await drainCallbacks()
        XCTAssertEqual(actions, [.quick])
    }

    func testCarbonEventDispatchUsesBothSignatureAndIndependentActionIDs() {
        var actions: [CaptureShortcutAction] = []
        let confirmation = HotKey(shortcut: .defaultShortcut, identifier: CaptureShortcutAction.confirmation.rawValue) {
            actions.append(.confirmation)
        }
        let quick = HotKey(shortcut: .defaultQuickShortcut, identifier: CaptureShortcutAction.quick.rawValue) {
            actions.append(.quick)
        }
        XCTAssertNotEqual(CaptureShortcutAction.confirmation.rawValue, CaptureShortcutAction.quick.rawValue)
        for action in CaptureShortcutAction.allCases {
            let event = EventHotKeyID(signature: HotKey.signature, id: action.rawValue)
            XCTAssertEqual(confirmation.handle(event), action == .confirmation ? noErr : OSStatus(eventNotHandledErr))
            XCTAssertEqual(quick.handle(event), action == .quick ? noErr : OSStatus(eventNotHandledErr))
        }
        XCTAssertEqual(actions, [.confirmation, .quick])
        for event in [EventHotKeyID(signature: 0, id: CaptureShortcutAction.confirmation.rawValue),
                      EventHotKeyID(signature: HotKey.signature, id: 999)] {
            XCTAssertEqual(confirmation.handle(event), OSStatus(eventNotHandledErr))
            XCTAssertEqual(quick.handle(event), OSStatus(eventNotHandledErr))
        }
        XCTAssertEqual(actions, [.confirmation, .quick])
    }

    func testBothActionsShareSingleSessionCompletionAndPendingResultProtection() {
        let states: [SessionCoordinator.State] = [.idle, .selecting, .starting, .capturing, .finishing, .result]
        for action in CaptureShortcutAction.allCases {
            for state in states {
                XCTAssertEqual(action.intent(state: state, hasResult: true, selectionMode: nil), .openResult)
            }
            XCTAssertEqual(action.intent(state: .idle, hasResult: false, selectionMode: nil), .select(action.startMode))
            XCTAssertEqual(action.intent(state: .capturing, hasResult: false, selectionMode: nil), .complete)
            for state in [SessionCoordinator.State.starting, .finishing, .result] {
                XCTAssertEqual(action.intent(state: state, hasResult: false, selectionMode: nil), .ignore)
            }
            XCTAssertEqual(action.intent(state: .selecting, hasResult: false, selectionMode: .onRelease), .ignore)
            XCTAssertEqual(action.intent(state: .selecting, hasResult: false, selectionMode: nil), .ignore)
        }
        XCTAssertEqual(CaptureShortcutAction.confirmation.intent(state: .selecting, hasResult: false,
                                                                selectionMode: .confirmation), .confirm)
        XCTAssertEqual(CaptureShortcutAction.quick.intent(state: .selecting, hasResult: false,
                                                         selectionMode: .confirmation), .ignore)
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "LongCapture.ShortcutTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    private func makeShortcuts(defaults: UserDefaults) -> CaptureShortcuts {
        CaptureShortcuts(defaults: defaults, factory: { _, _, callback in
            FakeShortcutRegistration(callback: callback)
        }, onAction: { _ in })
    }

    private func drainCallbacks() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

private final class FakeShortcutRegistration: HotKeyRegistration {
    private let callback: () -> Void
    private let shouldFail: Bool
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(callback: @escaping () -> Void, shouldFail: Bool = false) {
        self.callback = callback
        self.shouldFail = shouldFail
    }

    func register() throws {
        registerCount += 1
        if shouldFail { throw HotKeyError.registration(OSStatus(eventHotKeyExistsErr)) }
    }

    func unregister() { unregisterCount += 1 }
    func fire() { callback() }
}
