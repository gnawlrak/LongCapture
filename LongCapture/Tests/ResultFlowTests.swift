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
