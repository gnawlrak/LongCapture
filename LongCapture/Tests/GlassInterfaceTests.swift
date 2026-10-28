import AppKit
import XCTest
@testable import LongCapture

final class GlassInterfaceTests: XCTestCase {
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
        for title in ["复制", "保存位置…", "丢弃", "保存 PNG", "完成"] {
            XCTAssertNotNil(button(title, in: root), "Missing result action: \(title)")
        }
        for title in ["复制", "保存位置…", "丢弃", "保存 PNG"] {
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
                                                  permission: permission, onRequestPermission: { requests += 1 },
                                                  onOpenPermissionSettings: {}, onDirectoryChanged: { _ in },
                                                  onShortcutChanged: { _ in })
        defer { controller.close() }
        let root = try XCTUnwrap(controller.window?.contentView)
        XCTAssertFalse(glassViews(in: root).isEmpty, "Settings must share the native window material")
        XCTAssertEqual(requests, 0)
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
            for title in ["复制", "保存位置…", "丢弃", "保存 PNG", "完成"] {
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
