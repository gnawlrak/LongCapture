import AppKit
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import LongCapture

final class ResultFlowTests: XCTestCase {
    func testUntouchedThumbnailRequestsSaveAtFiveSecondsOnlyOnce() {
        let clock = TestResultClock()
        let lifecycle = ResultLifecycle(now: { clock.time })
        clock.time = 4.999
        XCTAssertFalse(lifecycle.tick())
        clock.time = 5
        XCTAssertTrue(lifecycle.tick())
        XCTAssertEqual(lifecycle.state, .saving)
        XCTAssertFalse(lifecycle.tick())
        lifecycle.saved()
        XCTAssertEqual(lifecycle.state, .resolved)
    }

    func testHoverPausesRatherThanRestartsCountdown() {
        let clock = TestResultClock()
        let lifecycle = ResultLifecycle(now: { clock.time })
        clock.time = 2
        lifecycle.setHovered(true)
        clock.time = 90
        XCTAssertFalse(lifecycle.tick())
        lifecycle.setHovered(false)
        clock.time = 92.99
        XCTAssertFalse(lifecycle.tick())
        clock.time = 93
        XCTAssertTrue(lifecycle.tick())
    }

    func testOpeningPreviewPermanentlyStopsCountdown() {
        let clock = TestResultClock()
        let lifecycle = ResultLifecycle(now: { clock.time })
        XCTAssertTrue(lifecycle.openPreview())
        clock.time = 100
        XCTAssertFalse(lifecycle.tick())
        lifecycle.setHovered(false)
        XCTAssertFalse(lifecycle.tick())
        XCTAssertEqual(lifecycle.state, .preview)
    }

    func testLeavingHoverAtDeadlineStillSaves() {
        let clock = TestResultClock()
        let lifecycle = ResultLifecycle(now: { clock.time })
        clock.time = 5
        lifecycle.setHovered(true)
        clock.time = 10
        lifecycle.setHovered(false)
        XCTAssertTrue(lifecycle.tick())
    }

    func testRepeatedCloseRequestsStartOnlyOneSave() {
        let lifecycle = ResultLifecycle(presentation: .preview)
        XCTAssertTrue(lifecycle.beginSave())
        XCTAssertFalse(lifecycle.beginSave())
        XCTAssertFalse(lifecycle.discard())
        lifecycle.saved()
        XCTAssertFalse(lifecycle.beginSave())
        XCTAssertFalse(lifecycle.discard())
    }

    func testDiscardNeverStartsSave() {
        let lifecycle = ResultLifecycle(presentation: .preview)
        XCTAssertTrue(lifecycle.discard())
        XCTAssertEqual(lifecycle.state, .resolved)
        XCTAssertFalse(lifecycle.beginSave())
    }

    func testSaveFailureRetainsResultAndAllowsExplicitRetry() {
        let clock = TestResultClock()
        let lifecycle = ResultLifecycle(now: { clock.time })
        clock.time = 5
        XCTAssertTrue(lifecycle.tick())
        lifecycle.saveFailed()
        XCTAssertEqual(lifecycle.state, .thumbnail)
        clock.time = 100
        XCTAssertFalse(lifecycle.tick(), "Do not repeatedly auto-save into an unwritable directory")
        XCTAssertTrue(lifecycle.openPreview())
        XCTAssertTrue(lifecycle.beginSave())
        lifecycle.saveFailed()
        XCTAssertEqual(lifecycle.state, .preview)
        XCTAssertTrue(lifecycle.beginSave())
    }

    func testPNGPreservesPixelDimensionsColorsAndFilenameCollision() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResultStore()
        let image = try makeResultImage()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try store.save(image: image, to: directory, capturedAt: timestamp)
        let original = try Data(contentsOf: first)
        let second = try store.save(image: image, to: directory, capturedAt: timestamp)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), original, "A filename collision must not overwrite a saved capture")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(second as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 12)
        XCTAssertEqual(decoded.height, 24)
        XCTAssertEqual(try rgbaBytes(decoded), try rgbaBytes(image))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.allSatisfy { $0.hasSuffix(".png") }, "Successful saves leave no staging files")
    }

    func testInvalidDirectoryDoesNotLoseOrMutateResult() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try makeResultImage()
        let bytes = try rgbaBytes(image)
        let file = directory.appendingPathComponent("not-a-directory")
        try Data([1, 2, 3]).write(to: file)
        XCTAssertThrowsError(try ResultStore().save(image: image, to: file, capturedAt: Date()))
        XCTAssertEqual(try rgbaBytes(image), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["not-a-directory"])
    }

    func testUnwritableDirectoryLeavesNoTemporaryFile() throws {
        let directory = try makeDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try ResultStore().save(image: self.makeResultImage(), to: directory, capturedAt: Date()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testSegmentRangesCoverEveryPixelWithExactOverlapAndNoEmptyTail() throws {
        let options = SegmentExportOptions(length: 256, overlap: 32)
        XCTAssertEqual(try options.ranges(imageLength: 480), [0..<256, 224..<480])
        XCTAssertEqual(try options.ranges(imageLength: 481), [0..<256, 224..<480, 448..<481])
        XCTAssertEqual(try options.ranges(imageLength: 20), [0..<20])
        XCTAssertThrowsError(try SegmentExportOptions(length: 256, overlap: 256).ranges(imageLength: 600))
        XCTAssertThrowsError(try SegmentExportOptions(length: 256, overlap: 129).ranges(imageLength: 600))
        XCTAssertThrowsError(try SegmentExportOptions(length: 0, overlap: 0).ranges(imageLength: 600))
        XCTAssertThrowsError(try SegmentExportOptions(length: 20_001, overlap: 0).ranges(imageLength: 600))
        XCTAssertThrowsError(try SegmentExportOptions(length: 256, overlap: -1).ranges(imageLength: 600))
    }

    func testGroupSaveAndSegmentExportPreservePixelsAndNeverOverwrite() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let canvas = TestCanvas(width: 120)
        let document = CaptureDocument(pages: [CapturePage(image: canvas.frame(at: 0, height: 600)),
            CapturePage(image: canvas.frame(at: 500, height: 400), origin: 500)])
        let store = ResultStore()
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try store.save(document: document, to: directory, capturedAt: time)
        let second = try store.save(document: document, to: directory, capturedAt: time)
        XCTAssertNotEqual(first, second)
        let files = try FileManager.default.contentsOfDirectory(at: first, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        XCTAssertEqual(files.count, 2)
        for (file, page) in zip(files, document.pages) {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            try assertPixelsEqual(image, page.load())
        }
        let options = SegmentExportOptions(length: 256, overlap: 32)
        let segmented = try store.save(document: document, to: directory, capturedAt: time, segments: options)
        let pieces = try FileManager.default.contentsOfDirectory(at: segmented, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        XCTAssertEqual(pieces.count, 5)
        var index = 0
        for page in document.pages {
            for range in try options.ranges(imageLength: page.height) {
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(pieces[index] as CFURL, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                try assertPixelsEqual(image, canvas.frame(at: page.origin + range.lowerBound, height: range.count))
                index += 1
            }
        }
        XCTAssertEqual(document.pages.count, 2, "Export must not mutate or resolve the original result")
    }

    func testFailedGroupSavePublishesNothingAndRetainsTemporaryPagesForRetry() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = CapturePageArchive()
        let image = try makeResultImage()
        let first = try archive.store(image, origin: 0)
        let second = try archive.store(image, origin: 12)
        let document = CaptureDocument(pages: [first, second], archive: archive)
        let secondURL = try XCTUnwrap(second.fileURL)
        let original = try Data(contentsOf: secondURL)
        try Data([1, 2, 3]).write(to: secondURL)
        XCTAssertThrowsError(try ResultStore().save(document: document, to: directory, capturedAt: Date()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(first.fileURL).path))
        try original.write(to: secondURL)
        XCTAssertNoThrow(try ResultStore().save(document: document, to: directory, capturedAt: Date()))
    }

    func testHorizontalSegmentExportUsesWidthAndPreservesLeftToRightPixelOrder() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let canvas = TestCanvas(width: 120)
        let image = try PixelImage(canvas.frame(at: 0, height: 600)).transposed().cgImage()
        let document = CaptureDocument(pages: [CapturePage(image: image)], axis: .horizontal)
        let options = SegmentExportOptions(length: 256, overlap: 32)
        let folder = try ResultStore().save(document: document, to: directory, capturedAt: Date(), segments: options)
        let pieces = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        XCTAssertEqual(pieces.count, 3)
        for (file, rows) in zip(pieces, try options.ranges(imageLength: 600)) {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
            let actual = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let expected = try PixelImage(canvas.frame(at: rows.lowerBound, height: rows.count)).transposed().cgImage()
            try assertPixelsEqual(actual, expected)
        }
    }

    @MainActor
    func testSegmentExportDoesNotSaveDiscardOrCloseOriginalAndBlocksCloseWhileBusy() async throws {
        _ = NSApplication.shared
        var saves = 0
        var discards = 0
        let started = expectation(description: "export begins")
        var release: CheckedContinuation<URL, Error>?
        let controller = PreviewWindowController(image: NSImage(cgImage: try makeResultImage(), size: NSSize(width: 12, height: 24)),
            onSave: { saves += 1; return URL(fileURLWithPath: "/tmp/unused.png") },
            onDiscard: { discards += 1; return true }, onChooseDirectory: {},
            onExport: { _ in
                try await withCheckedThrowingContinuation { release = $0; started.fulfill() }
            })
        let export = Task { await controller.exportSegments(SegmentExportOptions()) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(controller.windowShouldClose(try XCTUnwrap(controller.window)))
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(discards, 0)
        release?.resume(returning: URL(fileURLWithPath: "/tmp/exported"))
        await export.value
        XCTAssertEqual(saves, 0)
        let content = try XCTUnwrap(controller.window?.contentView)
        XCTAssertTrue(try XCTUnwrap(findButton(titled: "丢弃", in: content)).isEnabled)
        controller.closeAfterResolution()
    }

    @MainActor
    func testFailedSegmentExportLeavesOriginalActionsEnabledForRetry() async throws {
        _ = NSApplication.shared
        var exports = 0
        let controller = PreviewWindowController(image: NSImage(cgImage: try makeResultImage(), size: NSSize(width: 12, height: 24)),
            onSave: { XCTFail("Export must not save/resolve original"); return URL(fileURLWithPath: "/tmp/unused.png") },
            onDiscard: { true }, onChooseDirectory: {}, onExport: { _ in
                exports += 1
                if exports == 1 { throw ResultSaveError.cannotWrite }
                return URL(fileURLWithPath: "/tmp/exported")
            })
        await controller.exportSegments(SegmentExportOptions())
        await controller.exportSegments(SegmentExportOptions())
        XCTAssertEqual(exports, 2)
        let content = try XCTUnwrap(controller.window?.contentView)
        XCTAssertTrue(try XCTUnwrap(findButton(titled: "保存 PNG", in: content)).isEnabled)
        XCTAssertTrue(try XCTUnwrap(findButton(titled: "分段导出…", in: content)).isEnabled)
        controller.closeAfterResolution()
    }

    @MainActor
    func testPageLoadFinishingDuringSaveDoesNotReenablePageSelection() async throws {
        _ = NSApplication.shared
        let image = NSImage(cgImage: try makeResultImage(), size: NSSize(width: 12, height: 24))
        let loading = expectation(description: "page load begins")
        let saving = expectation(description: "save begins")
        var finishLoad: CheckedContinuation<NSImage, Error>?
        var finishSave: CheckedContinuation<URL, Error>?
        let controller = PreviewWindowController(image: image, onSave: {
            try await withCheckedThrowingContinuation { finishSave = $0; saving.fulfill() }
        }, onDiscard: { true }, onChooseDirectory: {}, pageCount: 2, loadPage: { _ in
            try await withCheckedThrowingContinuation { finishLoad = $0; loading.fulfill() }
        })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let content = try XCTUnwrap(controller.window?.contentView)
        let menu = try XCTUnwrap(descendants(content).compactMap { $0 as? NSPopUpButton }
            .first { $0.numberOfItems == 2 })
        menu.selectItem(at: 1)
        menu.sendAction(menu.action, to: menu.target)
        await fulfillment(of: [loading], timeout: 2)
        XCTAssertFalse(controller.windowShouldClose(try XCTUnwrap(controller.window)))
        await fulfillment(of: [saving], timeout: 2)
        finishLoad?.resume(returning: image)
        // Drain the resumed main-actor page task while the save is deliberately suspended.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(menu.isEnabled)
        finishSave?.resume(returning: URL(fileURLWithPath: "/tmp/unused.png"))
        for _ in 0..<20 { await Task.yield() }
        controller.closeAfterResolution()
    }

    @MainActor
    func testNativePreviewCloseSavesOnceAndDoesNotRecurse() async throws {
        _ = NSApplication.shared
        var saves = 0
        let saved = expectation(description: "preview saves")
        let controller = PreviewWindowController(image: NSImage(cgImage: try makeResultImage(), size: NSSize(width: 12, height: 24)),
                                                 onSave: {
            saves += 1
            try await Task.sleep(nanoseconds: 10_000_000)
            saved.fulfill()
            return URL(fileURLWithPath: "/tmp/LongCapture-preview-test.png")
        }, onDiscard: { XCTFail("Normal close must not discard"); return true }, onChooseDirectory: {})
        controller.window?.performClose(nil)
        controller.window?.performClose(nil)
        await fulfillment(of: [saved], timeout: 2)
        await Task.yield()
        XCTAssertEqual(saves, 1)
        controller.window?.performClose(nil)
        await Task.yield()
        XCTAssertEqual(saves, 1)
    }

    @MainActor
    func testNativePreviewDiscardButtonNeverSavesOnClose() async throws {
        _ = NSApplication.shared
        var saves = 0
        var discards = 0
        let controller = PreviewWindowController(image: NSImage(cgImage: try makeResultImage(), size: NSSize(width: 12, height: 24)),
                                                 onSave: {
            saves += 1
            return URL(fileURLWithPath: "/tmp/LongCapture-preview-test.png")
        }, onDiscard: { discards += 1; return true }, onChooseDirectory: {})
        let content = try XCTUnwrap(controller.window?.contentView)
        let discard = try XCTUnwrap(findButton(titled: "丢弃", in: content))
        discard.performClick(nil)
        controller.window?.performClose(nil)
        await Task.yield()
        XCTAssertEqual(discards, 1)
        XCTAssertEqual(saves, 0)
    }

    @MainActor
    func testDeclinedDiscardKeepsPreviewPendingAndCanStillSave() async throws {
        _ = NSApplication.shared
        var discards = 0
        var saves = 0
        let saved = expectation(description: "save remains available after declined discard")
        let controller = PreviewWindowController(image: NSImage(cgImage: try makeResultImage(), size: NSSize(width: 12, height: 24)),
                                                 onSave: {
            saves += 1
            saved.fulfill()
            return URL(fileURLWithPath: "/tmp/LongCapture-preview-test.png")
        }, onDiscard: { discards += 1; return false }, onChooseDirectory: {})
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        let discard = try XCTUnwrap(findButton(titled: "丢弃", in: content))
        discard.performClick(nil)
        XCTAssertEqual(discards, 1)
        XCTAssertFalse(controller.windowShouldClose(window), "Declined discard must not resolve the preview or allow an unsaved close")
        await fulfillment(of: [saved], timeout: 2)
        await Task.yield()
        XCTAssertEqual(saves, 1)
        XCTAssertTrue(controller.windowShouldClose(window))
    }

    @MainActor
    private func findButton(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { self.findButton(titled: title, in: $0) }.first
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LongCapture-ResultTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeResultImage() throws -> CGImage {
        let width = 12, height = 24
        let bytes = (0..<(width * height)).flatMap { i -> [UInt8] in
            [UInt8(i % 251), UInt8((i * 7) % 251), UInt8((i * 19) % 251), 255]
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}

private final class TestResultClock {
    var time: TimeInterval = 0
}
