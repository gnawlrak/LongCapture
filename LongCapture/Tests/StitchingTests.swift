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

private final class KnownFramePositionEstimator: OffsetEstimating {
    private var positions: [Data: Double] = [:]

    init(frames: [CGImage], positions: [Double]) throws {
        for (frame, position) in zip(frames, positions) { self.positions[try PixelImage(frame).pixels] = position }
    }

    func estimate(previous: PixelImage, current: PixelImage) -> MoveEstimate {
        guard let old = positions[previous.pixels], let new = positions[current.pixels] else {
            XCTFail("Estimator received an unknown test frame")
            return MoveEstimate(shift: nil)
        }
        return MoveEstimate(shift: Int((new - old).rounded()))
    }
}

final class StitchingTests: XCTestCase {
    func testSparseGalleryBoundarySurvivesSnapSizedMovesWithoutWhiteAliases() throws {
        let canvas = SparseGalleryTestCanvas()
        for axis in [CaptureAxis.horizontal, .vertical] {
            for sign in [1, -1] {
                let positions = sign == 1 ? [1_793, 2_093] : [2_093, 1_793]
                let frames = try positions.map { position -> CGImage in
                    let frame = canvas.frame(at: position)
                    return axis == .horizontal ? frame : try PixelImage(frame).transposed().cgImage()
                }
                let previous = try PixelImage(frames[0]), current = try PixelImage(frames[1])
                let old = try axis == .horizontal ? previous.transposed() : previous
                let new = try axis == .horizontal ? current.transposed() : current
                XCTAssertEqual(VisionOffsetEstimator().estimate(previous: old, current: new).shift, sign * 300)
                for mode in [axis, .automatic] {
                    let sut = StitchingController(axis: mode)
                    _ = sut.accept(frames[0])
                    let update = sut.accept(frames[1])
                    XCTAssertEqual(update.action, .grew, update.message ?? "")
                    let result = try sut.finish()
                    XCTAssertFalse(result.incomplete)
                    let output = try axis == .horizontal ? PixelImage(result.image) : PixelImage(result.image).transposed()
                    let expected = try PixelImage(canvas.frame(at: 1_793, width: 1_540, captions: false))
                    XCTAssertEqual(output.width, expected.width)
                    guard output.width == expected.width else { continue }
                    for row in 0..<canvas.height where !canvas.captionRows.contains(row) {
                        let range = (row * output.bytesPerRow)..<((row + 1) * output.bytesPerRow)
                        XCTAssertEqual(output.pixels.subdata(in: range), expected.pixels.subdata(in: range))
                    }
                }
            }
        }
    }

    func testSparseBoundaryWitnessStillRejectsPeriodicDividers() throws {
        func frame(at position: Int) throws -> PixelImage {
            let width = 240, height = 1_240
            var pixels = Data(repeating: 255, count: width * height * 4)
            pixels.withUnsafeMutableBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for y in 0..<height where (y + position) % 320 >= 300 {
                    for x in 0..<width {
                        for channel in 0..<3 { bytes[(y * width + x) * 4 + channel] = 30 }
                    }
                }
            }
            return try PixelImage(TestCanvas.image(width: width, height: height, pixels: pixels))
        }
        for sign in [1, -1] {
            let previous = try frame(at: 500), current = try frame(at: 500 + sign * 100)
            XCTAssertNil(VisionOffsetEstimator().estimate(previous: previous, current: current).shift)
            let sut = StitchingController()
            _ = sut.accept(try previous.cgImage())
            XCTAssertEqual(sut.accept(try current.cgImage()).action, .needsRecovery)
            let result = try sut.finish()
            XCTAssertTrue(result.incomplete)
            try assertPixelsEqual(result.image, previous.cgImage())
        }
    }

    func testSparseGalleryRetinaOutputKeepsOriginalRigidPixels() throws {
        let canvas = SparseGalleryTestCanvas()
        for sign in [1, -1] {
            let positions = sign == 1 ? [1_793, 2_093] : [2_093, 1_793]
            let sut = StitchingController(axis: .automatic)
            for position in positions {
                XCTAssertEqual(sut.accept(try retinaRaster(canvas.frame(at: position))).action, .grew)
            }
            let result = try sut.finish()
            XCTAssertFalse(result.incomplete)
            let output = try PixelImage(result.image)
            let expected = try PixelImage(retinaRaster(canvas.frame(at: 1_793, width: 1_540, captions: false)))
            XCTAssertEqual(output.width, expected.width)
            XCTAssertEqual(output.height, expected.height)
            guard output.width == expected.width, output.height == expected.height else { continue }
            for row in 0..<output.height where !canvas.captionRows.contains(row / 2) {
                let range = (row * output.bytesPerRow)..<((row + 1) * output.bytesPerRow)
                XCTAssertEqual(output.pixels.subdata(in: range), expected.pixels.subdata(in: range))
            }
        }
    }

    func testParallaxGalleryKeepsRigidArtAndWholeCaptionsInBothDirectionsAndAxes() throws {
        let canvas = ParallaxGalleryTestCanvas()
        for axis in [CaptureAxis.horizontal, .vertical] {
            for sign in [1, -1] {
                let start = sign == 1 ? 0 : 3_280, end = start + sign * 1_640
                let sut = StitchingController(axis: .automatic)
                for offset in stride(from: 0, through: 1_640, by: 40) {
                    let frame = try canvas.frame(at: start + sign * offset)
                    let input = axis == .horizontal ? frame : try PixelImage(frame).transposed().cgImage()
                    let update = sut.accept(input)
                    XCTAssertNotEqual(update.action, .needsRecovery, "\(axis) \(sign) \(offset): \(update.message ?? "")")
                }
                let result = try sut.finish()
                XCTAssertFalse(result.incomplete)
                XCTAssertEqual(result.document.axis, axis)
                let pixels = try axis == .horizontal ? PixelImage(result.image) : PixelImage(result.image).transposed()
                let origin = min(start, end), length = canvas.viewportWidth + abs(end - start)
                XCTAssertEqual(pixels.width, length)
                guard pixels.width == length else { continue }
                let expected = try PixelImage(canvas.image.cropping(to:
                    CGRect(x: origin, y: 0, width: length, height: canvas.height))!)
                for y in 0..<canvas.height where !canvas.captionRows.contains(y) {
                    let row = (y * length * 4)..<((y + 1) * length * 4)
                    XCTAssertEqual(pixels.pixels.subdata(in: row), expected.pixels.subdata(in: row))
                }
                // Every fully visible inner card must retain exactly one uncut 240px caption.
                let y = canvas.captionRows.lowerBound + 4
                for card in (origin / 820 + 1)..<((origin + length) / 820) {
                    let indices = (0..<length).filter { x in
                        let p = (y * length + x) * 4
                        return pixels.pixels[p] == UInt8(50 + card * 11) && pixels.pixels[p + 2] == 52
                    }
                    XCTAssertEqual(indices.count, 240, "Caption \(card) must not be cut, lost or duplicated")
                    if let first = indices.first, let last = indices.last {
                        XCTAssertEqual(last - first, 239)
                        guard last - first == 239 else { continue }
                        for row in canvas.captionRows {
                            let expected = Data((0..<240).flatMap { column -> [UInt8] in
                                let label = UInt32(column) &* 374_761_393
                                return [UInt8(50 + card * 11), UInt8(truncatingIfNeeded: (label ^ (label >> 13)) >> 8),
                                        UInt8(40 + (row - canvas.captionRows.lowerBound) * 3), 255]
                            })
                            let begin = (row * length + first) * 4
                            XCTAssertEqual(pixels.pixels.subdata(in: begin..<(begin + 240 * 4)), expected)
                        }
                    }
                }
            }
        }
    }

    func testLocalizedMotionCannotAuthorizePeriodicContentOrMissingOverlap() throws {
        let canvas = ParallaxGalleryTestCanvas()
        let first = try PixelImage(canvas.frame(at: 0)).transposed()
        let distant = try PixelImage(canvas.frame(at: 4_920)).transposed()
        XCTAssertNil(VisionOffsetEstimator().estimate(previous: first, current: distant).shift)
        let repeated = TestCanvas(width: 240, height: 2_400, repeatedPeriod: 24)
        var changed = try PixelImage(repeated.frame(at: 637, height: 800)).pixels
        changed.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for y in 0..<800 {
                for x in 90..<138 {
                    let p = (y * 240 + x) * 4
                    bytes[p] = 255; bytes[p + 1] = 255; bytes[p + 2] = 255
                }
            }
        }
        XCTAssertNil(VisionOffsetEstimator().estimate(previous: try PixelImage(repeated.frame(at: 600, height: 800)),
            current: try PixelImage(TestCanvas.image(width: 240, height: 800, pixels: changed))).shift)
    }

    func testParallaxMotionStillRequiresARealSeamAndCanRecoverWithoutLosingArt() throws {
        let canvas = ParallaxGalleryTestCanvas(), sut = StitchingController(axis: .automatic)
        for offset in stride(from: 0, through: 1_280, by: 40) {
            XCTAssertNotEqual(sut.accept(try canvas.frame(at: offset)).action, .needsRecovery)
        }
        let paused = sut.accept(try canvas.frame(at: 4_920))
        XCTAssertEqual(paused.action, .needsRecovery)
        XCTAssertEqual(paused.height, 2_080)
        XCTAssertEqual(sut.accept(try canvas.frame(at: 1_280)).progress, .recovered)
        for offset in stride(from: 1_320, through: 1_640, by: 40) {
            XCTAssertNotEqual(sut.accept(try canvas.frame(at: offset)).action, .needsRecovery)
        }
        XCTAssertFalse(try sut.finish().incomplete)

        // Independently moving narrow art that crosses every possible seam may help registration,
        // but cannot be sliced into the result merely because the remaining background is stable.
        let rigid = TestCanvas(width: 240, height: 2_000)
        func crossingFrame(at position: Int, phase: Int) throws -> PixelImage {
            var pixels = try PixelImage(rigid.frame(at: position, height: 800)).pixels
            pixels.withUnsafeMutableBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for y in 0..<800 {
                    for x in 90..<138 {
                        let p = (y * 240 + x) * 4
                        bytes[p] = UInt8(phase); bytes[p + 1] = UInt8(phase); bytes[p + 2] = UInt8(phase)
                    }
                }
            }
            return try PixelImage(TestCanvas.image(width: 240, height: 800, pixels: pixels))
        }
        let old = try crossingFrame(at: 0, phase: 30), new = try crossingFrame(at: 40, phase: 210)
        XCTAssertEqual(VisionOffsetEstimator().estimate(previous: old, current: new).shift, 40)
        var state = try StitchState(first: old, limits: .default)
        XCTAssertEqual(state.accept(new, shift: 40), .needsRecovery)
        XCTAssertEqual(state.position, 0)
        try assertPixelsEqual(state.render(), old.cgImage())
    }

    func testFrozenTableLeadingBandInBothAxesDirectionsAndAutomaticMode() throws {
        for axis in [CaptureAxis.vertical, .horizontal] {
            let canvas = TableTestCanvas(axis: axis), leading = axis == .vertical ? 180 : 280
            for mode in [axis, .automatic] {
                for sign in [1, -1] {
                    let start = sign == 1 ? 500 : 3_500
                    let sut = StitchingController(axis: mode)
                    for offset in [0, 80, 160, 240, 400, 320, 480] {
                        let update = sut.accept(try canvas.frame(at: start + sign * offset, leading: leading))
                        XCTAssertNotEqual(update.action, .needsRecovery, update.message ?? "")
                    }
                    let result = try sut.finish()
                    XCTAssertFalse(result.incomplete)
                    XCTAssertEqual(result.document.axis, axis)
                    try assertPixelsEqual(result.image, canvas.frame(at: sign == 1 ? start : start - 480,
                        length: canvas.viewportLength + 480, leading: leading))
                }
            }
        }
    }

    func testFrozenTableRecoveryRelocatesAndContinuesInBothAxes() throws {
        for axis in [CaptureAxis.vertical, .horizontal] {
            let canvas = TableTestCanvas(axis: axis), leading = axis == .vertical ? 180 : 280
            for sign in [1, -1] {
                let start = sign == 1 ? 500 : 3_500
                let sut = StitchingController(axis: .automatic)
                for offset in stride(from: 0, through: 1_280, by: 80) {
                    let update = sut.accept(try canvas.frame(at: start + sign * offset, leading: leading))
                    XCTAssertNotEqual(update.action, .needsRecovery, "\(axis) \(sign) offset \(offset): \(update.message ?? "")")
                }
                XCTAssertEqual(sut.accept(try canvas.frame(at: 6_000, leading: leading)).action, .needsRecovery)
                let recovered = sut.accept(try canvas.frame(at: start + sign * 137, leading: leading))
                XCTAssertEqual(recovered.progress, .recovered)
                XCTAssertEqual(recovered.height, canvas.viewportLength + 1_280)
                for offset in stride(from: 217, through: 1_497, by: 80) {
                    XCTAssertNotEqual(sut.accept(try canvas.frame(at: start + sign * offset, leading: leading)).action,
                                      .needsRecovery)
                }
                let result = try sut.finish()
                XCTAssertFalse(result.incomplete)
                try assertPixelsEqual(result.image, canvas.frame(at: sign == 1 ? start : start - 1_497,
                    length: canvas.viewportLength + 1_497, leading: leading))
            }
        }
    }

    func testFrozenTableRetinaQuantizationDoesNotHideTheStationaryBand() throws {
        for axis in [CaptureAxis.vertical, .horizontal] {
            let canvas = TableTestCanvas(axis: axis), leading = axis == .vertical ? 180 : 280
            for sign in [1, -1] {
                let start = sign == 1 ? 500 : 3_500, sut = StitchingController(axis: .automatic)
                var phase = 0
                func frame(_ position: Int) throws -> CGImage {
                    defer { phase += 1 }
                    return try retinaRaster(canvas.frame(at: position, leading: leading), ditherPhase: phase)
                }
                for offset in [0, 80, 160, 240, 400, 320, 480] {
                    let update = sut.accept(try frame(start + sign * offset))
                    XCTAssertNotEqual(update.action, .needsRecovery, "\(axis) \(sign): \(update.message ?? "")")
                }
                XCTAssertEqual(sut.accept(try frame(6_000)).action, .needsRecovery)
                XCTAssertEqual(sut.accept(try frame(start + sign * 137)).progress, .recovered)
                for offset in stride(from: 217, through: 537, by: 80) {
                    let update = sut.accept(try frame(start + sign * offset))
                    XCTAssertNotEqual(update.action, .needsRecovery, "\(axis) \(sign): \(update.message ?? "")")
                }
                let result = try sut.finish(), actual = try PixelImage(result.image)
                XCTAssertFalse(result.incomplete); XCTAssertEqual(result.document.axis, axis)
                let expected = try PixelImage(retinaRaster(canvas.frame(at: sign == 1 ? start : start - 537,
                    length: canvas.viewportLength + 537, leading: leading)))
                XCTAssertEqual(actual.width, expected.width); XCTAssertEqual(actual.height, expected.height)
                guard actual.pixels.count == expected.pixels.count else { continue }
                let maximum = zip(actual.pixels, expected.pixels).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
                XCTAssertLessThanOrEqual(maximum, 1)
            }
        }
    }

    func testFrozenTableBothEdgesSurviveContinuationWithoutRepeatingWithinPages() throws {
        for axis in [CaptureAxis.vertical, .horizontal] {
            let canvas = TableTestCanvas(axis: axis)
            let leading = axis == .vertical ? 120 : 240, trailing = axis == .vertical ? 100 : 180
            let width = axis == .vertical ? canvas.image.width : canvas.image.height
            let limit = canvas.viewportLength + 240
            for sign in [1, -1] {
                let start = sign == 1 ? 500 : 3_500
                let sut = StitchingController(limits: StitchLimits(maximumPixels: width * limit, maximumHeight: limit),
                                              continuesAtLimit: true, axis: .automatic)
                for offset in stride(from: 0, through: 480, by: 80) {
                    let update = sut.accept(try canvas.frame(at: start + sign * offset, leading: leading, trailing: trailing))
                    XCTAssertNotEqual(update.action, .needsRecovery, "\(axis) \(sign) offset \(offset): \(update.message ?? "")")
                }
                let result = try sut.finish()
                XCTAssertFalse(result.incomplete)
                XCTAssertEqual(result.document.pages.count, 2)
                guard result.document.pages.count == 2 else { continue }
                for (index, origin) in (sign == 1 ? [0, 240] : [-480, -240]).enumerated() {
                    try assertPixelsEqual(result.document.pages[index].load(), canvas.frame(at: start + origin,
                        length: limit, leading: leading, trailing: trailing))
                }
            }
        }
    }

    func testFrozenTableHeaderCannotAuthorizePeriodicOrBlankBody() throws {
        for axis in [CaptureAxis.vertical, .horizontal] {
            let leading = axis == .vertical ? 180 : 280
            let periodic = TableTestCanvas(axis: axis, repeating: true)
            let repeated = StitchingController(axis: axis)
            let first = try periodic.frame(at: 500, leading: leading)
            _ = repeated.accept(first)
            XCTAssertEqual(repeated.accept(try periodic.frame(at: 537, leading: leading)).action, .needsRecovery)
            let incomplete = try repeated.finish()
            XCTAssertTrue(incomplete.incomplete)
            try assertPixelsEqual(incomplete.image, first)

            let canvas = TableTestCanvas(axis: axis)
            let sut = StitchingController(axis: axis)
            let raw = try PixelImage(canvas.frame(at: 500, leading: leading))
            let normalized = axis == .horizontal ? try raw.transposed() : raw
            _ = sut.accept(try raw.cgImage())
            var blank = Data(repeating: 255, count: normalized.pixels.count)
            blank.replaceSubrange(0..<(leading * normalized.bytesPerRow),
                                  with: normalized.pixels.prefix(leading * normalized.bytesPerRow))
            let image = try PixelImage(TestCanvas.image(width: normalized.width, height: normalized.height, pixels: blank))
            let changed = try (axis == .horizontal ? image.transposed() : image).cgImage()
            XCTAssertEqual(sut.accept(changed).action, .needsRecovery)
            XCTAssertTrue(try sut.finish().incomplete)
        }
    }

    func testFrozenTableWrongInjectedShiftCannotBypassBodyAndSeamValidation() throws {
        XCTAssertNil(OverlapValidator().contentRows(height: 800, shift: 336, insets: MatchingInsets(leading: 280)))
        XCTAssertNotNil(OverlapValidator().contentRows(height: 800, shift: 80, insets: MatchingInsets(leading: 280)))
        for axis in [CaptureAxis.vertical, .horizontal] {
            let canvas = TableTestCanvas(axis: axis), leading = axis == .vertical ? 180 : 280
            let sut = StitchingController(estimator: ScriptedEstimator([51]), axis: axis)
            let first = try canvas.frame(at: 500, leading: leading)
            _ = sut.accept(first)
            XCTAssertEqual(sut.accept(try canvas.frame(at: 580, leading: leading)).action, .needsRecovery)
            let result = try sut.finish()
            XCTAssertTrue(result.incomplete)
            try assertPixelsEqual(result.image, first)
        }
    }

    func testOversizedFrozenBandsFailClosedRatherThanAuthorizeStaticHeader() throws {
        for axis in [CaptureAxis.vertical, .horizontal] {
            let canvas = TableTestCanvas(axis: axis), length = canvas.viewportLength
            for (leading, trailing) in [(length * 3 / 5, 0), (length * 9 / 20, length * 9 / 20)] {
                let first = try canvas.frame(at: 500, leading: leading, trailing: trailing)
                let next = try canvas.frame(at: 517, leading: leading, trailing: trailing)
                let a = try PixelImage(first), b = try PixelImage(next)
                let old = axis == .horizontal ? try a.transposed() : a
                let new = axis == .horizontal ? try b.transposed() : b
                let insets = FrozenEdgeDetector.detect(previous: old, current: new)
                XCTAssertNil(OverlapValidator().contentRows(height: length, shift: 0, insets: insets))
                let sut = StitchingController(axis: axis)
                _ = sut.accept(first)
                XCTAssertEqual(sut.accept(next).action, .needsRecovery)
                let result = try sut.finish()
                XCTAssertTrue(result.incomplete)
                try assertPixelsEqual(result.image, first)
            }
        }
    }

    func testFrozenTableOneLocalMarkerIsNotDistributedBodyEvidence() throws {
        for axis in [CaptureAxis.vertical, .horizontal] {
            let canvas = TableTestCanvas(axis: axis, repeating: true), leading = axis == .vertical ? 180 : 280
            func frame(at position: Int) throws -> CGImage {
                let source = try PixelImage(canvas.frame(at: position, leading: leading))
                let body = axis == .horizontal ? try source.transposed() : source
                var pixels = body.pixels
                pixels.withUnsafeMutableBytes { raw in
                    let bytes = raw.bindMemory(to: UInt8.self), top = 500 + leading + 64 - position
                    for y in top..<(top + 20) {
                        for x in (body.width / 2)..<(body.width / 2 + 20) {
                            let p = (y * body.width + x) * 4
                            for c in 0..<3 { bytes[p + c] = UInt8((x * 17 + (y - top) * 29 + c * 61) % 256) }
                        }
                    }
                }
                let marked = try PixelImage(TestCanvas.image(width: body.width, height: body.height, pixels: pixels))
                return try (axis == .horizontal ? marked.transposed() : marked).cgImage()
            }
            let sut = StitchingController(axis: axis), first = try frame(at: 500)
            _ = sut.accept(first)
            XCTAssertEqual(sut.accept(try frame(at: 537)).action, .needsRecovery)
            let result = try sut.finish()
            XCTAssertTrue(result.incomplete)
            try assertPixelsEqual(result.image, first)
        }
    }

    func testFrozenTableScatteredBodyChangesCannotPreferAShortExactFragment() throws {
        for axis in [CaptureAxis.vertical, .horizontal] {
            let canvas = TableTestCanvas(axis: axis, repeating: true), leading = axis == .vertical ? 180 : 280
            let first = try canvas.frame(at: 500, leading: leading)
            let next = try PixelImage(canvas.frame(at: 537, leading: leading))
            let body = axis == .horizontal ? try next.transposed() : next
            var pixels = body.pixels
            pixels.withUnsafeMutableBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for top in stride(from: leading + 18, to: body.height - body.height / 6 - 12, by: 58) {
                    for y in top..<(top + 10) {
                        for x in 20..<(body.width - 20) {
                            let p = (y * body.width + x) * 4
                            bytes[p] = 60; bytes[p + 1] = 150; bytes[p + 2] = 210
                        }
                    }
                }
            }
            let changed = try PixelImage(TestCanvas.image(width: body.width, height: body.height, pixels: pixels))
            let sut = StitchingController(axis: axis)
            _ = sut.accept(first)
            XCTAssertEqual(sut.accept(try (axis == .horizontal ? changed.transposed() : changed).cgImage()).action,
                           .needsRecovery)
            let result = try sut.finish()
            XCTAssertTrue(result.incomplete)
            try assertPixelsEqual(result.image, first)
        }
    }

    func testPictureHorizontalMatchingRelocationAndContinuedGrowth() throws {
        let canvas = PictureTestCanvas()
        for axis in [CaptureAxis.horizontal, .automatic] {
            for sign in [1, -1] {
                let start = sign == 1 ? 500 : 5_000
                let sut = StitchingController(axis: axis)
                for offset in stride(from: 0, through: 2_400, by: 200) {
                    XCTAssertNotEqual(sut.accept(canvas.frame(at: start + sign * offset)).action, .needsRecovery)
                }
                XCTAssertEqual(sut.accept(canvas.frame(at: 9_000)).action, .needsRecovery)
                let recovered = sut.accept(canvas.frame(at: start + sign * 137))
                XCTAssertEqual(recovered.progress, .recovered)
                XCTAssertEqual(recovered.height, 3_200)
                for offset in stride(from: 337, through: 2_737, by: 200) {
                    XCTAssertNotEqual(sut.accept(canvas.frame(at: start + sign * offset)).action, .needsRecovery)
                }
                let result = try sut.finish()
                XCTAssertFalse(result.incomplete)
                try assertPixelsEqual(result.image, canvas.frame(at: sign == 1 ? start : start - 2_737, width: 3_537))
            }
        }
    }

    func testPictureMatchingStillRejectsPeriodicAndNoOverlapContent() throws {
        let estimator = VisionOffsetEstimator()
        let periodic = PictureTestCanvas(width: 2_400, period: 384)
        let a = try PixelImage(periodic.frame(at: 0)).transposed()
        let b = try PixelImage(periodic.frame(at: 100)).transposed()
        XCTAssertNil(estimator.estimate(previous: a, current: b).shift)
        let canvas = PictureTestCanvas()
        let first = try PixelImage(canvas.frame(at: 500)).transposed()
        let distant = try PixelImage(canvas.frame(at: 9_000)).transposed()
        XCTAssertNil(estimator.estimate(previous: first, current: distant).shift)
        let blank = try PixelImage(TestCanvas.blank(width: 800, height: 160)).transposed()
        XCTAssertNil(estimator.estimate(previous: blank, current: blank).shift)
    }

    func testRetinaPictureRecoveryWithIndependentDisplayQuantization() throws {
        let canvas = PictureTestCanvas()
        for sign in [1, -1] {
            for noisy in [false, true] {
                let start = sign == 1 ? 500 : 5_000, sut = StitchingController(axis: .automatic)
                var phase = 0
                func frame(_ position: Int) throws -> CGImage {
                    defer { phase += 1 }
                    return try retinaRaster(canvas.frame(at: position), ditherPhase: noisy ? phase : nil)
                }
                for offset in stride(from: 0, through: 1_200, by: 200) {
                    let update = sut.accept(try frame(start + sign * offset))
                    XCTAssertNotEqual(update.action, .needsRecovery, "\(sign) noisy \(noisy) \(offset): \(update.message ?? "")")
                }
                XCTAssertEqual(sut.accept(try frame(9_000)).action, .needsRecovery)
                XCTAssertEqual(sut.accept(try frame(start + sign * 137)).progress, .recovered)
                for offset in stride(from: 337, through: 1_537, by: 200) {
                    let update = sut.accept(try frame(start + sign * offset))
                    XCTAssertNotEqual(update.action, .needsRecovery, "\(sign) noisy \(noisy) \(offset): \(update.message ?? "")")
                }
                let result = try sut.finish()
                XCTAssertFalse(result.incomplete)
                XCTAssertEqual(result.document.axis, .horizontal)
                let expected = try PixelImage(retinaRaster(canvas.frame(at: sign == 1 ? start : start - 1_537, width: 2_337)))
                let actual = try PixelImage(result.image)
                XCTAssertEqual(actual.width, expected.width); XCTAssertEqual(actual.height, expected.height)
                guard actual.pixels.count == expected.pixels.count else { continue }
                let maximum = zip(actual.pixels, expected.pixels).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
                XCTAssertLessThanOrEqual(maximum, noisy ? 1 : 0, "Pixel order must survive without resampling or incorrect aliases")
            }
        }
    }

    func testPictureRelocationRejectsChangedBodyAndAcceptsOneLevelRasterNoise() throws {
        let canvas = PictureTestCanvas()
        let sut = StitchingController(axis: .horizontal)
        for x in stride(from: 500, through: 2_900, by: 200) { _ = sut.accept(canvas.frame(at: x)) }
        XCTAssertEqual(sut.accept(canvas.frame(at: 9_000)).action, .needsRecovery)
        var changed = try PixelImage(canvas.frame(at: 637)).pixels
        changed.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for left in [160, 370, 580] {
                for y in 20..<140 {
                    for x in left..<(left + 24) {
                        let p = (y * 800 + x) * 4
                        bytes[p] = 240; bytes[p + 1] = 40; bytes[p + 2] = 80
                    }
                }
            }
        }
        XCTAssertEqual(sut.accept(TestCanvas.image(width: 800, height: 160, pixels: changed)).action, .needsRecovery)
        var noisy = try PixelImage(canvas.frame(at: 637)).pixels
        noisy.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for p in stride(from: 0, to: bytes.count, by: 4) {
                for c in 0..<3 where (p / 4 + c) % 2 == 0 { bytes[p + c] += 1 }
            }
        }
        let recovered = sut.accept(TestCanvas.image(width: 800, height: 160, pixels: noisy))
        XCTAssertEqual(recovered.progress, .recovered)
        XCTAssertEqual(recovered.height, 3_200)
        let result = try sut.finish()
        XCTAssertFalse(result.incomplete)
        try assertPixelsEqual(result.image, canvas.frame(at: 500, width: 3_200))
    }

    func testDisplayQuantizationCannotAuthorizePeriodicPicturesOrChangedBodies() throws {
        let repeated = PictureTestCanvas(width: 2_400, period: 384)
        let estimator = VisionOffsetEstimator()
        let a = try PixelImage(retinaRaster(repeated.frame(at: 0), ditherPhase: 0)).transposed()
        for position in [100, 200, 224, 240] {
            let b = try PixelImage(retinaRaster(repeated.frame(at: position), ditherPhase: 1)).transposed()
            XCTAssertNil(estimator.estimate(previous: a, current: b).shift,
                         "Opposite periodic aliases must reject without sampling outside either viewport")
        }
        let canvas = PictureTestCanvas(), first = try retinaRaster(canvas.frame(at: 500))
        let raw = try PixelImage(retinaRaster(canvas.frame(at: 700)))
        var pixels = raw.pixels
        pixels.withUnsafeMutableBytes { bytes in
            let data = bytes.bindMemory(to: UInt8.self)
            for p in stride(from: 0, to: data.count, by: 4) {
                for c in 0..<3 { data[p + c] += 4 }
            }
        }
        let sut = StitchingController(axis: .horizontal)
        _ = sut.accept(first)
        XCTAssertEqual(sut.accept(TestCanvas.image(width: raw.width, height: raw.height, pixels: pixels)).action,
                       .needsRecovery)
        let result = try sut.finish()
        XCTAssertTrue(result.incomplete)
        try assertPixelsEqual(result.image, first)
    }

    func testMultiscaleTextureCannotTurnALinearGradientIntoRegistrationEvidence() throws {
        var pixels = Data(repeating: 255, count: 800 * 160 * 4)
        pixels.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for y in 0..<160 {
                for x in 0..<800 {
                    for c in 0..<3 { bytes[(y * 800 + x) * 4 + c] = UInt8(50 + x / 8 + y / 8) }
                }
            }
        }
        let frame = try PixelImage(TestCanvas.image(width: 800, height: 160, pixels: pixels)).transposed()
        XCTAssertFalse(OverlapValidator().score(frame, frame, shift: 0).isReliable)
        XCTAssertNil(VisionOffsetEstimator().estimate(previous: frame, current: frame).shift)
    }

    func testHorizontalRecoveryCanRelocateWithinEarlierConfirmedContentWithoutExactAnchor() throws {
        let canvas = HorizontalTextTestCanvas(width: 12_000)
        for axis in [CaptureAxis.horizontal, .automatic] {
            for sign in [1, -1] {
                let start = sign == 1 ? 500 : 4_500
                let sut = StitchingController(axis: axis)
                for offset in stride(from: 0, through: 2_400, by: 200) {
                    XCTAssertNotEqual(sut.accept(canvas.frame(at: start + sign * offset, width: 800, height: 80)).action,
                                      .needsRecovery)
                }
                XCTAssertEqual(sut.accept(canvas.frame(at: sign == 1 ? 8_000 : 9_000, width: 800, height: 80)).action,
                               .needsRecovery)
                let recovered = sut.accept(canvas.frame(at: start + sign * 137, width: 800, height: 80))
                XCTAssertEqual(recovered.action, .stayed)
                XCTAssertEqual(recovered.progress, .recovered)
                XCTAssertNil(recovered.referenceImage)
                XCTAssertEqual(recovered.height, 3_200)
                for offset in stride(from: 337, through: 2_737, by: 200) {
                    XCTAssertNotEqual(sut.accept(canvas.frame(at: start + sign * offset, width: 800, height: 80)).action,
                                      .needsRecovery)
                }
                let result = try sut.finish()
                XCTAssertFalse(result.incomplete)
                try assertPixelsEqual(result.image,
                    canvas.frame(at: sign == 1 ? start : start - 2_737, width: 3_537, height: 80))
                XCTAssertEqual(sut.retainedPixelBytes, 0)
            }
        }
    }

    func testRelocationNeverAddsUnseenContentAndUnrecoveredFinishRetainsConfirmedPixels() throws {
        let canvas = HorizontalTextTestCanvas(width: 12_000)
        let sut = StitchingController(axis: .horizontal)
        for x in stride(from: 500, through: 2_900, by: 200) {
            _ = sut.accept(canvas.frame(at: x, width: 800, height: 80))
        }
        for x in [8_000, 8_200, 8_400] {
            let update = sut.accept(canvas.frame(at: x, width: 800, height: 80))
            XCTAssertEqual(update.action, .needsRecovery)
            XCTAssertEqual(update.height, 3_200)
            XCTAssertNotNil(update.referenceImage)
            XCTAssertLessThanOrEqual(sut.retainedPixelBytes, 80 * 3_200 * 4 + 3 * 80 * 800 * 4)
        }
        let result = try sut.finish()
        XCTAssertTrue(result.incomplete)
        try assertPixelsEqual(result.image, canvas.frame(at: 500, width: 3_200, height: 80))
    }

    func testRecoveryRejectsDistantRepeatedPositionsAndCanStillReturnToLastAnchor() throws {
        let canvas = TestCanvas(width: 80, height: 12_000, repeatedPeriod: 3_200)
        let estimator = ScriptedEstimator(Array(repeating: Optional(200), count: 20) + [nil, nil, -150])
        let sut = StitchingController(estimator: estimator, axis: .horizontal)
        func frame(_ y: Int) throws -> CGImage { try PixelImage(canvas.frame(at: y, height: 800)).transposed().cgImage() }
        for y in stride(from: 0, through: 4_000, by: 200) { _ = sut.accept(try frame(y)) }
        XCTAssertEqual(sut.accept(TestCanvas.blank(width: 800, height: 80)).action, .needsRecovery)
        // Both 137 and 3337 are fully confirmed and pixel-identical. Do not guess the position.
        let ambiguous = sut.accept(try frame(137))
        XCTAssertEqual(ambiguous.action, .needsRecovery)
        XCTAssertEqual(ambiguous.height, 4_800)
        XCTAssertNotNil(ambiguous.referenceImage)
        let recovered = sut.accept(try frame(3_850))
        XCTAssertEqual(recovered.action, .stayed)
        XCTAssertEqual(recovered.progress, .recovered)
        try assertPixelsEqual(sut.finish().image, PixelImage(canvas.frame(at: 0, height: 4_800)).transposed().cgImage())
    }

    func testRelocationRejectsCrossAxisChangesAndCancelReleasesItsIndex() throws {
        let canvas = HorizontalTextTestCanvas(width: 12_000)
        let sut = StitchingController(axis: .horizontal)
        for x in stride(from: 500, through: 2_900, by: 200) {
            _ = sut.accept(canvas.frame(at: x, width: 800, height: 80))
        }
        let changed = try XCTUnwrap(canvas.image.cropping(to: CGRect(x: 637, y: 8, width: 800, height: 80)))
        XCTAssertEqual(sut.accept(changed).action, .needsRecovery)
        XCTAssertEqual(sut.accept(canvas.frame(at: 637, width: 800, height: 80)).progress, .recovered)
        XCTAssertEqual(sut.accept(canvas.frame(at: 8_000, width: 800, height: 80)).action, .needsRecovery)
        sut.cancel()
        XCTAssertEqual(sut.retainedPixelBytes, 0)
        XCTAssertEqual(sut.accept(changed).action, .rejected)
        XCTAssertThrowsError(try sut.finish())
    }

    func testRecoveryViewportAndRelocationPreserveBothDocumentBoundsAndDirection() throws {
        let canvas = TestCanvas(width: 120, height: 3_000)
        for sign in [1, -1] {
            let start = sign == 1 ? 500 : 1_500
            var state = try StitchState(first: PixelImage(canvas.frame(at: start, height: 300)), limits: .default)
            for offset in stride(from: 100, through: 600, by: 100) {
                _ = state.accept(try PixelImage(canvas.frame(at: start + sign * offset, height: 300)), shift: sign * 100)
            }
            let top = state.upperBound, bottom = state.lowerBound, direction = state.direction
            let oldPosition = sign == 1 ? 137 : -137
            let viewport = try XCTUnwrap(state.recoveryViewport(at: oldPosition))
            try assertPixelsEqual(viewport.cgImage(), canvas.frame(at: start + oldPosition, height: 300))
            XCTAssertTrue(state.relocate(to: oldPosition))
            XCTAssertEqual(state.position, oldPosition)
            XCTAssertFalse(state.relocate(to: top - 1))
            XCTAssertFalse(state.relocate(to: bottom - 299))
            XCTAssertNil(state.recoveryViewport(at: top - 1))
            XCTAssertEqual(state.upperBound, top)
            XCTAssertEqual(state.lowerBound, bottom)
            XCTAssertEqual(state.direction, direction)
            try assertPixelsEqual(state.render(), canvas.frame(at: start + top, height: 900))
        }
    }

    func testHorizontalRelocationAfterRolloverKeepsPageOriginsAndSubsequentGrowth() throws {
        let canvas = HorizontalTextTestCanvas(width: 12_000)
        for sign in [1, -1] {
            let start = sign == 1 ? 500 : 6_000
            let sut = StitchingController(limits: StitchLimits(maximumPixels: 80 * 3_200, maximumHeight: 3_200),
                                          continuesAtLimit: true, axis: .automatic)
            for offset in stride(from: 0, through: 4_400, by: 200) {
                XCTAssertNotEqual(sut.accept(canvas.frame(at: start + sign * offset, width: 800, height: 80)).action,
                                  .needsRecovery)
            }
            XCTAssertEqual(sut.accept(canvas.frame(at: 10_000, width: 800, height: 80)).action, .needsRecovery)
            let recovered = sut.accept(canvas.frame(at: start + sign * 2_537, width: 800, height: 80))
            XCTAssertEqual(recovered.progress, .recovered)
            XCTAssertEqual(recovered.pageCount, 2)
            for offset in stride(from: 2_737, through: 4_737, by: 200) {
                XCTAssertNotEqual(sut.accept(canvas.frame(at: start + sign * offset, width: 800, height: 80)).action,
                                  .needsRecovery)
            }
            let result = try sut.finish()
            XCTAssertFalse(result.incomplete)
            XCTAssertEqual(result.document.pages.count, 2)
            let origins = sign == 1 ? [0, 2_400] : [-4_737, -2_400]
            let lengths = sign == 1 ? [3_200, 3_137] : [3_137, 3_200]
            for index in 0..<2 {
                try assertPixelsEqual(result.document.pages[index].load(),
                    canvas.frame(at: start + origins[index], width: lengths[index], height: 80))
            }
        }
    }

    func testRealVisionShortHorizontalTextSelectionsMatchAcceptedGeometry() throws {
        let canvas = HorizontalTextTestCanvas()
        for height in [64, 65, 80, 95, 96, 128] {
            for axis in [CaptureAxis.horizontal, .automatic] {
                for sign in [1, -1] {
                    let sut = StitchingController(axis: axis)
                    for offset in [0, 40, 80, 40, 81, 83, 120] {
                        let update = sut.accept(canvas.frame(at: 500 + sign * offset, width: 800, height: height))
                        XCTAssertNotEqual(update.action, .needsRecovery, "height=\(height), mode=\(axis), sign=\(sign), offset=\(offset): \(update.message ?? "")")
                    }
                    let result = try sut.finish()
                    XCTAssertFalse(result.incomplete)
                    XCTAssertEqual(result.document.axis, .horizontal)
                    try assertPixelsEqual(result.image, canvas.frame(at: sign == 1 ? 500 : 380, width: 920, height: height))
                }
            }
        }
    }

    func testShortHorizontalSelectionsStillRejectBlankAmbiguousAndNoOverlapFrames() throws {
        let canvas = HorizontalTextTestCanvas()
        for axis in [CaptureAxis.horizontal, .automatic] {
            let sut = StitchingController(axis: axis)
            let first = canvas.frame(at: 0, width: 800, height: 64)
            _ = sut.accept(first)
            XCTAssertEqual(sut.accept(canvas.frame(at: 2000, width: 800, height: 64)).action, .needsRecovery)
            XCTAssertEqual(sut.accept(canvas.frame(at: 60, width: 800, height: 64)).action, .grew)
            let result = try sut.finish()
            XCTAssertFalse(result.incomplete)
            try assertPixelsEqual(result.image, canvas.frame(at: 0, width: 860, height: 64))
        }
        let blank = try PixelImage(TestCanvas.blank(width: 64, height: 800))
        XCTAssertNil(VisionOffsetEstimator().estimate(previous: blank, current: blank).shift)
        let repeating = TestCanvas(width: 64, repeatedPeriod: 20)
        XCTAssertNil(VisionOffsetEstimator().estimate(previous: try PixelImage(repeating.frame(at: 0, height: 180)),
            current: try PixelImage(repeating.frame(at: 40, height: 180))).shift)
        let tooSmall = TestCanvas(width: 64)
        XCTAssertNil(VisionOffsetEstimator().estimate(previous: try PixelImage(tooSmall.frame(at: 0, height: 64)),
            current: try PixelImage(tooSmall.frame(at: 10, height: 64))).shift)
    }

    func testAutomaticAxisUsesRealVisionForBothAxesAndDirections() throws {
        let canvas = TestCanvas(width: 240)
        for axis in [CaptureAxis.vertical, .horizontal] {
            for sign in [1, -1] {
                let sut = StitchingController(axis: .automatic)
                func frame(_ y: Int, _ height: Int = 180) throws -> CGImage {
                    let image = canvas.frame(at: y, height: height)
                    return axis == .horizontal ? try PixelImage(image).transposed().cgImage() : image
                }
                XCTAssertEqual(sut.accept(try frame(300)).axis, .automatic)
                let locked = sut.accept(try frame(300 + sign * 40))
                XCTAssertEqual(locked.axis, axis)
                XCTAssertEqual(locked.action, .grew)
                XCTAssertEqual(sut.accept(try frame(300 + sign * 20)).action, .stayed)
                XCTAssertEqual(sut.accept(try frame(300 + sign * 70)).axis, axis)
                let result = try sut.finish()
                XCTAssertFalse(result.incomplete)
                XCTAssertEqual(result.document.axis, axis)
                try assertPixelsEqual(result.image, frame(sign == 1 ? 300 : 230, 250))
            }
        }
    }

    func testAutomaticAxisAccumulatesTinyMotionAndFlushesConfirmedTail() throws {
        let canvas = TestCanvas()
        for axis in [CaptureAxis.vertical, .horizontal] {
            for sign in [1, -1] {
                for end in [3, 4] {
                    let shifts: [Int?] = (1...end).flatMap {
                        axis == .vertical ? [Optional(sign * $0), nil] : [nil, Optional(sign * $0)]
                    }
                    let sut = StitchingController(estimator: ScriptedEstimator(shifts), axis: .automatic)
                    func frame(_ y: Int, _ height: Int = 120) throws -> CGImage {
                        let image = canvas.frame(at: y, height: height)
                        return axis == .horizontal ? try PixelImage(image).transposed().cgImage() : image
                    }
                    _ = sut.accept(try frame(300))
                    for y in 1...end {
                        let update = sut.accept(try frame(300 + sign * y))
                        XCTAssertEqual(update.axis, y < 4 ? .automatic : axis)
                    }
                    let result = try sut.finish()
                    XCTAssertFalse(result.incomplete)
                    try assertPixelsEqual(result.image, frame(sign == 1 ? 300 : 300 - end, 120 + end))
                    XCTAssertEqual(sut.retainedPixelBytes, 0)
                }
            }
        }
    }

    func testAutomaticAxisDoesNotLockOnJitterBlankOrDuplicateFrames() throws {
        let canvas = TestCanvas(width: 240, height: 600)
        let whole = canvas.frame(at: 0, height: 600)
        func crop(_ x: Int, _ y: Int) throws -> CGImage {
            try XCTUnwrap(whole.cropping(to: CGRect(x: x, y: y, width: 160, height: 180)))
        }
        let sut = StitchingController(axis: .automatic)
        _ = sut.accept(try crop(0, 0))
        XCTAssertEqual(sut.accept(try crop(0, 1)).axis, .automatic)
        XCTAssertEqual(sut.accept(try crop(0, 0)).axis, .automatic)
        XCTAssertEqual(sut.accept(try crop(30, 0)).axis, .horizontal)
        try assertPixelsEqual(sut.finish().image, XCTUnwrap(whole.cropping(to: CGRect(x: 0, y: 0, width: 190, height: 180))))
        let blank = TestCanvas.blank()
        let idle = StitchingController(axis: .automatic)
        for _ in 0..<4 { XCTAssertEqual(idle.accept(blank).axis, .automatic) }
        let result = try idle.finish()
        XCTAssertFalse(result.incomplete)
        try assertPixelsEqual(result.image, blank)
    }

    func testAutomaticAxisRejectsDiagonalAndRetainsAnchorForRecovery() throws {
        let whole = TestCanvas(width: 600, height: 600).frame(at: 0, height: 600)
        func crop(_ x: Int, _ y: Int) throws -> CGImage {
            try XCTUnwrap(whole.cropping(to: CGRect(x: x, y: y, width: 240, height: 180)))
        }
        let sut = StitchingController(axis: .automatic)
        _ = sut.accept(try crop(0, 0))
        let bad = sut.accept(try crop(25, 25))
        XCTAssertEqual(bad.axis, .automatic)
        XCTAssertEqual(bad.action, .needsRecovery)
        XCTAssertNotNil(bad.referenceImage)
        XCTAssertEqual(sut.accept(try crop(0, 40)).axis, .vertical)
        // Once locked, perpendicular movement cannot switch axes or skip a gap.
        XCTAssertEqual(sut.accept(try crop(40, 40)).action, .needsRecovery)
        XCTAssertEqual(sut.accept(try crop(0, 60)).axis, .vertical)
        let result = try sut.finish()
        XCTAssertFalse(result.incomplete)
        try assertPixelsEqual(result.image, XCTUnwrap(whole.cropping(to: CGRect(x: 0, y: 0, width: 240, height: 240))))
    }

    func testAutomaticAxisFailurePreservesConfirmedTinyTailAndIncompleteNotice() throws {
        let canvas = TestCanvas()
        let sut = StitchingController(estimator: ScriptedEstimator([2, nil, nil, nil]), axis: .automatic)
        _ = sut.accept(canvas.frame(at: 0, height: 120))
        _ = sut.accept(canvas.frame(at: 2, height: 120))
        XCTAssertEqual(sut.accept(canvas.frame(at: 600, height: 120)).action, .needsRecovery)
        let result = try sut.finish()
        XCTAssertTrue(result.incomplete)
        try assertPixelsEqual(result.image, canvas.frame(at: 0, height: 122))
        let cancelled = StitchingController(axis: .automatic)
        _ = cancelled.accept(canvas.frame(at: 0, height: 120))
        cancelled.cancel()
        XCTAssertEqual(cancelled.retainedPixelBytes, 0)
        XCTAssertEqual(cancelled.accept(canvas.frame(at: 10, height: 120)).action, .rejected)
        XCTAssertThrowsError(try cancelled.finish())
        let recovered = StitchingController(estimator: ScriptedEstimator([nil, nil, 0, 0]), axis: .automatic)
        let anchor = canvas.frame(at: 0, height: 120)
        _ = recovered.accept(anchor)
        XCTAssertEqual(recovered.accept(canvas.frame(at: 600, height: 120)).action, .needsRecovery)
        var pixels = try PixelImage(anchor).pixels
        pixels[0] ^= 1
        let almostIdentical = TestCanvas.image(width: canvas.width, height: 120, pixels: pixels)
        XCTAssertEqual(recovered.accept(almostIdentical).axis, .automatic)
        XCTAssertFalse(try recovered.finish().incomplete)
    }

    func testAutomaticAxisRejectsTwoPlausibleAxesAndUnrelatedFrames() throws {
        func diagonal(_ offset: Int) -> CGImage {
            var pixels = [UInt8](repeating: 255, count: 160 * 160 * 4)
            for y in 0..<160 {
                for x in 0..<160 {
                    let value = UInt8(((x + y + offset) * 73) % 251)
                    for channel in 0..<3 { pixels[(y * 160 + x) * 4 + channel] = value }
                }
            }
            return TestCanvas.image(width: 160, height: 160, pixels: Data(pixels))
        }
        let initial = diagonal(0)
        let ambiguous = StitchingController(estimator: ScriptedEstimator([20, 20]), axis: .automatic)
        _ = ambiguous.accept(initial)
        let update = ambiguous.accept(diagonal(20))
        XCTAssertEqual(update.axis, .automatic)
        XCTAssertEqual(update.action, .needsRecovery)
        let result = try ambiguous.finish()
        XCTAssertTrue(result.incomplete)
        try assertPixelsEqual(result.image, initial)

        let canvas = TestCanvas()
        let unmatched = StitchingController(axis: .automatic)
        _ = unmatched.accept(canvas.frame(at: 0, height: 180))
        XCTAssertEqual(unmatched.accept(canvas.frame(at: 600, height: 180)).action, .needsRecovery)
        XCTAssertTrue(try unmatched.finish().incomplete)
        let repeated = StitchingController(axis: .automatic)
        let pattern = TestCanvas(repeatedPeriod: 20)
        _ = repeated.accept(pattern.frame(at: 0, height: 180))
        XCTAssertEqual(repeated.accept(pattern.frame(at: 40, height: 180)).axis, .automatic)
    }

    func testAutomaticAxisRespectsLimitsAfterResolvingOrientationAndWithoutMovement() throws {
        let canvas = TestCanvas(width: 240)
        let limits = StitchLimits(maximumPixels: 240 * 130, maximumHeight: 130)
        let sut = StitchingController(limits: limits, continuesAtLimit: true, axis: .automatic)
        _ = sut.accept(canvas.frame(at: 0, height: 180))
        XCTAssertEqual(sut.accept(canvas.frame(at: 20, height: 180)).action, .hitLimit)
        let result = try sut.finish()
        XCTAssertTrue(result.incomplete)
        try assertPixelsEqual(result.image, canvas.frame(at: 0, height: 130))
        let idle = StitchingController(limits: limits, axis: .automatic)
        _ = idle.accept(canvas.frame(at: 0, height: 180))
        XCTAssertTrue(try idle.finish().incomplete)
    }

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

    func testZeroRoundedMovesAccumulateWithoutLosingTheReliableOrigin() throws {
        try assertFractionalScrollCanResume { try KnownFramePositionEstimator(frames: $0, positions: $1) }
    }

    func testRealVisionFractionalScrollDoesNotPermanentlyBlockLaterGrowth() throws {
        try assertFractionalScrollCanResume { _, _ in VisionOffsetEstimator() }
    }

    private func assertFractionalScrollCanResume(
        estimator: ([CGImage], [Double]) throws -> any OffsetEstimating
    ) throws {
        let canvas = TestCanvas(height: 2_000)
        for sign in [1.0, -1.0] {
            let base = 500.0, anchor = base + sign * 10
            let fractions = (1...16).map { anchor + sign * Double($0) / 16 }
            let positions = [base, anchor] + fractions + [anchor + sign * 21, anchor + sign * 41]
            let frames = positions.map { canvas.interpolatedFrame(at: $0, height: 300) }
            let sut = StitchingController(estimator: try estimator(frames, positions))
            XCTAssertEqual(sut.accept(frames[0]).action, .grew)
            XCTAssertEqual(sut.accept(frames[1]).action, .grew)
            for frame in frames.dropFirst(2).dropLast(2) { _ = sut.accept(frame) }
            for frame in frames.suffix(2) {
                let update = sut.accept(frame)
                XCTAssertEqual(update.action, .grew, "Rounding must not leave a permanent offset: \(update.message ?? "")")
            }
            let result = try sut.finish()
            XCTAssertFalse(result.incomplete)
            let start = Int(positions.min()!), height = Int(positions.max()!) - start + 300
            try assertPixelsEqual(result.image, canvas.frame(at: start, height: height))
        }
    }

    func testTextureValidationCannotAliasAPairedPixelPattern() throws {
        let canvas = TestCanvas(height: 1_600)
        let estimators: [any OffsetEstimating] = [ScriptedEstimator([64]), VisionOffsetEstimator()]
        for estimator in estimators {
            let sut = StitchingController(estimator: estimator)
            _ = sut.accept(canvas.frame(at: 0, height: 960))
            let update = sut.accept(canvas.frame(at: 64, height: 960))
            XCTAssertEqual(update.action, .grew, update.message ?? "No reason")
            try assertPixelsEqual(sut.finish().image, canvas.frame(at: 0, height: 1_024))
        }
    }

    func testOverlapValidationCannotHideAOnePixelErrorInPairedRows() throws {
        let canvas = TestCanvas(height: 1_600)
        let previous = try PixelImage(canvas.frame(at: 0, height: 960))
        let current = try PixelImage(canvas.frame(at: 65, height: 960))
        let validator = OverlapValidator()
        XCTAssertTrue(validator.score(previous, current, shift: 65).isReliable)
        XCTAssertFalse(validator.score(previous, current, shift: 64).isReliable,
                       "An even sampling grid must not hide the wrong half of each paired row")
    }

    func testOverlapPatchesCannotDiluteAnErrorAtEverySample() throws {
        let canvas = TestCanvas(width: 1_280, height: 480)
        let previous = try PixelImage(canvas.frame(at: 0, height: 480))
        var changed = previous.pixels
        changed.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for ix in 0..<128 {
                let x = ix * (canvas.width - 1) / 128
                let p = (200 * canvas.width + x) * 4
                for c in 0..<3 {
                    bytes[p + c] = bytes[p + c] <= 235 ? bytes[p + c] + 20 : bytes[p + c] - 20
                }
            }
        }
        let current = try PixelImage(TestCanvas.image(width: canvas.width, height: 480, pixels: changed))
        XCTAssertFalse(OverlapValidator().score(previous, current, shift: 0, rows: 200..<201).isReliable,
                       "Correct adjacent pixels must not average away a bad original sample")
    }

    func testManyViewportsDoNotAcquireAnAccumulatedLengthLimit() throws {
        let canvas = TestCanvas(height: 14_000)
        for sign in [1, -1] {
            let positions = (0...200).map { sign == 1 ? 120 + $0 * 64 : 13_000 - $0 * 64 }
            let sut = StitchingController(estimator: ScriptedEstimator(Array(repeating: sign * 64, count: 200)))
            for y in positions {
                let update = sut.accept(canvas.frame(at: y, height: 480))
                guard update.action == .grew else {
                    XCTFail("Unexpected stop after \(update.height) pixels: \(update.message ?? "")")
                    return
                }
            }
            let start = positions.min()!, height = positions.max()! - start + 480
            try assertPixelsEqual(sut.finish().image, canvas.frame(at: start, height: height))
        }
    }

    func testRealVisionContinuesAcrossManyTextViewports() throws {
        let canvas = TextTestCanvas(height: 8_000)
        for sign in [1, -1] {
            let positions = (0...60).map { sign == 1 ? 120 + $0 * 97 : 6_500 - $0 * 97 }
            let sut = StitchingController()
            for y in positions {
                let update = sut.accept(try withViewportOverlay(canvas.frame(at: y, height: 480), edge: sign == 1 ? .bottom : .top))
                guard update.action == .grew else {
                    XCTFail("Unexpected stop at source row \(y), confirmed height \(update.height): \(update.message ?? "")")
                    return
                }
            }
            let start = positions.min()!, height = positions.max()! - start + 480
            let expected = try withViewportOverlay(canvas.frame(at: start, height: height), edge: sign == 1 ? .bottom : .top)
            try assertPixelsEqual(sut.finish().image, expected)
        }
    }

    func testRealVisionFastScrollWithConfirmedInteriorOverlapInBothDirections() throws {
        let canvas = TextTestCanvas(height: 3_000)
        for positions in [[120, 384, 672, 960], [1_600, 1_336, 1_048, 760]] {
            let sut = StitchingController()
            for y in positions {
                let frame = try withViewportOverlay(withViewportOverlay(canvas.frame(at: y, height: 480),
                                                                         edge: .top), edge: .bottom)
                let update = sut.accept(frame)
                XCTAssertEqual(update.action, .grew, "A 55-60% move still has verified body overlap: \(update.message ?? "")")
            }
            let start = positions.min()!, height = positions.max()! - start + 480
            let expected = try withViewportOverlay(withViewportOverlay(canvas.frame(at: start, height: height),
                                                                       edge: .top), edge: .bottom)
            let result = try sut.finish()
            XCTAssertFalse(result.incomplete)
            try assertPixelsEqual(result.image, expected)
        }
    }

    func testRealVisionNumberedListDistinguishesSimilarButNotIdenticalRows() throws {
        let canvas = TextTestCanvas(height: 4_000, lineText: { row in
            String(format: "%04d  An ordinary list item with the same description on every line.", row)
        })
        for positions in [[120, 157, 198, 244, 283], [1_200, 1_163, 1_122, 1_076, 1_037],
                          [3_000, 2_963, 2_926, 2_889, 2_852, 2_815]] {
            let sut = StitchingController()
            for y in positions {
                let update = sut.accept(canvas.frame(at: y, height: 480))
                XCTAssertEqual(update.action, .grew, "Unique row numbers must disambiguate repeated prose: \(update.message ?? "")")
            }
            let result = try sut.finish()
            XCTAssertFalse(result.incomplete)
            let start = positions.min()!, height = positions.max()! - start + 480
            try assertPixelsEqual(result.image, canvas.frame(at: start, height: height))
        }
    }

    func testRealVisionSimilarListWithoutActualOverlapStillRequiresRecovery() throws {
        let canvas = TextTestCanvas(height: 2_400, lineText: { row in
            String(format: "%04d  An ordinary list item with the same description on every line.", row)
        })
        for positions in [[120, 1_480], [1_480, 120], [120, 720], [120, 1_320], [1_720, 120]] {
            let sut = StitchingController()
            let first = canvas.frame(at: positions[0], height: 480)
            _ = sut.accept(first)
            XCTAssertEqual(sut.accept(canvas.frame(at: positions[1], height: 480)).action, .needsRecovery,
                           "Similar wording must not invent a match across missing content")
            let result = try sut.finish()
            XCTAssertTrue(result.incomplete)
            try assertPixelsEqual(result.image, first)
        }
    }

    func testRealVisionRepeatedProseAndOneLocalMarkerRemainAmbiguous() throws {
        for uniqueRow in [nil, 12] {
            let canvas = TextTestCanvas(height: 2_400, lineText: { row in
                row == uniqueRow ? "One isolated marker, not distributed displacement evidence." :
                    "An ordinary list item with the same description on every line."
            })
            let sut = StitchingController()
            let first = canvas.frame(at: 120, height: 480)
            _ = sut.accept(first)
            XCTAssertEqual(sut.accept(canvas.frame(at: 157, height: 480)).action, .needsRecovery)
            let result = try sut.finish()
            XCTAssertTrue(result.incomplete)
            try assertPixelsEqual(result.image, first)
        }
    }

    func testRealVisionNumberedListSlowScrollAndReverseVisitsWithEdgeOverlays() throws {
        let canvas = TextTestCanvas(height: 2_400, lineText: { row in
            String(format: "%04d  An ordinary list item with the same description on every line.", row)
        })
        for sign in [1, -1] {
            let positions = [0, 1, 3, 6, 46, 31, 13, 76].map { 800 + sign * $0 }
            let actions: [StitchAction] = [.grew, .grew, .grew, .grew, .grew, .stayed, .stayed, .grew]
            let sut = StitchingController()
            for (y, action) in zip(positions, actions) {
                let frame = try withViewportOverlay(withViewportOverlay(canvas.frame(at: y, height: 480),
                                                                         edge: .top), edge: .bottom)
                let update = sut.accept(frame)
                XCTAssertEqual(update.action, action, update.message ?? "No reason")
            }
            let start = positions.min()!, height = positions.max()! - start + 480
            let expected = try withViewportOverlay(withViewportOverlay(canvas.frame(at: start, height: height),
                                                                       edge: .top), edge: .bottom)
            let result = try sut.finish()
            XCTAssertFalse(result.incomplete)
            try assertPixelsEqual(result.image, expected)
        }
    }

    func testRealVisionFastOverlapCannotHideCorruptionAndCanRecover() throws {
        let canvas = TestCanvas(height: 2_000)
        for shift in [264, -264] {
            let sut = StitchingController()
            let first = canvas.frame(at: 700, height: 480)
            _ = sut.accept(first)
            let next = canvas.frame(at: 700 + shift, height: 480)
            var pixels = try PixelImage(next).pixels
            let rows = try XCTUnwrap(OverlapValidator().contentRows(height: 480, shift: shift))
            pixels.withUnsafeMutableBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for y in rows {
                    for x in 0..<canvas.width {
                        let p = (y * canvas.width + x) * 4
                        bytes[p] = 255; bytes[p + 1] = 255; bytes[p + 2] = 255
                    }
                }
            }
            let bad = TestCanvas.image(width: canvas.width, height: 480, pixels: pixels)
            XCTAssertEqual(sut.accept(bad).action, .needsRecovery)
            XCTAssertEqual(sut.accept(next).action, .grew, "Rejected content cannot replace the reliable anchor")
            let result = try sut.finish()
            XCTAssertFalse(result.incomplete)
            try assertPixelsEqual(result.image, canvas.frame(at: min(700, 700 + shift), height: 744))
        }
    }

    func testRealVisionListMatchingToleratesOneLevelRasterNoise() throws {
        let canvas = TextTestCanvas(height: 2_400, lineText: { row in
            String(format: "%04d  An ordinary list item with the same description on every line.", row)
        })
        for shift in [37, -37] {
            let previous = try PixelImage(canvas.frame(at: 800, height: 480))
            var pixels = try PixelImage(canvas.frame(at: 800 + shift, height: 480)).pixels
            pixels.withUnsafeMutableBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for p in stride(from: 0, to: bytes.count, by: 4) {
                    for c in 0..<3 { bytes[p + c] = bytes[p + c] == 0 ? 0 : bytes[p + c] - 1 }
                }
            }
            let current = try PixelImage(TestCanvas.image(width: previous.width, height: 480, pixels: pixels))
            XCTAssertEqual(VisionOffsetEstimator().estimate(previous: previous, current: current).shift, shift)
        }
    }

    func testRealVisionPeriodicContentWithScatteredChangesCannotPreferAShortExactFragment() throws {
        let canvas = TextTestCanvas(height: 2_400, lineText: { _ in
            "An ordinary list item with the same description on every line."
        })
        let sut = StitchingController()
        let first = canvas.frame(at: 120, height: 480)
        _ = sut.accept(first)
        var pixels = try PixelImage(canvas.frame(at: 157, height: 480)).pixels
        pixels.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for top in [100, 210, 320] {
                for y in top..<(top + 10) {
                    for x in 18..<50 {
                        let p = (y * canvas.image.width + x) * 4
                        bytes[p] = 60; bytes[p + 1] = 150; bytes[p + 2] = 210
                    }
                }
            }
        }
        let changed = TestCanvas.image(width: canvas.image.width, height: 480, pixels: pixels)
        XCTAssertEqual(sut.accept(changed).action, .needsRecovery,
                       "Avoiding changing regions is not evidence of a larger displacement")
        let result = try sut.finish()
        XCTAssertTrue(result.incomplete)
        try assertPixelsEqual(result.image, first)
    }
    func testContinuationPreservesPixelsInBothDirectionsAndOrdersPagesForReading() throws {
        let canvas = TestCanvas()
        for sign in [1, -1] {
            let start = sign == 1 ? 0 : 600
            let sut = StitchingController(estimator: ScriptedEstimator(Array(repeating: sign * 30, count: 14)),
                limits: StitchLimits(maximumPixels: canvas.width * 190, maximumHeight: 240), continuesAtLimit: true)
            for step in 0...14 {
                let update = sut.accept(canvas.frame(at: start + sign * step * 30, height: 120))
                XCTAssertNotEqual(update.action, .hitLimit)
                XCTAssertNotEqual(update.action, .needsRecovery)
                XCTAssertLessThanOrEqual(sut.retainedPixelBytes, canvas.width * (190 + 240) * 4)
            }
            let result = try sut.finish()
            XCTAssertFalse(result.incomplete)
            XCTAssertGreaterThan(result.document.pages.count, 2)
            var end: Int?
            for page in result.document.pages {
                XCTAssertLessThanOrEqual(page.height, 190)
                if let end { XCTAssertLessThan(page.origin, end, "Adjacent pages must overlap, never skip rows") }
                try assertPixelsEqual(page.load(), canvas.frame(at: start + page.origin, height: page.height))
                end = page.origin + page.height
            }
            XCTAssertEqual(result.document.pages.first?.origin, sign == 1 ? 0 : -420)
            XCTAssertEqual(end, sign == 1 ? 540 : 120)
            XCTAssertEqual(result.document.pages.filter { $0.fileURL != nil }.count,
                           result.document.pages.count - 1, "Upwards capture leaves the in-memory final page first in reading order")
        }
    }

    func testExactCapDoesNotEmitDuplicateContinuationAndReversalDoesNotGrow() throws {
        let canvas = TestCanvas()
        let sut = StitchingController(estimator: ScriptedEstimator([30, 30, -30, 30, 30]),
            limits: StitchLimits(maximumPixels: canvas.width * 180, maximumHeight: 180), continuesAtLimit: true)
        for y in [0, 30, 60, 30, 60] { _ = sut.accept(canvas.frame(at: y, height: 120)) }
        let revisit = sut.accept(canvas.frame(at: 90, height: 120))
        XCTAssertEqual(revisit.action, .grew)
        let result = try sut.finish()
        XCTAssertEqual(result.document.pages.count, 2)
        try assertPixelsEqual(result.document.pages[0].load(), canvas.frame(at: 0, height: 180))
        try assertPixelsEqual(result.document.pages[1].load(), canvas.frame(at: 60, height: 150))

        let exact = StitchingController(estimator: ScriptedEstimator([30, 30]),
            limits: StitchLimits(maximumPixels: canvas.width * 180, maximumHeight: 180), continuesAtLimit: true)
        for y in [0, 30, 60] { _ = exact.accept(canvas.frame(at: y, height: 120)) }
        XCTAssertEqual(try exact.finish().document.pages.count, 1)
    }

    func testRecoveryReferenceAndRevisitStatusDoNotAdvanceReliableAnchor() throws {
        let canvas = TestCanvas()
        let sut = StitchingController(estimator: ScriptedEstimator([30, -15, nil, 15, 30]))
        _ = sut.accept(canvas.frame(at: 0, height: 120))
        _ = sut.accept(canvas.frame(at: 30, height: 120))
        XCTAssertEqual(sut.accept(canvas.frame(at: 15, height: 120)).progress, .revisiting)
        let paused = sut.accept(canvas.frame(at: 600, height: 120))
        XCTAssertNotNil(paused.referenceImage)
        XCTAssertEqual(paused.progress, .recovering)
        XCTAssertEqual(sut.accept(canvas.frame(at: 30, height: 120)).progress, .recovered)
        _ = sut.accept(canvas.frame(at: 60, height: 120))
        try assertPixelsEqual(sut.finish().image, canvas.frame(at: 0, height: 180))
    }

    func testContinuationTemporaryFilesAreReleasedOnCancelAndResultRelease() throws {
        let canvas = TestCanvas()
        let archive = CapturePageArchive()
        var sut: StitchingController? = StitchingController(estimator: ScriptedEstimator([30, 30, 30]),
            limits: StitchLimits(maximumPixels: canvas.width * 180, maximumHeight: 180),
            continuesAtLimit: true, archive: archive)
        for y in [0, 30, 60, 90] { _ = sut?.accept(canvas.frame(at: y, height: 120)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.directory.path))
        sut?.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.directory.path))
        sut = nil
    }

    func testHorizontalCaptureBothDirectionsSlowMotionReversalsAndContinuation() throws {
        let canvas = TestCanvas(width: 180)
        for sign in [1, -1] {
            let start = sign == 1 ? 0 : 600
            let offsets = [0, 30, 60, 30, 90, 91, 92, 120, 150, 180, 210, 240]
            let shifts = zip(offsets, offsets.dropFirst()).map { sign * ($1 - $0) }
            let sut = StitchingController(estimator: ScriptedEstimator(shifts.map(Optional.some)),
                limits: StitchLimits(maximumPixels: 180 * 190, maximumHeight: 240),
                continuesAtLimit: true, axis: .horizontal)
            for offset in offsets {
                let frame = try PixelImage(canvas.frame(at: start + sign * offset, height: 120)).transposed().cgImage()
                let update = sut.accept(frame)
                XCTAssertNotEqual(update.action, .needsRecovery)
                XCTAssertNotEqual(update.action, .hitLimit)
                XCTAssertEqual(update.axis, .horizontal)
            }
            let result = try sut.finish()
            XCTAssertEqual(result.document.axis, .horizontal)
            XCTAssertFalse(result.incomplete)
            XCTAssertGreaterThan(result.document.pages.count, 1)
            for page in result.document.pages {
                XCTAssertLessThanOrEqual(page.width, 190)
                XCTAssertEqual(page.height, 180)
                let expected = try PixelImage(canvas.frame(at: start + page.origin, height: page.width)).transposed().cgImage()
                try assertPixelsEqual(page.load(), expected)
            }
        }
    }

    func testRealVisionHorizontalCaptureAndTransposeRoundTripPreserveAllPixels() throws {
        let canvas = TestCanvas(width: 240)
        let first = canvas.frame(at: 200, height: 180)
        try assertPixelsEqual(PixelImage(first).transposed().transposed().cgImage(), first)
        for sign in [1, -1] {
            let sut = StitchingController(axis: .horizontal)
            for offset in [0, 24, 48, 72] {
                let frame = try PixelImage(canvas.frame(at: 200 + sign * offset, height: 180)).transposed().cgImage()
                XCTAssertNotEqual(sut.accept(frame).action, .needsRecovery)
            }
            let result = try sut.finish()
            let expected = try PixelImage(canvas.frame(at: sign == 1 ? 200 : 128, height: 252)).transposed().cgImage()
            try assertPixelsEqual(result.image, expected)
        }
    }

    func testTransposeHasIndependentKnownPixelOrder() throws {
        let colors: [[UInt8]] = (1...6).map { value in [UInt8(value), UInt8(10 + value), UInt8(20 + value), 255] }
        let pixels = Data(colors.flatMap { $0 })
        let original = try PixelImage.makeImage(width: 3, height: 2, pixels: pixels)
        let transposed = try PixelImage(original).transposed()
        XCTAssertEqual(transposed.width, 2)
        XCTAssertEqual(transposed.height, 3)
        let expected = Data([0, 3, 1, 4, 2, 5].flatMap { colors[$0] })
        XCTAssertEqual(transposed.pixels, expected)
    }

    func testSpoolFailureStopsSafelyWithoutLosingCrossingOverflow() throws {
        let canvas = TestCanvas()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        for sign in [1, -1] {
            let start = sign == 1 ? 0 : 200
            let sut = StitchingController(estimator: ScriptedEstimator([sign * 40, sign * 40]),
                limits: StitchLimits(maximumPixels: canvas.width * 190, maximumHeight: 190),
                continuesAtLimit: true, archive: CapturePageArchive(root: root))
            _ = sut.accept(canvas.frame(at: start, height: 120))
            _ = sut.accept(canvas.frame(at: start + sign * 40, height: 120))
            XCTAssertEqual(sut.accept(canvas.frame(at: start + sign * 80, height: 120)).action, .hitLimit)
            let result = try sut.finish()
            XCTAssertTrue(result.incomplete)
            XCTAssertTrue(result.reason?.contains("临时文件") == true)
            XCTAssertEqual(result.document.pages.count, 2)
            for page in result.document.pages {
                try assertPixelsEqual(page.load(), canvas.frame(at: start + page.origin, height: page.height))
            }
            XCTAssertEqual(result.document.pages.first?.origin, sign == 1 ? 0 : -80)
            XCTAssertEqual(result.document.pages.last.map { $0.origin + $0.height }, sign == 1 ? 200 : 120)
        }
    }

    func testReleasingFinishedDocumentRemovesOnlyItsOwnTemporaryFiles() throws {
        let canvas = TestCanvas()
        let sut = StitchingController(estimator: ScriptedEstimator([30, 30, 30]),
            limits: StitchLimits(maximumPixels: canvas.width * 180, maximumHeight: 180), continuesAtLimit: true)
        for y in [0, 30, 60, 90] { _ = sut.accept(canvas.frame(at: y, height: 120)) }
        var result: StitchedCapture? = try sut.finish()
        let file = try XCTUnwrap(result?.document.pages.first?.fileURL)
        weak let document = result?.document
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        result = nil
        XCTAssertNil(document)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }

    func testContinuationCanRecoverAndFinishIncompleteWithoutDroppingEarlierPages() throws {
        let canvas = TestCanvas()
        let sut = StitchingController(estimator: ScriptedEstimator([30, 30, 30, nil]),
            limits: StitchLimits(maximumPixels: canvas.width * 180, maximumHeight: 180), continuesAtLimit: true)
        for y in [0, 30, 60, 90] { _ = sut.accept(canvas.frame(at: y, height: 120)) }
        XCTAssertEqual(sut.accept(canvas.frame(at: 600, height: 120)).action, .needsRecovery)
        let result = try sut.finish()
        XCTAssertTrue(result.incomplete)
        XCTAssertEqual(result.document.pages.count, 2)
        try assertPixelsEqual(result.document.pages[0].load(), canvas.frame(at: 0, height: 180))
        try assertPixelsEqual(result.document.pages[1].load(), canvas.frame(at: 60, height: 150))
    }

}
