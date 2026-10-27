import CoreGraphics
import XCTest
@testable import LongCapture

private final class ScriptedEstimator: OffsetEstimating {
    var estimates: [MoveEstimate]
    init(_ shifts: [Int?]) { estimates = shifts.map { MoveEstimate(shift: $0, message: $0 == nil ? "Test mismatch" : nil) } }
    func estimate(previous: PixelImage, current: PixelImage) -> MoveEstimate {
        precondition(!estimates.isEmpty, "Unexpected estimator invocation")
        return estimates.removeFirst()
    }
}

final class StitchingTests: XCTestCase {
    func testDownwardOutputHasExactPixelsNotOnlyHeight() throws {
        let canvas = TestCanvas()
        let sut = StitchingController(estimator: ScriptedEstimator([20, 35, 15]))
        for y in [0, 20, 55, 70] { XCTAssertEqual(sut.accept(canvas.frame(at: y, height: 120)).action, .grew) }
        let result = try sut.finish()
        XCTAssertFalse(result.incomplete)
        try assertPixelsEqual(result.image, canvas.frame(at: 0, height: 190))
    }

    func testUpwardOutputPrependsInPixelOrder() throws {
        let canvas = TestCanvas()
        let sut = StitchingController(estimator: ScriptedEstimator([-20, -35, -15]))
        for y in [200, 180, 145, 130] { _ = sut.accept(canvas.frame(at: y, height: 120)) }
        try assertPixelsEqual(sut.finish().image, canvas.frame(at: 130, height: 190))
    }

    func testReverseVisitDoesNotDuplicateOrDeleteDownwardContent() throws {
        let canvas = TestCanvas()
        let sut = StitchingController(estimator: ScriptedEstimator([20, -10, -20, 15, 15, 30]))
        let positions = [20, 40, 30, 10, 25, 40, 70]
        let actions: [StitchAction] = [.grew, .grew, .stayed, .stayed, .stayed, .stayed, .grew]
        for (y, action) in zip(positions, actions) {
            XCTAssertEqual(sut.accept(canvas.frame(at: y, height: 120)).action, action)
        }
        try assertPixelsEqual(sut.finish().image, canvas.frame(at: 20, height: 170))
    }

    func testReverseVisitDoesNotExtendWrongEndOfUpwardCapture() throws {
        let canvas = TestCanvas()
        let sut = StitchingController(estimator: ScriptedEstimator([-20, 10, 30, -50, -50]))
        for y in [200, 180, 190, 220, 170, 120] { _ = sut.accept(canvas.frame(at: y, height: 120)) }
        try assertPixelsEqual(sut.finish().image, canvas.frame(at: 120, height: 200))
    }

    func testOneToThreePixelScrollsAccumulateAndStoreOnlyNewStrips() throws {
        let canvas = TestCanvas()
        let shifts = Array(repeating: [1, 2, 3], count: 20).flatMap { $0 }
        let sut = StitchingController(estimator: ScriptedEstimator(shifts.map(Optional.some)))
        var y = 0
        _ = sut.accept(canvas.frame(at: y, height: 160))
        for shift in shifts { y += shift; _ = sut.accept(canvas.frame(at: y, height: 160)) }
        XCTAssertEqual(sut.retainedStripBytes, canvas.width * (160 + y) * 4)
        try assertPixelsEqual(sut.finish().image, canvas.frame(at: 0, height: 160 + y))
    }

    func testDuplicateFramesDoNotLockDirectionOrAddContent() throws {
        let canvas = TestCanvas()
        let sut = StitchingController(estimator: ScriptedEstimator([-20]))
        let frame = canvas.frame(at: 200, height: 120)
        _ = sut.accept(frame)
        for _ in 0..<5 { XCTAssertEqual(sut.accept(frame).action, .stayed) }
        _ = sut.accept(canvas.frame(at: 180, height: 120))
        try assertPixelsEqual(sut.finish().image, canvas.frame(at: 180, height: 140))
    }

    func testRecoveryUsesLastReliableAnchorAndDoesNotSkipGap() throws {
        let canvas = TestCanvas()
        let sut = StitchingController(estimator: ScriptedEstimator([20, nil, 1, 19]))
        _ = sut.accept(canvas.frame(at: 0, height: 120))
        _ = sut.accept(canvas.frame(at: 20, height: 120))
        XCTAssertEqual(sut.accept(canvas.frame(at: 600, height: 120)).action, .needsRecovery)
        XCTAssertEqual(sut.accept(canvas.frame(at: 21, height: 120)).action, .grew)
        _ = sut.accept(canvas.frame(at: 40, height: 120))
        let result = try sut.finish()
        XCTAssertFalse(result.incomplete)
        try assertPixelsEqual(result.image, canvas.frame(at: 0, height: 160))
    }

    func testEndingDuringRecoveryExportsOnlyConfirmedPixelsAndMarksIncomplete() throws {
        let canvas = TestCanvas()
        let sut = StitchingController(estimator: ScriptedEstimator([20, nil]))
        for y in [0, 20, 600] { _ = sut.accept(canvas.frame(at: y, height: 120)) }
        let result = try sut.finish()
        XCTAssertTrue(result.incomplete)
        XCTAssertNotNil(result.reason)
        try assertPixelsEqual(result.image, canvas.frame(at: 0, height: 140))
    }

    func testHeightCapKeepsConfirmedPartialStripAtExactLimit() throws {
        let canvas = TestCanvas()
        let sut = StitchingController(estimator: ScriptedEstimator([40]), limits: StitchLimits(maximumPixels: 64_000_000, maximumHeight: 145))
        _ = sut.accept(canvas.frame(at: 0, height: 120))
        XCTAssertEqual(sut.accept(canvas.frame(at: 40, height: 120)).action, .hitLimit)
        let result = try sut.finish()
        XCTAssertTrue(result.incomplete)
        try assertPixelsEqual(result.image, canvas.frame(at: 0, height: 145))
    }

    func testPixelCapWinsBeforeHeightAndRetinaResolutionIsPreserved() throws {
        let canvas = TestCanvas(width: 480)
        let sut = StitchingController(estimator: ScriptedEstimator([-50]), limits: StitchLimits(maximumPixels: 480 * 265, maximumHeight: 50_000))
        _ = sut.accept(canvas.frame(at: 200, height: 240))
        XCTAssertEqual(sut.accept(canvas.frame(at: 150, height: 240)).action, .hitLimit)
        let result = try sut.finish()
        XCTAssertEqual(result.image.width, 480)
        try assertPixelsEqual(result.image, canvas.frame(at: 175, height: 265))
    }

    func testDefaultLimitsAndOversizedFirstFrameAreBounded() throws {
        XCTAssertEqual(StitchLimits.default.height(forWidth: 2_000), 32_000)
        XCTAssertEqual(StitchLimits.default.height(forWidth: 500), 50_000)
        let canvas = TestCanvas()
        let sut = StitchingController(limits: StitchLimits(maximumPixels: canvas.width * 100, maximumHeight: 50_000))
        XCTAssertEqual(sut.accept(canvas.frame(at: 0, height: 120)).action, .hitLimit)
        XCTAssertEqual(sut.retainedStripBytes, canvas.width * 100 * 4)
        try assertPixelsEqual(sut.finish().image, canvas.frame(at: 0, height: 100))
    }

    func testCancelAndFinishAreTerminal() throws {
        let sut = StitchingController()
        _ = sut.accept(TestCanvas.blank())
        sut.cancel()
        XCTAssertEqual(sut.accept(TestCanvas.blank()).action, .rejected)
        XCTAssertThrowsError(try sut.finish()) { XCTAssertEqual($0 as? StitchError, .cancelled) }
    }

    func testMismatchedFrameDimensionsDoNotReplaceAnchor() throws {
        let canvas = TestCanvas()
        let sut = StitchingController(estimator: ScriptedEstimator([10]))
        _ = sut.accept(canvas.frame(at: 0, height: 120))
        XCTAssertEqual(sut.accept(canvas.frame(at: 10, height: 121)).action, .needsRecovery)
        _ = sut.accept(canvas.frame(at: 10, height: 120))
        try assertPixelsEqual(sut.finish().image, canvas.frame(at: 0, height: 130))
    }

    func testRealVisionRegistersDownwardAndUpwardPixels() throws {
        let canvas = TestCanvas(width: 240, height: 900)
        for positions in [[200, 221, 255, 257], [300, 271, 240, 237]] {
            let sut = StitchingController()
            for y in positions {
                let update = sut.accept(canvas.frame(at: y, height: 300))
                XCTAssertEqual(update.action, .grew, update.message ?? "No reason")
            }
            let start = positions.min()!, end = positions.max()! + 300
            try assertPixelsEqual(sut.finish().image, canvas.frame(at: start, height: end - start))
        }
    }

    func testRealVisionRejectsBlankRepeatedNoOverlapAndDynamicFrames() throws {
        let estimator = VisionOffsetEstimator()
        let blankA = try PixelImage(TestCanvas.blank(value: 240))
        let blankB = try PixelImage(TestCanvas.blank(value: 230))
        XCTAssertNil(estimator.estimate(previous: blankA, current: blankB).shift)
        let repeated = TestCanvas(height: 900, repeatedPeriod: 24)
        XCTAssertNil(estimator.estimate(previous: try PixelImage(repeated.frame(at: 0, height: 300)),
                                        current: try PixelImage(repeated.frame(at: 12, height: 300))).shift)
        let canvas = TestCanvas()
        let previous = try PixelImage(canvas.frame(at: 0, height: 300))
        XCTAssertNil(estimator.estimate(previous: previous, current: try PixelImage(canvas.frame(at: 600, height: 300))).shift)
        var changed = try PixelImage(canvas.frame(at: 20, height: 300)).pixels
        changed.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for y in 80..<200 { for x in 0..<240 { let i = (y * 240 + x) * 4; p[i] = 255; p[i + 1] = 255; p[i + 2] = 255 } }
        }
        let dynamic = try PixelImage(TestCanvas.image(width: 240, height: 300, pixels: changed))
        XCTAssertNil(estimator.estimate(previous: previous, current: dynamic).shift)
    }

    func testRealVisionMatchesTextDocumentsWithWideWhiteMargins() throws {
        let canvas = TextTestCanvas()
        let sut = StitchingController()
        for y in [120, 121, 123, 126, 162, 210] {
            let update = sut.accept(canvas.frame(at: y, height: 480))
            XCTAssertEqual(update.action, .grew, update.message ?? "No reason")
        }
        try assertPixelsEqual(sut.finish().image, canvas.frame(at: 120, height: 570))
    }

    func testRealVisionRetinaCaptureKeepsEverySourcePixel() throws {
        let canvas = TestCanvas(width: 480)
        let sut = StitchingController()
        for y in [200, 239, 280] {
            XCTAssertEqual(sut.accept(canvas.frame(at: y, height: 480)).action, .grew)
        }
        try assertPixelsEqual(sut.finish().image, canvas.frame(at: 200, height: 560))
    }
}
