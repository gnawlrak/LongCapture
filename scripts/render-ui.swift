import AppKit
import ScreenCaptureKit

/// Non-sensitive layout fixtures. Composited mode only captures this process's own windows.
@main
struct RenderInterface {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(composited ? .accessory : .prohibited)
        Task { @MainActor in
            do {
                try await renderFixtures()
                app.terminate(nil)
            } catch {
                fputs("UI rendering failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    @MainActor
    private static func renderFixtures() async throws {
        let app = NSApplication.shared
        if composited && !CGPreflightScreenCaptureAccess() {
            throw NSError(domain: "RenderInterface", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Composited fixtures require existing screen-recording access; no permission will be requested."
            ])
        }
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/GlassUI", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let image = sampleDocument()
        for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            app.appearance = NSAppearance(named: appearance)
            let settings = SettingsWindowController(saveDirectory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"),
                                                     shortcut: .defaultShortcut,
                                                     permission: ScreenCapturePermission(preflight: { true }),
                                                     onRequestPermission: {}, onOpenPermissionSettings: {},
                                                     onDirectoryChanged: { _ in }, onShortcutChanged: { _ in })
            try await render(settings.window!, name: "settings-\(label)", appearance: appearance, into: output)
            settings.close()

            let preview = PreviewWindowController(image: image, onSave: { output.appendingPathComponent("unused.png") },
                                                   onDiscard: { true }, onChooseDirectory: {})
            try await render(preview.window!, name: "preview-\(label)", appearance: appearance, into: output)
            preview.closeAfterResolution()

            let display = CGRect(x: 0, y: 0, width: 1280, height: 800)
            let selection = SelectionOverlay(displayRect: display, safeTopInset: 33, onBegin: { _ in }, onCancel: {})
            let view = selection.window!.contentView!
            let number = selection.window!.windowNumber
            for (type, point) in [(NSEvent.EventType.leftMouseDown, CGPoint(x: 180, y: 140)),
                                  (.leftMouseDragged, CGPoint(x: 1100, y: 620)), (.leftMouseUp, CGPoint(x: 1100, y: 620))] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                               windowNumber: number, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                if type == .leftMouseDown { view.mouseDown(with: event) }
                else if type == .leftMouseDragged { view.mouseDragged(with: event) }
                else { view.mouseUp(with: event) }
            }
            try await render(selection.window!, name: "selection-\(label)", appearance: appearance, into: output)
            selection.close()

            let existing = Set(app.windows.map(ObjectIdentifier.init))
            let capture = CaptureOverlay(displayRect: display, region: CGRect(x: 180, y: 140, width: 920, height: 480),
                                         onDone: {}, onCancel: {})
            let toolbar = app.windows.first { !existing.contains(ObjectIdentifier($0)) && $0 is NSPanel }!
            capture.setReady()
            capture.update(StitchUpdate(action: .grew, height: 12840))
            try await render(toolbar, name: "capture-\(label)", appearance: appearance, into: output)
            capture.update(StitchUpdate(action: .needsRecovery, height: 12840))
            try await render(toolbar, name: "recovery-\(label)", appearance: appearance, into: output)
            capture.close()

            let previous = Set(app.windows.map(ObjectIdentifier.init))
            let thumbnail = ResultThumbnail(image: image, screenFrame: NSScreen.main!.frame,
                                            onOpen: {}, onAutoSave: {})
            thumbnail.show()
            let panel = app.windows.first { !previous.contains(ObjectIdentifier($0)) }!
            panel.orderOut(nil)
            try await render(panel, name: "thumbnail-\(label)", appearance: appearance, into: output)
            thumbnail.finish()
        }
        print("Rendered 12 \(composited ? "composited" : "offscreen") native interface fixtures into \(output.path)")
    }

    private static var composited: Bool { CommandLine.arguments.contains("--composited") }

    @MainActor
    private static func render(_ window: NSWindow, name: String, appearance: NSAppearance.Name, into output: URL) async throws {
        window.appearance = NSAppearance(named: appearance)
        let view = window.contentView!
        window.displayIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        view.layoutSubtreeIfNeeded()
        if composited {
            let background = NSWindow(contentRect: NSScreen.main!.frame, styleMask: .borderless,
                                      backing: .buffered, defer: false)
            background.isReleasedWhenClosed = false
            background.level = window.level
            background.contentView = FixtureBackdrop()
            background.appearance = window.appearance
            background.orderFrontRegardless()
            let sharing = window.sharingType
            window.sharingType = .readOnly
            window.center()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            defer { window.sharingType = sharing; window.orderOut(nil); background.close() }
            try await Task.sleep(nanoseconds: 450_000_000)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let target = content.windows.first(where: {
                $0.windowID == CGWindowID(window.windowNumber) && $0.owningApplication?.processID == getpid()
            }), let stage = content.windows.first(where: {
                $0.windowID == CGWindowID(background.windowNumber) && $0.owningApplication?.processID == getpid()
            }), let screen = window.screen,
                let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw NSError(domain: "RenderInterface", code: 4)
            }
            let filter = SCContentFilter(display: display, including: [target, stage])
            filter.includeMenuBar = false
            let configuration = SCStreamConfiguration()
            let scale = window.backingScaleFactor
            configuration.sourceRect = CGRect(x: window.frame.minX - screen.frame.minX,
                                               y: screen.frame.maxY - window.frame.maxY,
                                               width: window.frame.width, height: window.frame.height)
            configuration.width = Int(window.frame.width * scale)
            configuration.height = Int(window.frame.height * scale)
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.ignoreShadowsSingleWindow = true
            configuration.colorSpaceName = CGColorSpace.sRGB
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "RenderInterface", code: 2)
            }
            try png.write(to: output.appendingPathComponent("\(name)-composited.png"))
            return
        }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw NSError(domain: "RenderInterface", code: 1, userInfo: [NSLocalizedDescriptionKey: "No bitmap for \(name)"])
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "RenderInterface", code: 2)
        }
        try png.write(to: output.appendingPathComponent("\(name).png"))
    }

    @MainActor
    private static func sampleDocument() -> NSImage {
        NSImage(size: NSSize(width: 680, height: 1800), flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            let ink = NSColor(calibratedRed: 0.10, green: 0.19, blue: 0.20, alpha: 1)
            let accent = NSColor(calibratedRed: 0.08, green: 0.43, blue: 0.40, alpha: 1)
            ("LONG CAPTURE" as NSString).draw(at: CGPoint(x: 48, y: 44), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: accent, .kern: 3
            ])
            ("让内容完整留在一张图里。" as NSString).draw(at: CGPoint(x: 48, y: 84), withAttributes: [
                .font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: ink
            ])
            for i in 0..<12 {
                let y = CGFloat(170 + i * 126)
                accent.withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: CGRect(x: 44, y: y, width: 592, height: 104), xRadius: 12, yRadius: 12).fill()
                String(format: "%02d", i + 1).draw(at: CGPoint(x: 62, y: y + 18), withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .medium), .foregroundColor: accent
                ])
                ("这是本地生成的非敏感测试文档。" as NSString).draw(at: CGPoint(x: 112, y: y + 20), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 16, weight: .medium), .foregroundColor: ink
                ])
                ("原始像素 PNG · 手动滚动 · 不改变图像内容" as NSString).draw(at: CGPoint(x: 112, y: y + 53), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.gray
                ])
            }
            return true
        }
    }
}

@MainActor
private final class FixtureBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let colors: [NSColor] = dark
            ? [NSColor(calibratedRed: 0.08, green: 0.17, blue: 0.18, alpha: 1),
               NSColor(calibratedRed: 0.24, green: 0.20, blue: 0.15, alpha: 1)]
            : [NSColor(calibratedRed: 0.66, green: 0.84, blue: 0.80, alpha: 1),
               NSColor(calibratedRed: 0.94, green: 0.85, blue: 0.69, alpha: 1)]
        NSGradient(colors: colors)!.draw(in: bounds, angle: 25)
        NSColor.white.withAlphaComponent(dark ? 0.06 : 0.35).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 120, dy: 220), xRadius: 80, yRadius: 80).fill()
    }
}
