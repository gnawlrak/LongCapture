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

    func testOneToThreePixelScrollsAccumulateWithBoundedViewportBuffers() throws {
        let canvas = TestCanvas()
        let shifts = Array(repeating: [1, 2, 3], count: 20).flatMap { $0 }
        let sut = StitchingController(estimator: ScriptedEstimator(shifts.map(Optional.some)))
        var y = 0
        _ = sut.accept(canvas.frame(at: y, height: 160))
        for shift in shifts {
            y += shift
            XCTAssertEqual(sut.accept(canvas.frame(at: y, height: 160)).action, .grew)
            XCTAssertLessThanOrEqual(sut.retainedPixelBytes, canvas.width * (160 + y + 2 * 160) * 4)
        }
        let outputBytes = canvas.width * (160 + y) * 4
        XCTAssertGreaterThanOrEqual(sut.retainedPixelBytes, outputBytes)
        XCTAssertLessThanOrEqual(sut.retainedPixelBytes, outputBytes + 2 * canvas.width * 160 * 4)
        try assertPixelsEqual(sut.finish().image, canvas.frame(at: 0, height: 160 + y))
        XCTAssertEqual(sut.retainedPixelBytes, 0)
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
        XCTAssertEqual(sut.retainedPixelBytes, canvas.width * 100 * 4)
        try assertPixelsEqual(sut.finish().image, canvas.frame(at: 0, height: 100))
    }

    func testCancelAndFinishAreTerminal() throws {
        let sut = StitchingController()
        _ = sut.accept(TestCanvas.blank())
        sut.cancel()
        XCTAssertEqual(sut.retainedPixelBytes, 0)
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

    func testRealVisionDownwardCaptureDoesNotRepeatViewportFooterOrFade() throws {
        let canvas = TextTestCanvas()
        let sut = StitchingController()
        let positions = [80, 100, 136, 178, 211, 246, 286]
        for y in positions {
            let frame = try withViewportOverlay(canvas.frame(at: y, height: 480), edge: .bottom)
            let update = sut.accept(frame)
            XCTAssertEqual(update.action, .grew, update.message ?? "No reason")
        }
        let result = try sut.finish()
        XCTAssertFalse(result.incomplete)
        let expected = try withViewportOverlay(canvas.frame(at: 80, height: 686), edge: .bottom)
        try assertPixelsEqual(result.image, expected)
    }

    func testRealVisionUpwardCaptureDoesNotRepeatViewportHeaderOrFade() throws {
        let canvas = TextTestCanvas()
        let sut = StitchingController()
        for y in [420, 389, 355, 322, 280] {
            let update = sut.accept(try withViewportOverlay(canvas.frame(at: y, height: 480), edge: .top))
            XCTAssertEqual(update.action, .grew, update.message ?? "No reason")
        }
        let result = try sut.finish()
        XCTAssertFalse(result.incomplete)
        try assertPixelsEqual(result.image, withViewportOverlay(canvas.frame(at: 280, height: 620), edge: .top))
    }

    func testReverseVisitKeepsCleanFrontierInsteadOfReplacingItWithOldViewport() throws {
        let canvas = TextTestCanvas()
        let positions = [80, 114, 90, 150, 118, 186, 211, 175]
        let sut = StitchingController(estimator: ScriptedEstimator([34, -24, 60, -32, 68, 25, -36]))
        let actions: [StitchAction] = [.grew, .grew, .stayed, .grew, .stayed, .grew, .grew, .stayed]
        for (y, action) in zip(positions, actions) {
            XCTAssertEqual(sut.accept(try withViewportOverlay(canvas.frame(at: y, height: 480), edge: .bottom)).action, action)
        }
        try assertPixelsEqual(sut.finish().image, withViewportOverlay(canvas.frame(at: 80, height: 611), edge: .bottom))
    }

    func testRealVisionSlowScrollDoesNotBakeEdgeControlsIntoEachNewStrip() throws {
        let canvas = TextTestCanvas()
        let sut = StitchingController()
        for y in [120, 121, 123, 126, 127, 129, 132, 133, 135, 138] {
            let update = sut.accept(try withViewportOverlay(canvas.frame(at: y, height: 480), edge: .bottom))
            XCTAssertEqual(update.action, .grew, update.message ?? "No reason")
        }
        try assertPixelsEqual(sut.finish().image, withViewportOverlay(canvas.frame(at: 120, height: 498), edge: .bottom))
    }

    func testUnverifiedSeamCannotAdvanceEvenWithAnInjectedOffset() throws {
        let canvas = TestCanvas()
        let sut = StitchingController(estimator: ScriptedEstimator([40, 40]))
        let first = canvas.frame(at: 0, height: 300)
        _ = sut.accept(first)
        var changed = try PixelImage(canvas.frame(at: 40, height: 300)).pixels
        changed.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for p in stride(from: 0, to: 260 * canvas.width * 4, by: 4) {
                bytes[p] = 255; bytes[p + 1] = 255; bytes[p + 2] = 255
            }
        }
        let bad = TestCanvas.image(width: canvas.width, height: 300, pixels: changed)
        let update = sut.accept(bad)
        XCTAssertEqual(update.action, .needsRecovery)
        XCTAssertEqual(update.height, 300, "Unverified seam must not change position or exported bounds")
        XCTAssertEqual(sut.accept(canvas.frame(at: 40, height: 300)).action, .grew)
        let result = try sut.finish()
        XCTAssertFalse(result.incomplete)
        try assertPixelsEqual(result.image, canvas.frame(at: 0, height: 340))
    }

    func testBothViewportEdgesAreNotRepeatedInEitherDirection() throws {
        let canvas = TextTestCanvas()
        for positions in [[100, 134, 260, 285, 330], [620, 581, 450, 427, 390]] {
            let sut = StitchingController()
            for y in positions {
                let frame = try withViewportOverlay(withViewportOverlay(canvas.frame(at: y, height: 480),
                                                                         edge: .top), edge: .bottom)
                let update = sut.accept(frame)
                XCTAssertEqual(update.action, .grew, update.message ?? "No reason")
            }
            let start = positions.min()!, height = positions.max()! - start + 480
            let expected = try withViewportOverlay(withViewportOverlay(canvas.frame(at: start, height: height),
                                                                       edge: .top), edge: .bottom)
            let result = try sut.finish()
            XCTAssertFalse(result.incomplete)
            try assertPixelsEqual(result.image, expected)
        }
    }

    func testUpwardReverseVisitsRetainTheFrontierNotTheLatestViewport() throws {
        let canvas = TextTestCanvas()
        let sut = StitchingController(estimator: ScriptedEstimator([-30, 28, -68, 35, -85, 24, -55, 21]))
        let positions = [700, 670, 698, 630, 665, 580, 604, 549, 570]
        let actions: [StitchAction] = [.grew, .grew, .stayed, .grew, .stayed, .grew, .stayed, .grew, .stayed]
        for (y, action) in zip(positions, actions) {
            XCTAssertEqual(sut.accept(try withViewportOverlay(canvas.frame(at: y, height: 480), edge: .top)).action,
                           action)
        }
        XCTAssertLessThanOrEqual(sut.retainedPixelBytes, canvas.image.width * (631 + 2 * 480) * 4)
        try assertPixelsEqual(sut.finish().image, withViewportOverlay(canvas.frame(at: 549, height: 631), edge: .top))
    }

    func testPartialCapsSealFrontierWithoutCommittingStaleEdgePixels() throws {
        let canvas = TextTestCanvas()
        for (positions, shift, edge, start) in [([100, 340], 240, ViewportOverlayEdge.bottom, 100),
                                                ([700, 460], -240, ViewportOverlayEdge.top, 580)] {
            let sut = StitchingController(estimator: ScriptedEstimator([shift]),
                limits: StitchLimits(maximumPixels: canvas.image.width * 600, maximumHeight: 50_000))
            XCTAssertEqual(sut.accept(try withViewportOverlay(canvas.frame(at: positions[0], height: 480), edge: edge)).action,
                           .grew)
            XCTAssertEqual(sut.accept(try withViewportOverlay(canvas.frame(at: positions[1], height: 480), edge: edge)).action,
                           .hitLimit)
            XCTAssertEqual(sut.retainedPixelBytes, canvas.image.width * 600 * 4)
            let result = try sut.finish()
            XCTAssertTrue(result.incomplete)
            try assertPixelsEqual(result.image, canvas.frame(at: start, height: 600))
        }
    }

    func testRejectedInteriorSeamDoesNotMoveOrLockStitchState() throws {
        let canvas = TestCanvas()
        var sut = try StitchState(first: PixelImage(canvas.frame(at: 400, height: 300)), limits: .default)
        let blank = try PixelImage(TestCanvas.blank(width: canvas.width, height: 300))
        XCTAssertEqual(sut.accept(blank, shift: 40), .needsRecovery)
        XCTAssertNil(sut.direction)
        XCTAssertEqual(sut.position, 0)
        XCTAssertEqual(sut.upperBound, 0)
        XCTAssertEqual(sut.lowerBound, 300)
        XCTAssertEqual(sut.accept(try PixelImage(canvas.frame(at: 360, height: 300)), shift: -40), .grew)
        XCTAssertEqual(sut.direction, .up)
        try assertPixelsEqual(sut.render(), canvas.frame(at: 360, height: 340))
    }

    func testRealVisionStillRejectsPeriodicRowsWithViewportOverlay() throws {
        let canvas = TestCanvas(repeatedPeriod: 24)
        let sut = StitchingController()
        _ = sut.accept(try withViewportOverlay(canvas.frame(at: 0, height: 480), edge: .bottom))
        let update = sut.accept(try withViewportOverlay(canvas.frame(at: 12, height: 480), edge: .bottom))
        XCTAssertEqual(update.action, .needsRecovery)
        XCTAssertEqual(update.height, 480)
        let result = try sut.finish()
        XCTAssertTrue(result.incomplete)
        try assertPixelsEqual(result.image, withViewportOverlay(canvas.frame(at: 0, height: 480), edge: .bottom))
    }

    func testRealVisionWideRetinaTextWithEdgeOverlayPreservesPixels() throws {
        let canvas = TextTestCanvas(width: 1_280, height: 2_200)
        let sut = StitchingController()
        let positions = [100, 101, 130, 216, 179, 251]
        let actions: [StitchAction] = [.grew, .grew, .grew, .grew, .stayed, .grew]
        for (y, action) in zip(positions, actions) {
            let update = sut.accept(try withViewportOverlay(canvas.frame(at: y, height: 960), edge: .bottom))
            XCTAssertEqual(update.action, action, update.message ?? "No reason")
        }
        let result = try sut.finish()
        XCTAssertFalse(result.incomplete)
        try assertPixelsEqual(result.image, withViewportOverlay(canvas.frame(at: 100, height: 1_111), edge: .bottom))
    }
}
