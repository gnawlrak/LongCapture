import AppKit
import ServiceManagement
import XCTest
@testable import LongCapture

final class GlassInterfaceTests: XCTestCase {
    @MainActor
    func testShortcutRecordingSwitchesRowsWithoutResumingAndClosesSafely() async throws {
        _ = NSApplication.shared
        var recording: [Bool] = [], confirmation: [HotKeyShortcut] = [], quick: [HotKeyShortcut] = []
        let controller = SettingsWindowController(saveDirectory: URL(fileURLWithPath: "/tmp"),
            shortcut: .defaultShortcut, permission: ScreenCapturePermission(preflight: { true }),
            loginItem: inactiveLoginItem(), onRequestPermission: {}, onOpenPermissionSettings: {},
            onDirectoryChanged: { _ in }, onShortcutChanged: { confirmation.append($0) },
            onQuickShortcutChanged: { quick.append($0) }, onRecordingChanged: { recording.append($0) })
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window), root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        func recorder(_ label: String) throws -> NSButton {
            try XCTUnwrap(descendants(in: root).compactMap { $0 as? NSButton }.first {
                $0.accessibilityLabel() == label
            })
        }
        let manualButton = try recorder("录入调整模式快捷键")
        let quickButton = try recorder("录入快速模式快捷键")
        manualButton.performClick(nil)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(recording, [true])
        XCTAssertEqual(manualButton.title, "请按快捷键…")
        XCTAssertEqual(quickButton.title, "⌃⌥⇧S")
        quickButton.performClick(nil)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(recording, [true], "Switching recorders must keep both hotkeys suspended")
        XCTAssertEqual(manualButton.title, "⌃⌥S")
        XCTAssertEqual(quickButton.title, "请按快捷键…")
        let invalidKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.shift], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "R", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15))
        NSApp.sendEvent(invalidKey)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(quick.isEmpty)
        XCTAssertEqual(recording, [true], "Invalid combinations must leave recording and suspension active")
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.control, .option], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15))
        NSApp.sendEvent(key)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(quick, [HotKeyShortcut(keyCode: 15, modifiers: HotKeyShortcut.defaultShortcut.modifiers)])
        XCTAssertTrue(confirmation.isEmpty)
        XCTAssertEqual(recording, [true, false])
        XCTAssertEqual(quickButton.title, "⌃⌥R")
        manualButton.performClick(nil)
        NSApp.sendEvent(try selectionKey(53, in: window))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(recording, [true, false, true, false])
        XCTAssertTrue(confirmation.isEmpty)
        quickButton.performClick(nil)
        controller.close()
        XCTAssertEqual(recording, [true, false, true, false, true, false])
        NSApp.sendEvent(key)
        XCTAssertEqual(quick.count, 1, "Closing settings must remove the recording monitor")
    }

    @MainActor
    func testShortcutAssignmentsAndAuthoritativeUpdatesRemainIndependent() async throws {
        _ = NSApplication.shared
        let custom = HotKeyShortcut(keyCode: 15, modifiers: HotKeyShortcut.defaultShortcut.modifiers)
        var changes: [(CaptureShortcutAction, HotKeyShortcut)] = []
        let controller = SettingsWindowController(saveDirectory: URL(fileURLWithPath: "/tmp"), shortcut: custom,
            permission: ScreenCapturePermission(preflight: { true }), loginItem: inactiveLoginItem(),
            quickShortcut: nil, shortcutMessages: [.quick: "快速模式组合不可用，请修改。"],
            onRequestPermission: {}, onOpenPermissionSettings: {}, onDirectoryChanged: { _ in },
            onShortcutChanged: { changes.append((.confirmation, $0)) },
            onQuickShortcutChanged: { changes.append((.quick, $0)) })
        defer { controller.close() }
        let root = try XCTUnwrap(controller.window?.contentView)
        root.layoutSubtreeIfNeeded()
        func labeledButton(_ label: String) throws -> NSButton {
            try XCTUnwrap(descendants(in: root).compactMap { $0 as? NSButton }.first {
                $0.accessibilityLabel() == label
            }, "Missing \(label); native buttons: \(descendants(in: root).compactMap { ($0 as? NSButton).map { ($0.title, $0.accessibilityLabel()) } })")
        }
        let manualButton = try labeledButton("录入调整模式快捷键")
        let quickButton = try labeledButton("录入快速模式快捷键")
        XCTAssertEqual(manualButton.title, "⌃⌥R")
        XCTAssertEqual(quickButton.title, "未设置")
        func record(_ button: NSButton, flags: NSEvent.ModifierFlags) throws {
            button.performClick(nil)
            let window = try XCTUnwrap(controller.window)
            NSApp.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1)))
        }
        try record(quickButton, flags: [.control, .option, .shift])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(manualButton.title, "⌃⌥R")
        XCTAssertEqual(quickButton.title, "⌃⌥⇧S")
        try record(manualButton, flags: [.control, .option])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(changes.map(\.0), [.quick, .confirmation])
        XCTAssertEqual(changes.map(\.1), [.defaultQuickShortcut, .defaultShortcut])
        controller.update(saveDirectory: URL(fileURLWithPath: "/tmp"), shortcut: custom,
                          quickShortcut: nil, shortcutMessages: [.quick: "两个截图快捷键不能相同。"])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(manualButton.title, "⌃⌥R")
        XCTAssertEqual(quickButton.title, "未设置", "Rejected input must display the authoritative configuration")
    }

    @MainActor
    func testSelectionPixelDimensionsUseAlignedRetinaCoordinates() throws {
        _ = NSApplication.shared
        let display = CGRect(x: -1280, y: -300, width: 1280, height: 800)
        for mode in [SelectionStartMode.confirmation, .onRelease] {
            let overlay = SelectionOverlay(displayRect: display, startMode: mode, scale: 2,
                                           onBegin: { _ in }, onCancel: {})
            defer { overlay.close() }
            let window = try XCTUnwrap(overlay.window), root = try XCTUnwrap(window.contentView)
            root.mouseDown(with: try selectionMouse(.leftMouseDown, at: CGPoint(x: 100.25, y: 100.25), in: window))
            root.mouseDragged(with: try selectionMouse(.leftMouseDragged, at: CGPoint(x: 500.25, y: 400.25), in: window))
            let geometry = try CaptureGeometry(displayID: 0, displayFrame: display,
                                              selection: XCTUnwrap(overlay.currentSelection), scale: 2)
            XCTAssertEqual(geometry.pixelWidth, 801)
            XCTAssertEqual(geometry.pixelHeight, 601)
            let label = try XCTUnwrap(descendants(in: root).compactMap { $0 as? NSTextField }.first {
                $0.stringValue.hasSuffix(" px")
            })
            XCTAssertEqual(label.stringValue, "801 × 601 px")
        }
    }

    @MainActor
    func testSettingsProvidesIndependentConfirmationAndQuickShortcutRecorders() throws {
        _ = NSApplication.shared
        let permission = ScreenCapturePermission(preflight: { true }, requestAccess: {
            XCTFail("Settings must not ask for extra permissions"); return false
        }, openSettings: { _ in true })
        let controller = SettingsWindowController(saveDirectory: URL(fileURLWithPath: "/tmp"),
            shortcut: .defaultShortcut, permission: permission, loginItem: inactiveLoginItem(),
            onRequestPermission: {}, onOpenPermissionSettings: {}, onDirectoryChanged: { _ in },
            onShortcutChanged: { _ in })
        defer { controller.close() }
        let root = try XCTUnwrap(controller.window?.contentView)
        root.layoutSubtreeIfNeeded()
        let recorders = descendants(in: root).compactMap { $0 as? NSButton }.filter {
            $0.accessibilityLabel()?.contains("快捷键") == true
        }
        XCTAssertEqual(recorders.count, 2)
        XCTAssertTrue(recorders.contains { $0.title == "⌃⌥S" })
        XCTAssertTrue(recorders.contains { $0.title == "⌃⌥⇧S" })
    }

    @MainActor
    func testQuickSelectionUsesReleasePointInAllDirectionsAndStartsOnlyOnce() throws {
        _ = NSApplication.shared
        let display = CGRect(x: -1280, y: -300, width: 1280, height: 800)
        for scale: CGFloat in [1, 2] {
            for (start, end) in [(CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 400)),
                                 (CGPoint(x: 500, y: 100), CGPoint(x: 100, y: 400)),
                                 (CGPoint(x: 100, y: 400), CGPoint(x: 500, y: 100)),
                                 (CGPoint(x: 500, y: 400), CGPoint(x: 100, y: 100))] {
                var captured: [CGRect] = []
                let overlay = SelectionOverlay(displayRect: display, startMode: .onRelease, scale: scale,
                                               onBegin: { captured.append($0) }, onCancel: {})
                defer { overlay.close() }
                let window = try XCTUnwrap(overlay.window)
                let root = try XCTUnwrap(window.contentView)
                root.mouseDown(with: try selectionMouse(.leftMouseDown, at: start, in: window))
                root.mouseDragged(with: try selectionMouse(.leftMouseDragged, at: CGPoint(x: 300, y: 250), in: window))
                overlay.begin()
                XCTAssertTrue(captured.isEmpty)
                root.mouseUp(with: try selectionMouse(.leftMouseUp, at: end, in: window))
                XCTAssertEqual(captured, [CGRect(x: -1180, y: -200, width: 400, height: 300)])
                let geometry = try CaptureGeometry(displayID: 0, displayFrame: display,
                                                  selection: XCTUnwrap(captured.first), scale: scale)
                XCTAssertEqual(geometry.pixelWidth, Int(400 * scale))
                XCTAssertEqual(geometry.pixelHeight, Int(300 * scale))
                root.mouseUp(with: try selectionMouse(.leftMouseUp, at: end, in: window))
                root.mouseDragged(with: try selectionMouse(.leftMouseDragged, at: start, in: window))
                overlay.begin()
                XCTAssertEqual(captured.count, 1)
            }
        }
    }

    @MainActor
    func testQuickSelectionRejectsClicksAndPixelTooSmallRegionsThenAllowsRedraw() throws {
        _ = NSApplication.shared
        for scale: CGFloat in [1, 2] {
            var captured: [CGRect] = []
            let overlay = SelectionOverlay(displayRect: CGRect(x: 0, y: 0, width: 1280, height: 800),
                startMode: .onRelease, scale: scale, onBegin: { captured.append($0) }, onCancel: {})
            defer { overlay.close() }
            let window = try XCTUnwrap(overlay.window), root = try XCTUnwrap(window.contentView)
            let origin = CGPoint(x: 100, y: 100)
            for end in [origin, CGPoint(x: 124, y: 124), CGPoint(x: 147, y: 131)] {
                root.mouseDown(with: try selectionMouse(.leftMouseDown, at: origin, in: window))
                root.mouseUp(with: try selectionMouse(.leftMouseUp, at: end, in: window))
                XCTAssertTrue(captured.isEmpty)
                XCTAssertNil(overlay.currentSelection)
            }
            root.mouseDown(with: try selectionMouse(.leftMouseDown, at: origin, in: window))
            let end = CGPoint(x: 100 + 96 / scale, y: 100 + 64 / scale)
            root.mouseUp(with: try selectionMouse(.leftMouseUp, at: end, in: window))
            XCTAssertEqual(captured, [CGRect(x: 100, y: 100, width: 96 / scale, height: 64 / scale)])
        }
    }

    @MainActor
    func testQuickSelectionCancellationAndExternalCloseSuppressLateEvents() throws {
        _ = NSApplication.shared
        for escape in [true, false] {
            var started = 0, cancelled = 0
            let overlay = SelectionOverlay(displayRect: CGRect(x: 0, y: 0, width: 1280, height: 800),
                startMode: .onRelease, onBegin: { _ in started += 1 }, onCancel: { cancelled += 1 })
            defer { overlay.close() }
            let window = try XCTUnwrap(overlay.window), root = try XCTUnwrap(window.contentView)
            root.mouseDown(with: try selectionMouse(.leftMouseDown, at: CGPoint(x: 100, y: 100), in: window))
            root.mouseDragged(with: try selectionMouse(.leftMouseDragged, at: CGPoint(x: 500, y: 400), in: window))
            root.keyDown(with: try selectionKey(36, in: window))
            overlay.begin()
            XCTAssertEqual(started, 0)
            if escape { root.keyDown(with: try selectionKey(53, in: window)) }
            else { overlay.close() }
            root.keyDown(with: try selectionKey(53, in: window))
            root.mouseUp(with: try selectionMouse(.leftMouseUp, at: CGPoint(x: 500, y: 400), in: window))
            root.mouseDown(with: try selectionMouse(.leftMouseDown, at: CGPoint(x: 100, y: 100), in: window))
            root.mouseUp(with: try selectionMouse(.leftMouseUp, at: CGPoint(x: 500, y: 400), in: window))
            XCTAssertEqual(started, 0)
            XCTAssertEqual(cancelled, escape ? 1 : 0)
        }
    }

    @MainActor
    func testQuickSelectionHasNoConfirmationControlsAndClampsToSelectedDisplay() throws {
        _ = NSApplication.shared
        var captured: CGRect?
        let overlay = SelectionOverlay(displayRect: CGRect(x: -1280, y: 0, width: 1280, height: 800),
            startMode: .onRelease, scale: 2, onBegin: { captured = $0 }, onCancel: {})
        defer { overlay.close() }
        let window = try XCTUnwrap(overlay.window), root = try XCTUnwrap(window.contentView)
        XCTAssertNil(button("开始截图", in: root))
        XCTAssertTrue(descendants(in: root).compactMap { $0 as? NSButton }.isEmpty)
        XCTAssertTrue(root.accessibilityLabel()?.contains("松手开始") == true)
        root.mouseDown(with: try selectionMouse(.leftMouseDown, at: CGPoint(x: 1200, y: 700), in: window))
        root.mouseUp(with: try selectionMouse(.leftMouseUp, at: CGPoint(x: 1500, y: 1000), in: window))
        XCTAssertEqual(captured, CGRect(x: -80, y: 700, width: 80, height: 100))
    }

    @MainActor
    private func selectionMouse(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @MainActor
    private func selectionKey(_ code: UInt16, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code))
    }

    @MainActor
    func testSelectionCannotStartWhileMouseIsStillDragging() throws {
        _ = NSApplication.shared
        var started = 0
        let overlay = SelectionOverlay(displayRect: CGRect(x: 0, y: 0, width: 1280, height: 800),
                                       onBegin: { _ in started += 1 }, onCancel: {})
        defer { overlay.close() }
        let window = try XCTUnwrap(overlay.window)
        let root = try XCTUnwrap(window.contentView)
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        }
        root.mouseDown(with: try mouse(.leftMouseDown, 100, 100))
        root.mouseDragged(with: try mouse(.leftMouseDragged, 500, 400))
        overlay.begin()
        XCTAssertEqual(started, 0, "A repeated shortcut must not begin a half-drawn selection")
        root.mouseUp(with: try mouse(.leftMouseUp, 500, 400))
        XCTAssertEqual(started, 0, "Confirmation mode still waits for Return")
        overlay.begin()
        XCTAssertEqual(started, 1)
    }

    @MainActor
    func testShareUsesCurrentPageAndBlocksStaleTransferDuringPageLoading() async throws {
        _ = NSApplication.shared
        let first = sampleImage()
        let second = NSImage(size: NSSize(width: 37, height: 83), flipped: false) { rect in
            NSColor.systemOrange.setFill(); rect.fill(); return true
        }
        let firstPixels = try XCTUnwrap(first.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let secondPixels = try XCTUnwrap(second.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var shared: [NSImage] = []
        var loading: CheckedContinuation<NSImage, Error>?
        let clipboard = NSPasteboard.general.changeCount
        let controller = PreviewWindowController(image: first,
            onSave: { XCTFail("Sharing must not resolve the original"); return URL(fileURLWithPath: "/tmp/unused") },
            onDiscard: { XCTFail("Sharing must not discard the original"); return false }, onChooseDirectory: {},
            pageCount: 2, loadPage: { _ in try await withCheckedThrowingContinuation { loading = $0 } },
            onShare: { image, _ in shared.append(image) })
        defer { controller.closeAfterResolution() }
        let root = try XCTUnwrap(controller.window?.contentView)
        let share = try XCTUnwrap(button("分享", in: root))
        share.performClick(nil)
        XCTAssertEqual(shared.first?.size, NSSize(width: firstPixels.width, height: firstPixels.height))
        let pages = try XCTUnwrap(descendants(in: root).compactMap { $0 as? NSPopUpButton }.first {
            $0.itemTitles.contains("第 2 / 2 张")
        })
        pages.selectItem(at: 1)
        NSApp.sendAction(try XCTUnwrap(pages.action), to: pages.target, from: pages)
        for _ in 0..<20 where loading == nil { await Task.yield() }
        XCTAssertNotNil(loading)
        XCTAssertFalse(share.isEnabled)
        let document = try XCTUnwrap(descendants(in: root).compactMap { $0 as? ResultDragSourceView }.first)
        XCTAssertFalse(document.canDrag())
        NSApp.sendAction(try XCTUnwrap(share.action), to: share.target, from: share)
        XCTAssertEqual(shared.count, 1)
        loading?.resume(returning: second)
        for _ in 0..<100 where !share.isEnabled { await Task.yield() }
        XCTAssertTrue(share.isEnabled)
        share.performClick(nil)
        XCTAssertEqual(shared.count, 2)
        XCTAssertEqual(shared.last?.size, NSSize(width: secondPixels.width, height: secondPixels.height))
        let sharedPixels = try XCTUnwrap(shared.last?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        try assertPixelsEqual(sharedPixels, secondPixels)
        XCTAssertEqual(NSPasteboard.general.changeCount, clipboard)
    }

    @MainActor
    func testNativeDragThresholdCancellationAndInteractionOwnership() throws {
        _ = NSApplication.shared
        let view = TestResultDragSource(frame: CGRect(x: 0, y: 0, width: 200, height: 200), image: sampleImage())
        var interactions: [Bool] = [], clicks = 0
        view.onInteraction = { interactions.append($0) }
        view.onClick = { clicks += 1 }
        func event(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 40), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, x: 40))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 43))
        XCTAssertEqual(view.started, 0)
        view.mouseDragged(with: try event(.leftMouseDragged, x: 48))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 70))
        XCTAssertEqual(view.started, 1)
        view.mouseUp(with: try event(.leftMouseUp, x: 70))
        XCTAssertEqual(clicks, 0)
        XCTAssertTrue(view.isDraggingImage)
        XCTAssertTrue(ResultDragSourceView.hasActiveDrag)
        view.endImageDrag()
        XCTAssertEqual(interactions, [true, false])
        XCTAssertFalse(view.isDraggingImage)
        XCTAssertFalse(ResultDragSourceView.hasActiveDrag)
        view.canDrag = { false }
        view.mouseDown(with: try event(.leftMouseDown, x: 40))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 70))
        XCTAssertEqual(view.started, 1)
        XCTAssertEqual(interactions, [true, false])
    }

    @MainActor
    func testPreviewIncludesSharingWithoutReplacingExistingActions() throws {
        _ = NSApplication.shared
        let controller = PreviewWindowController(image: sampleImage(),
            onSave: { XCTFail("Sharing must not automatically save or close"); return URL(fileURLWithPath: "/tmp/unused.png") },
            onDiscard: { XCTFail("Sharing must not discard"); return false }, onChooseDirectory: {})
        defer { controller.closeAfterResolution() }
        let root = try XCTUnwrap(controller.window?.contentView)
        for title in ["分享", "复制", "保存 PNG", "完成", "丢弃"] {
            XCTAssertNotNil(button(title, in: root), title)
        }
    }

    @MainActor
    func testThumbnailClickWaitsForMouseUpSoItCanBecomeADrag() throws {
        _ = NSApplication.shared
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        var opened = 0
        let thumbnail = ResultThumbnail(image: sampleImage(), screenFrame: NSScreen.main!.frame,
            onOpen: { opened += 1 }, onAutoSave: { XCTFail("An active interaction must not auto-save") })
        defer { thumbnail.finish() }
        thumbnail.show()
        let panel = try XCTUnwrap(NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) })
        let root = try XCTUnwrap(panel.contentView)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: 80, y: 80), modifierFlags: [],
                timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        root.mouseDown(with: try event(.leftMouseDown))
        XCTAssertEqual(opened, 0)
        root.mouseUp(with: try event(.leftMouseUp))
        XCTAssertEqual(opened, 1)
    }

    @MainActor
    func testLegacyMaterialAndReducedTransparencyKeepTheSameControls() throws {
        _ = NSApplication.shared
        var reduced = false
        let surface = NativeGlassView(allowsLiquidGlass: false, reduceTransparency: { reduced })
        surface.frame = CGRect(x: 0, y: 0, width: 320, height: 80)
        let control = NSButton(title: "保留的操作", target: nil, action: nil)
        surface.contentView.addSubview(control)
        XCTAssertEqual(surface.materialKind, .visualEffect)
        XCTAssertFalse(descendants(in: surface).compactMap { $0 as? NSVisualEffectView }.isEmpty)
        reduced = true
        surface.refreshMaterial()
        XCTAssertEqual(surface.materialKind, .opaque)
        XCTAssertTrue(descendants(in: surface).compactMap { $0 as? NSVisualEffectView }.isEmpty)
        XCTAssertTrue(control.superview === surface.contentView)
        reduced = false
        surface.refreshMaterial()
        XCTAssertEqual(surface.materialKind, .visualEffect)
        XCTAssertTrue(control.superview === surface.contentView)
    }

    @MainActor
    func testGlassRespondsToAccessibilityChangesWithoutReplacingContent() throws {
        _ = NSApplication.shared
        var reduced = false
        let surface = NativeGlassView(reduceTransparency: { reduced })
        let content = surface.contentView
        surface.frame = CGRect(x: 0, y: 0, width: 320, height: 80)
        reduced = true
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                   object: nil)
        XCTAssertEqual(surface.materialKind, .opaque)
        XCTAssertTrue(content === surface.contentView)
        reduced = false
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                   object: nil)
        if #available(macOS 26.0, *) { XCTAssertEqual(surface.materialKind, .liquidGlass) }
        else { XCTAssertEqual(surface.materialKind, .visualEffect) }
        XCTAssertTrue(content === surface.contentView)
    }

    @MainActor
    func testSelectionInstructionsUseGlassWithoutCoveringTheWholeDisplay() throws {
        _ = NSApplication.shared
        let overlay = SelectionOverlay(displayRect: CGRect(x: 0, y: 0, width: 1280, height: 800),
                                       onBegin: { _ in }, onCancel: {})
        defer { overlay.close() }
        let root = try XCTUnwrap(overlay.window?.contentView)
        root.layoutSubtreeIfNeeded()
        let glass = try XCTUnwrap(glassViews(in: root).first, "Selection guidance must use a native glass surface")
        XCTAssertLessThan(glass.frame.height, root.bounds.height / 2, "Never blur the selected document itself")
        XCTAssertNotNil(button("开始截图", in: root))
        XCTAssertNotNil(button("取消", in: root))
    }

    @MainActor
    func testSelectionInstructionsClearSystemMenuBarAndNotch() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let safeTop = min(screen.visibleFrame.maxY, screen.frame.maxY - screen.safeAreaInsets.top)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let overlay = SelectionOverlay(displayRect: screen.frame, onBegin: { _ in }, onCancel: {})
            defer { overlay.close() }
            let window = try XCTUnwrap(overlay.window)
            window.appearance = NSAppearance(named: appearance)
            let root = try XCTUnwrap(window.contentView)
            root.layoutSubtreeIfNeeded()
            let glass = try XCTUnwrap(glassViews(in: root).first)
            let frame = window.convertToScreen(root.convert(glass.bounds, from: glass))
            XCTAssertLessThanOrEqual(frame.maxY, safeTop - 16 + 0.5,
                                     "Selection guidance must leave 16pt below both menu bar and notch in \(appearance)")
            XCTAssertEqual(root.bounds.size, screen.frame.size, "Keep full-display selection coordinates unchanged")
        }
    }

    @MainActor
    func testSelectionGuidanceInsetsStayDisplayLocalWithoutShrinkingSelection() throws {
        _ = NSApplication.shared
        for origin in [CGPoint.zero, CGPoint(x: -1512, y: 240)] {
            let display = CGRect(origin: origin, size: CGSize(width: 1512, height: 982))
            for topInset: CGFloat in [0, 24, 33, 64] {
                let overlay = SelectionOverlay(displayRect: display, safeTopInset: topInset,
                                               onBegin: { _ in }, onCancel: {})
                defer { overlay.close() }
                let root = try XCTUnwrap(overlay.window?.contentView)
                root.layoutSubtreeIfNeeded()
                let glass = try XCTUnwrap(glassViews(in: root).first)
                let frame = root.convert(glass.bounds, from: glass)
                XCTAssertEqual(frame.maxY, display.height - topInset - 16, accuracy: 0.5)
                XCTAssertEqual(frame.midX, display.width / 2, accuracy: 0.5)
                XCTAssertEqual(root.bounds, CGRect(origin: .zero, size: display.size))
                XCTAssertTrue(root.bounds.contains(frame))
                XCTAssertNotNil(button("开始截图", in: root))
                XCTAssertNotNil(button("取消", in: root))
            }
        }
    }

    @MainActor
    func testCaptureGlassToolbarPreservesClickThroughAndCompletionActions() throws {
        _ = NSApplication.shared
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        var completed = 0
        var cancelled = 0
        let overlay = CaptureOverlay(displayRect: CGRect(x: 0, y: 0, width: 1280, height: 800),
                                     region: CGRect(x: 120, y: 160, width: 720, height: 450),
                                     onDone: { completed += 1 }, onCancel: { cancelled += 1 })
        defer { overlay.close() }
        let windows = NSApp.windows.filter { !existing.contains(ObjectIdentifier($0)) }
        let toolbar = try XCTUnwrap(windows.first { $0 is NSPanel })
        let border = try XCTUnwrap(windows.first { !($0 is NSPanel) })
        let content = try XCTUnwrap(toolbar.contentView)
        XCTAssertTrue(border.ignoresMouseEvents)
        XCTAssertEqual(border.sharingType, .none)
        XCTAssertEqual(toolbar.sharingType, .none)
        XCTAssertTrue(toolbar.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(glassViews(in: content).isEmpty, "Capture controls must use native glass")
        let done = try XCTUnwrap(button("完成", in: content))
        if #available(macOS 26.0, *) { XCTAssertEqual(done.tintProminence, .primary) }
        XCTAssertFalse(done.isEnabled)
        overlay.setReady()
        XCTAssertTrue(done.isEnabled)
        done.performClick(nil)
        button("取消", in: content)?.performClick(nil)
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(cancelled, 1)
        overlay.setFinishing()
        XCTAssertFalse(done.isEnabled)
    }

    @MainActor
    func testThumbnailGlassRemainsAnAccessiblePreviewButtonAfterSaveFailure() throws {
        _ = NSApplication.shared
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        var opened = 0
        let thumbnail = ResultThumbnail(image: sampleImage(), screenFrame: NSScreen.main!.frame,
                                        warning: "仅包含已确认部分", onOpen: { opened += 1 },
                                        onAutoSave: { XCTFail("Opening must stop automatic saving") })
        defer { thumbnail.finish() }
        thumbnail.show()
        let panel = try XCTUnwrap(NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) })
        let card = try XCTUnwrap(panel.contentView)
        XCTAssertFalse(glassViews(in: card).isEmpty, "Result thumbnail must use native glass")
        thumbnail.showSaveFailure("测试目录不可写")
        XCTAssertTrue(card.accessibilityPerformPress())
        XCTAssertEqual(opened, 1)
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor
    func testPreviewGlassKeepsImageUnfilteredAndAllResultActionsAvailable() throws {
        _ = NSApplication.shared
        let controller = PreviewWindowController(image: sampleImage(), onSave: {
            XCTFail("Building a preview must not save")
            return URL(fileURLWithPath: "/tmp/unused.png")
        }, onDiscard: { true }, onChooseDirectory: {})
        defer { controller.closeAfterResolution() }
        let root = try XCTUnwrap(controller.window?.contentView)
        XCTAssertFalse(glassViews(in: root).isEmpty, "Preview chrome must use native glass")
        let scroll = try XCTUnwrap(descendants(in: root).compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertTrue(glassViews(in: document).isEmpty, "Glass belongs to controls, never screenshot pixels")
        for title in ["复制", "分享", "保存位置…", "丢弃", "保存 PNG", "完成"] {
            XCTAssertNotNil(button(title, in: root), "Missing result action: \(title)")
        }
        for title in ["复制", "分享", "保存位置…", "丢弃", "保存 PNG"] {
            XCTAssertEqual(button(title, in: root)?.imagePosition, .imageLeading, "\(title) must display its label, not just its symbol")
        }
        XCTAssertEqual(button("复制", in: root)?.keyEquivalent, "c")
        XCTAssertEqual(button("保存 PNG", in: root)?.keyEquivalent, "s")
        XCTAssertEqual(button("完成", in: root)?.keyEquivalent, "\r")
    }

    @MainActor
    func testSettingsUsesGlassAndDoesNotRequestPermissionOnPresentation() throws {
        _ = NSApplication.shared
        var requests = 0
        let permission = ScreenCapturePermission(preflight: { false }, requestAccess: { requests += 1; return false })
        let controller = SettingsWindowController(saveDirectory: URL(fileURLWithPath: "/tmp"), shortcut: .defaultShortcut,
                                                  permission: permission, loginItem: inactiveLoginItem(),
                                                  onRequestPermission: { requests += 1 },
                                                  onOpenPermissionSettings: {}, onDirectoryChanged: { _ in },
                                                  onShortcutChanged: { _ in })
        defer { controller.close() }
        let root = try XCTUnwrap(controller.window?.contentView)
        XCTAssertFalse(glassViews(in: root).isEmpty, "Settings must share the native window material")
        XCTAssertEqual(requests, 0)
    }

    @MainActor
    func testSettingsLoginSwitchStartsOffAndUsesTheSystemService() async throws {
        _ = NSApplication.shared
        var status = SMAppService.Status.notRegistered
        var registrations = 0
        var removals = 0
        var registrationFails = false
        let loginItem = LoginItemSettings(readStatus: { status }, register: {
            registrations += 1
            if registrationFails { throw NSError(domain: "LoginSwitchTest", code: 1) }
            status = .enabled
        }, unregister: {
            removals += 1
            status = .notRegistered
        }, openSettings: { XCTFail("A toggle must not navigate automatically") })
        let controller = SettingsWindowController(saveDirectory: URL(fileURLWithPath: "/tmp"), shortcut: .defaultShortcut,
                                                  permission: ScreenCapturePermission(preflight: { false }),
                                                  loginItem: loginItem,
                                                  onRequestPermission: {}, onOpenPermissionSettings: {},
                                                  onDirectoryChanged: { _ in }, onShortcutChanged: { _ in })
        defer { controller.close() }
        let root = try XCTUnwrap(controller.window?.contentView)
        controller.window?.displayIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        root.layoutSubtreeIfNeeded()
        let toggle = try XCTUnwrap(descendants(in: root).compactMap { $0 as? NSSwitch }.first)
        XCTAssertEqual(toggle.state, .off)
        XCTAssertTrue(toggle.isEnabled)
        XCTAssertFalse(toggle.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(root.bounds.contains(root.convert(toggle.bounds, from: toggle)))
        XCTAssertEqual(registrations, 0, "Presenting settings must never opt in")
        XCTAssertEqual(removals, 0)
        toggle.performClick(nil)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(registrations, 1)
        XCTAssertEqual(loginItem.status, .enabled)
        XCTAssertEqual(toggle.state, .on)
        toggle.performClick(nil)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(removals, 1)
        XCTAssertEqual(toggle.state, .off)
        registrationFails = true
        toggle.performClick(nil)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(registrations, 2)
        XCTAssertEqual(toggle.state, .off, "The native switch must revert when the system refuses registration")
        XCTAssertNotNil(loginItem.errorMessage)
    }

    @MainActor
    func testReopeningSettingsRefreshesExternalLoginItemChanges() async throws {
        _ = NSApplication.shared
        var status = SMAppService.Status.enabled
        let loginItem = LoginItemSettings(readStatus: { status }, register: { XCTFail("No automatic registration") },
                                         unregister: { XCTFail("No automatic removal") }, openSettings: {})
        let controller = SettingsWindowController(saveDirectory: URL(fileURLWithPath: "/tmp"), shortcut: .defaultShortcut,
                                                  permission: ScreenCapturePermission(preflight: { false }),
                                                  loginItem: loginItem, onRequestPermission: {}, onOpenPermissionSettings: {},
                                                  onDirectoryChanged: { _ in }, onShortcutChanged: { _ in })
        defer { controller.close() }
        for externalStatus in [SMAppService.Status.enabled, .requiresApproval, .notRegistered] {
            status = externalStatus
            controller.showWindow(nil)
            try await Task.sleep(nanoseconds: 150_000_000)
            let root = try XCTUnwrap(controller.window?.contentView)
            root.layoutSubtreeIfNeeded()
            let toggle = try XCTUnwrap(descendants(in: root).compactMap { $0 as? NSSwitch }.first)
            XCTAssertEqual(loginItem.status, externalStatus)
            XCTAssertEqual(toggle.state, externalStatus == .notRegistered ? .off : .on)
            controller.close()
        }
    }

    @MainActor
    func testSelectionDragResizeMoveAndReturnStillWorkAroundGlassGuidance() throws {
        _ = NSApplication.shared
        var captured: CGRect?
        let overlay = SelectionOverlay(displayRect: CGRect(x: -1280, y: 0, width: 1280, height: 800),
                                       onBegin: { captured = $0 }, onCancel: {})
        defer { overlay.close() }
        let window = try XCTUnwrap(overlay.window)
        let root = try XCTUnwrap(window.contentView)
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [],
                                            timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1))
        }
        root.mouseDown(with: try mouse(.leftMouseDown, 100, 100))
        root.mouseDragged(with: try mouse(.leftMouseDragged, 500, 500))
        root.mouseUp(with: try mouse(.leftMouseUp, 500, 500))
        root.mouseDown(with: try mouse(.leftMouseDown, 500, 300))
        root.mouseDragged(with: try mouse(.leftMouseDragged, 540, 300))
        root.mouseUp(with: try mouse(.leftMouseUp, 540, 300))
        root.mouseDown(with: try mouse(.leftMouseDown, 300, 300))
        root.mouseDragged(with: try mouse(.leftMouseDragged, 320, 310))
        root.mouseUp(with: try mouse(.leftMouseUp, 320, 310))
        XCTAssertEqual(overlay.currentSelection, CGRect(x: -1160, y: 110, width: 440, height: 400))
        let start = try XCTUnwrap(button("开始截图", in: root))
        XCTAssertTrue(start.isEnabled)
        XCTAssertEqual(start.keyEquivalent, "\r")
        start.performClick(nil)
        XCTAssertEqual(captured, CGRect(x: -1160, y: 110, width: 440, height: 400))
    }

    @MainActor
    func testPreviewActionsRemainVisibleAtMinimumSizeInBothAppearances() throws {
        _ = NSApplication.shared
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let controller = PreviewWindowController(image: sampleImage(), warning: "匹配暂停，仅包含已确认匹配的部分。",
                                                     onSave: { URL(fileURLWithPath: "/tmp/unused.png") },
                                                     onDiscard: { true }, onChooseDirectory: {})
            let window = try XCTUnwrap(controller.window)
            window.appearance = NSAppearance(named: name)
            window.setFrame(NSRect(origin: .zero, size: window.minSize), display: false)
            let root = try XCTUnwrap(window.contentView)
            root.layoutSubtreeIfNeeded()
            for title in ["复制", "分享", "保存位置…", "丢弃", "保存 PNG", "完成"] {
                let action = try XCTUnwrap(button(title, in: root))
                let frame = root.convert(action.bounds, from: action)
                XCTAssertTrue(root.bounds.contains(frame), "\(title) falls outside the minimum window in \(name)")
                XCTAssertGreaterThan(action.frame.width, 30)
                XCTAssertFalse(action.isHiddenOrHasHiddenAncestor)
            }
            controller.closeAfterResolution()
        }
    }

    @MainActor
    func testSelectionUsesAutomaticGuidanceWithoutAxisSwitcher() throws {
        _ = NSApplication.shared
        let overlay = SelectionOverlay(displayRect: CGRect(x: 0, y: 0, width: 1280, height: 800),
                                       onBegin: { _ in }, onCancel: {})
        defer { overlay.close() }
        let root = try XCTUnwrap(overlay.window?.contentView)
        XCTAssertTrue(descendants(in: root).compactMap { $0 as? NSSegmentedControl }.isEmpty,
                      "Capture direction is automatic, so selection must not expose a manual axis switcher")
        XCTAssertTrue(descendants(in: root).compactMap { $0 as? NSTextField }.contains {
            $0.stringValue.contains("自动识别")
        })
        XCTAssertNil(overlay.currentSelection)
        XCTAssertFalse(try XCTUnwrap(button("开始截图", in: root)).isEnabled)
        XCTAssertEqual(try XCTUnwrap(button("取消", in: root)).keyEquivalent, "\u{1b}")
    }

    @MainActor
    func testRecoveryReferenceAndDistinctStatesStayInsideToolbarAndRemainExcluded() throws {
        _ = NSApplication.shared
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let overlay = CaptureOverlay(displayRect: CGRect(x: 0, y: 0, width: 1280, height: 800),
                                     region: CGRect(x: 100, y: 100, width: 700, height: 550), onDone: {}, onCancel: {})
        defer { overlay.close() }
        let panel = try XCTUnwrap(NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) && $0 is NSPanel })
        let root = try XCTUnwrap(panel.contentView)
        let image = try XCTUnwrap(sampleImage().cgImage(forProposedRect: nil, context: nil, hints: nil))
        overlay.update(StitchUpdate(action: .needsRecovery, height: 900, progress: .recovering, referenceImage: image))
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.sharingType, .none)
        let reference = try XCTUnwrap(descendants(in: root).compactMap { $0 as? NSImageView }.first { $0.image?.size == NSSize(width: image.width, height: image.height) })
        XCTAssertFalse(reference.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(root.bounds.contains(root.convert(reference.bounds, from: reference)))
        XCTAssertEqual(panel.frame.height, 188)
        overlay.update(StitchUpdate(action: .stayed, height: 900, progress: .revisiting))
        XCTAssertTrue(reference.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(panel.frame.height, 72)
        XCTAssertTrue(descendants(in: root).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("反向回看") })
        overlay.update(StitchUpdate(action: .grew, height: 920, progress: .recovered))
        XCTAssertTrue(descendants(in: root).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("已恢复") })
        overlay.update(StitchUpdate(action: .stayed, height: 180, axis: .automatic))
        XCTAssertTrue(descendants(in: root).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("自动识别方向") })
        XCTAssertEqual(panel.frame.height, 72)
    }

    @MainActor
    func testMultiPagePreviewNavigationAndExportStayVisibleAtMinimumWindowSize() async throws {
        _ = NSApplication.shared
        let image = sampleImage()
        var loaded: [Int] = []
        let controller = PreviewWindowController(image: image, onSave: { URL(fileURLWithPath: "/tmp/unused") },
            onDiscard: { true }, onChooseDirectory: {}, pageCount: 3, axis: .horizontal,
            loadPage: { index in loaded.append(index); return image }, onExport: { _ in URL(fileURLWithPath: "/tmp/unused") })
        defer { controller.closeAfterResolution() }
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(origin: .zero, size: window.minSize), display: false)
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        for title in ["复制", "分享", "保存位置…", "分段导出…", "丢弃", "保存全部 PNG", "完成"] {
            let action = try XCTUnwrap(button(title, in: root))
            XCTAssertTrue(root.bounds.contains(root.convert(action.bounds, from: action)), title)
            XCTAssertFalse(action.isHiddenOrHasHiddenAncestor)
        }
        let pages = try XCTUnwrap(descendants(in: root).compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("第 3 / 3 张") })
        pages.selectItem(at: 2)
        NSApp.sendAction(try XCTUnwrap(pages.action), to: pages.target, from: pages)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(loaded, [2])
    }

    @MainActor
    private func glassViews(in view: NSView) -> [NSView] {
        if #available(macOS 26.0, *) {
            return descendants(in: view).filter { $0 is NSGlassEffectView }
        }
        return descendants(in: view).filter { $0 is NSVisualEffectView }
    }

    @MainActor
    private func descendants(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(in: $0) }
    }

    @MainActor
    private func inactiveLoginItem() -> LoginItemSettings {
        LoginItemSettings(readStatus: { .notRegistered }, register: { XCTFail("No automatic registration") },
                          unregister: { XCTFail("No automatic removal") }, openSettings: {})
    }

    @MainActor
    private func button(_ title: String, in view: NSView) -> NSButton? {
        descendants(in: view).compactMap { $0 as? NSButton }.first { $0.title == title }
    }

    @MainActor
    private func sampleImage() -> NSImage {
        NSImage(size: NSSize(width: 320, height: 1200), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            NSColor.systemTeal.setFill()
            NSRect(x: 20, y: 20, width: 280, height: 180).fill()
            return true
        }
    }
}

@MainActor
private final class TestResultDragSource: ResultDragSourceView {
    var started = 0
    override func startImageDrag(_ item: NSDraggingItem, event: NSEvent) { started += 1 }
}
