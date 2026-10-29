import AppKit
import XCTest
@testable import LongCapture

final class FramePipelineTests: XCTestCase {
    func testLatestPendingFrameReplacesBacklogAndFinishConsumesTail() {
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let resultReady = expectation(description: "finish after tail")
        let recorder = FrameRecorder()
        let image = Self.image()
        let pipeline = FrameProcessingPipeline(accept: { frame in
            let index = recorder.append(frame)
            if index == 1 {
                firstStarted.signal()
                _ = releaseFirst.wait(timeout: .now() + 5)
            }
            return StitchUpdate(action: .grew, height: index, message: nil)
        }, finish: {
            XCTAssertEqual(recorder.count, 2, "Only in-flight frame and latest tail are retained")
            return StitchedCapture(image: image, incomplete: false, reason: nil)
        }, cancel: {}, onUpdate: { _ in })
        pipeline.submit(image)
        XCTAssertEqual(firstStarted.wait(timeout: .now() + 3), .success)
        for _ in 0..<100 { pipeline.submit(image) }
        pipeline.finish { result in
            switch result {
            case .success: break
            case .failure(let error): XCTFail(error.localizedDescription)
            }
            resultReady.fulfill()
        }
        pipeline.submit(image)
        releaseFirst.signal()
        wait(for: [resultReady], timeout: 5)
    }

    func testCancellationDropsPendingAndSuppressesLateUpdates() {
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let cancelled = expectation(description: "cancel reaches worker")
        let unexpectedUpdate = expectation(description: "no late update")
        unexpectedUpdate.isInverted = true
        let recorder = FrameRecorder()
        let pipeline = FrameProcessingPipeline(accept: { frame in
            _ = recorder.append(frame)
            firstStarted.signal()
            _ = releaseFirst.wait(timeout: .now() + 3)
            return StitchUpdate(action: .grew, height: 1, message: nil)
        }, finish: { throw CaptureSessionError.noFrames }, cancel: {
            cancelled.fulfill()
        }, onUpdate: { _ in unexpectedUpdate.fulfill() })
        pipeline.submit(Self.image())
        XCTAssertEqual(firstStarted.wait(timeout: .now() + 3), .success)
        pipeline.submit(Self.image())
        pipeline.cancel()
        pipeline.submit(Self.image())
        releaseFirst.signal()
        wait(for: [cancelled, unexpectedUpdate], timeout: 0.3)
        XCTAssertEqual(recorder.count, 1)
    }

    static func image() -> CGImage {
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 64, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
}

private final class FrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [CGImage] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
    func append(_ image: CGImage) -> Int {
        lock.lock(); defer { lock.unlock() }
        frames.append(image)
        return frames.count
    }
}

@MainActor
final class SessionCoordinatorTests: XCTestCase {
    func testPermissionDeniedReturnsToIdleAndReportsError() async throws {
        let errorReported = expectation(description: "error")
        let session = SessionCoordinator(sourceFactory: { _, _, _ in
            throw ScreenCaptureError.permissionDenied
        }, onResult: { _ in XCTFail("No result on permission failure") },
        onError: { _ in errorReported.fulfill() })
        session.prepareForSelection()
        await session.beginCapture(geometry: try geometry())
        XCTAssertEqual(session.state, .idle)
        await fulfillment(of: [errorReported], timeout: 1)
    }

    func testCancellationRejectsLateFrames() async throws {
        let source = FakeFrameSource()
        let session = SessionCoordinator(sourceFactory: { _, onFrame, _ in
            source.onFrame = onFrame
            return source
        }, onResult: { _ in XCTFail("Cancelled result") }, onError: { _ in XCTFail("Cancelled error") })
        session.prepareForSelection()
        await session.beginCapture(geometry: try geometry())
        await session.cancel()
        source.onFrame?(FramePipelineTests.image())
        XCTAssertEqual(session.state, .idle)
        XCTAssertTrue(source.stopped)
    }

    func testStreamInterruptionPreservesConfirmedResultAndBlocksNewSelection() async throws {
        let source = FakeFrameSource()
        let completed = expectation(description: "partial result")
        let session = SessionCoordinator(sourceFactory: { _, onFrame, onError in
            source.onFrame = onFrame
            source.onError = onError
            return source
        }, onResult: { result in
            XCTAssertTrue(result.incomplete)
            XCTAssertTrue(result.notice?.contains("采集流中断") == true)
            XCTAssertEqual(result.image.width, 16)
            completed.fulfill()
        }, onError: { _ in XCTFail("Must export confirmed content instead of discarding") })
        session.prepareForSelection()
        await session.beginCapture(geometry: try geometry())
        source.onFrame?(FramePipelineTests.image())
        source.onError?(ScreenCaptureError.displayUnavailable)
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(session.state, .result)
        session.prepareForSelection()
        XCTAssertEqual(session.state, .result, "Unresolved result must not be overwritten")
        session.resolveResult()
        XCTAssertEqual(session.state, .idle)
    }

    func testStartupFailureAfterFinishCannotClobberResult() async throws {
        let source = SuspendedFrameSource()
        let started = expectation(description: "source is starting")
        let completed = expectation(description: "tail result")
        source.onStart = { started.fulfill() }
        let session = SessionCoordinator(sourceFactory: { _, onFrame, _ in
            source.onFrame = onFrame
            return source
        }, onResult: { _ in completed.fulfill() }, onError: { _ in XCTFail("Late startup failure must be ignored") })
        session.prepareForSelection()
        let geometry = try geometry()
        let beginning = Task { await session.beginCapture(geometry: geometry) }
        await fulfillment(of: [started], timeout: 3)
        source.onFrame?(FramePipelineTests.image())
        await session.complete()
        await fulfillment(of: [completed], timeout: 3)
        source.failStart()
        await beginning.value
        XCTAssertEqual(session.state, .result)
    }

    func testContinuationKeepsStreamRunningAndFinishDrainsTailForBothAxes() async throws {
        for axis in [CaptureAxis.vertical, .horizontal] {
            for mode in [axis, .automatic] {
                let canvas = TestCanvas(width: 240)
                let source = FakeFrameSource()
                let complete = expectation(description: "multi-page result \(axis)")
                var nextUpdate: XCTestExpectation?
                let session = SessionCoordinator(sourceFactory: { _, onFrame, _ in
                    source.onFrame = onFrame
                    return source
                }, onResult: { result in
                    XCTAssertEqual(result.document.axis, axis)
                    XCTAssertFalse(result.incomplete)
                    XCTAssertEqual(result.document.pages.count, 2)
                    do {
                        for (page, origin) in zip(result.document.pages, [0, 60]) {
                            let expected = canvas.frame(at: origin, height: 180)
                            let oriented = axis == .horizontal ? try PixelImage(expected).transposed().cgImage() : expected
                            try assertPixelsEqual(page.load(), oriented)
                        }
                    } catch { XCTFail(error.localizedDescription) }
                    complete.fulfill()
                }, onError: { XCTFail($0.localizedDescription) }, onUpdate: { update in
                    XCTAssertNotEqual(update.action, .hitLimit)
                    nextUpdate?.fulfill()
                }, controllerFactory: { axis in
                    StitchingController(limits: StitchLimits(maximumPixels: 240 * 180, maximumHeight: 180),
                                        continuesAtLimit: true, axis: axis)
                })
                session.prepareForSelection()
                if mode == .automatic { await session.beginCapture(geometry: try geometry()) }
                else { await session.beginCapture(geometry: try geometry(), axis: mode) }
                for y in [0, 30, 60, 90] {
                    nextUpdate = expectation(description: "frame \(y) \(axis)")
                    let image = canvas.frame(at: y, height: 120)
                    source.onFrame?(axis == .horizontal ? try PixelImage(image).transposed().cgImage() : image)
                    await fulfillment(of: [try XCTUnwrap(nextUpdate)], timeout: 3)
                    nextUpdate = nil
                    XCTAssertEqual(session.state, .capturing)
                    XCTAssertFalse(source.stopped)
                }
                let tail = canvas.frame(at: 120, height: 120)
                source.onFrame?(axis == .horizontal ? try PixelImage(tail).transposed().cgImage() : tail)
                await session.complete()
                await fulfillment(of: [complete], timeout: 4)
                XCTAssertTrue(source.stopped)
                XCTAssertEqual(session.state, .result)
            }
        }
    }

    private func geometry() throws -> CaptureGeometry {
        try CaptureGeometry(displayID: 1, displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                            selection: CGRect(x: 10, y: 10, width: 400, height: 300), scale: 1)
    }
}

private final class FakeFrameSource: CaptureFrameSource {
    var onFrame: ((CGImage) -> Void)?
    var onError: ((Error) -> Void)?
    var stopped = false
    func start() async throws {}
    func stop() async { stopped = true }
}

private final class SuspendedFrameSource: CaptureFrameSource {
    var onFrame: ((CGImage) -> Void)?
    var onStart: (() -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?
    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            onStart?()
        }
    }
    func stop() async {}
    func failStart() {
        continuation?.resume(throwing: ScreenCaptureError.displayUnavailable)
        continuation = nil
    }
}
