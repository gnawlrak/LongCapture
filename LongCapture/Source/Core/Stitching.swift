import CoreGraphics
import Foundation
import Vision

struct StitchLimits: Sendable {
    var maximumPixels = 64_000_000
    var maximumHeight = 50_000
    static let `default` = StitchLimits()

    func height(forWidth width: Int) -> Int {
        guard width > 0 else { return 0 }
        return max(0, min(maximumHeight, maximumPixels / width))
    }
}

enum StitchDirection: Equatable { case up, down }
enum StitchAction: Equatable, Sendable { case grew, stayed, needsRecovery, hitLimit, rejected }

struct StitchUpdate: Sendable {
    let action: StitchAction
    let height: Int
    let message: String?

    init(action: StitchAction, height: Int, message: String? = nil) {
        self.action = action; self.height = height; self.message = message
    }
}

struct StitchedCapture {
    let image: CGImage
    let incomplete: Bool
    let reason: String?
}

struct MoveEstimate {
    /// Positive shifts mean the viewport has moved down in document coordinates.
    let shift: Int?
    let message: String?
    init(shift: Int?, message: String? = nil) { self.shift = shift; self.message = message }
}

protocol OffsetEstimating {
    func estimate(previous: PixelImage, current: PixelImage) -> MoveEstimate
}

enum StitchError: Error, Equatable, LocalizedError {
    case noContent, invalidFrame, renderFailed, cancelled, alreadyFinished
    var errorDescription: String? {
        switch self {
        case .noContent: return "尚未收到完整的屏幕画面，请重新采集。"
        case .invalidFrame: return "屏幕画面的像素格式无效。"
        case .renderFailed: return "无法合成长截图。"
        case .cancelled: return "截图已取消。"
        case .alreadyFinished: return "本次截图已结束。"
        }
    }
}

/// Immutable, tightly packed, top-to-bottom sRGB RGBA8 pixels; never aliases a CVPixelBuffer.
struct PixelImage {
    let width: Int
    let height: Int
    let pixels: Data
    var bytesPerRow: Int { width * 4 }

    init(_ image: CGImage) throws {
        let width = image.width, height = image.height
        self.width = width; self.height = height
        guard width > 0, height > 0, width <= Int.max / 4 / height else { throw StitchError.invalidFrame }
        let rowBytes = width * 4
        let byteOrder = image.bitmapInfo.intersection(.byteOrderMask)
        if image.bitsPerComponent == 8, image.bitsPerPixel == 32,
           image.alphaInfo == .premultipliedLast,
           byteOrder == .byteOrder32Big || byteOrder == .byteOrderDefault,
           image.colorSpace?.name == CGColorSpace.sRGB,
           let source = image.dataProvider?.data,
           CFDataGetLength(source) >= image.bytesPerRow * height,
           let pointer = CFDataGetBytePtr(source) {
            var data = Data(count: rowBytes * height)
            data.withUnsafeMutableBytes { destination in
                for y in 0..<height {
                    memcpy(destination.baseAddress!.advanced(by: y * rowBytes),
                           pointer.advanced(by: y * image.bytesPerRow), rowBytes)
                }
            }
            pixels = data
        } else {
            var data = Data(count: rowBytes * height)
            let rendered = data.withUnsafeMutableBytes { destination -> Bool in
                guard let context = CGContext(data: destination.baseAddress, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: rowBytes,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                                CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard rendered else { throw StitchError.invalidFrame }
            pixels = data
        }
    }

    func cgImage() throws -> CGImage {
        try Self.makeImage(width: width, height: height, pixels: pixels)
    }

    static func makeImage(width: Int, height: Int, pixels: Data) throws -> CGImage {
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue |
                                    CGBitmapInfo.byteOrder32Big.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { throw StitchError.renderFailed }
        return image
    }
}

/// The confirmed viewport and the exported interval are intentionally independent.
struct StitchState {
    private struct Strip { let origin: Int; let rows: Int; let pixels: Data }
    private struct Frontier {
        let frame: PixelImage
        let position: Int
        let start: Int
        let end: Int
    }
    private var strips: [Strip] = []
    private var frontier: Frontier?
    let width: Int
    let frameHeight: Int
    let maximumHeight: Int
    private(set) var direction: StitchDirection?
    private(set) var upperBound = 0
    private(set) var lowerBound: Int
    private(set) var position = 0
    private(set) var atLimit: Bool
    var imageHeight: Int { lowerBound - upperBound }
    var retainedPixelBytes: Int {
        strips.reduce(0) { $0 + $1.pixels.count } + (frontier?.frame.pixels.count ?? 0)
    }

    init(first: PixelImage, limits: StitchLimits) throws {
        width = first.width; frameHeight = first.height
        maximumHeight = limits.height(forWidth: first.width)
        guard maximumHeight > 0 else { throw StitchError.invalidFrame }
        lowerBound = min(first.height, maximumHeight)
        atLimit = lowerBound == maximumHeight
        frontier = Frontier(frame: first, position: 0, start: 0, end: lowerBound)
        if atLimit { sealFrontier() }
    }

    mutating func accept(_ frame: PixelImage, shift: Int) -> StitchAction {
        guard frame.width == width, frame.height == frameHeight else { return .needsRecovery }
        guard !atLimit else { return .hitLimit }
        guard shift > -frameHeight, shift < frameHeight else { return .needsRecovery }
        let nextPosition = position + shift
        let nextDirection = direction ?? (shift == 0 ? nil : shift > 0 ? .down : .up)
        let room = maximumHeight - imageHeight
        var added = 0
        if nextDirection == .down {
            let end = nextPosition + frameHeight
            if end > lowerBound {
                added = min(end - lowerBound, room)
                guard let old = frontier,
                      let seam = matchingSeam(old, frame: frame, position: nextPosition) else {
                    return .needsRecovery
                }
                appendRows(from: old.frame, row: old.start - old.position,
                           count: seam - old.start, origin: old.start)
                lowerBound += added
                frontier = Frontier(frame: frame, position: nextPosition, start: seam, end: lowerBound)
            }
        } else if nextDirection == .up, nextPosition < upperBound {
            added = min(upperBound - nextPosition, room)
            let newTop = upperBound - added
            guard let old = frontier,
                  let seam = matchingSeam(old, frame: frame, position: nextPosition) else {
                return .needsRecovery
            }
            appendRows(from: old.frame, row: seam - old.position, count: old.end - seam, origin: seam)
            upperBound = newTop
            frontier = Frontier(frame: frame, position: nextPosition, start: newTop, end: seam)
        }
        position = nextPosition
        direction = nextDirection
        atLimit = imageHeight == maximumHeight
        if atLimit { sealFrontier() }
        return atLimit ? .hitLimit : added > 0 ? .grew : .stayed
    }

    private func matchingSeam(_ old: Frontier, frame: PixelImage, position: Int) -> Int? {
        let shift = position - old.position
        let validator = OverlapValidator()
        guard validator.score(old.frame, frame, shift: shift).isReliable,
              let rows = validator.contentRows(height: frameHeight, shift: shift) else { return nil }
        let start = max(rows.lowerBound, old.start - position)
        let end = min(rows.upperBound, old.end - position)
        guard start < end else { return nil }
        // Keep the growing viewport replaceable; commit only through a verified interior seam.
        let middle = start + (end - start) / 2
        let radius = min(12, (end - start) / 4)
        for distance in 0...(end - start) / 2 {
            for row in distance == 0 ? [middle] : [middle - distance, middle + distance] {
                let band = (row - radius)..<(row + radius + 1)
                guard band.lowerBound >= start, band.upperBound <= end else { continue }
                let score = validator.score(old.frame, frame, shift: shift, rows: band)
                if score.mean <= 0.008, score.badFraction <= 0.02,
                   score.laneMeans.allSatisfy({ $0 <= 0.012 }) { return position + row }
            }
        }
        return nil
    }

    private mutating func sealFrontier() {
        guard let frontier else { return }
        appendRows(from: frontier.frame, row: frontier.start - frontier.position,
                   count: frontier.end - frontier.start, origin: frontier.start)
        self.frontier = nil
    }

    private mutating func appendRows(from frame: PixelImage, row: Int, count: Int, origin: Int) {
        guard count > 0 else { return }
        let start = row * width * 4, end = (row + count) * width * 4
        strips.append(Strip(origin: origin, rows: count, pixels: frame.pixels.subdata(in: start..<end)))
    }

    func render() throws -> CGImage {
        guard imageHeight > 0 else { throw StitchError.noContent }
        var output = Data(count: width * imageHeight * 4)
        output.withUnsafeMutableBytes { destination in
            for strip in strips {
                _ = strip.pixels.withUnsafeBytes { source in
                    memcpy(destination.baseAddress!.advanced(by: (strip.origin - upperBound) * width * 4),
                           source.baseAddress!, strip.rows * width * 4)
                }
            }
            if let frontier {
                _ = frontier.frame.pixels.withUnsafeBytes { source in
                    memcpy(destination.baseAddress!.advanced(by: (frontier.start - upperBound) * width * 4),
                           source.baseAddress!.advanced(by: (frontier.start - frontier.position) * width * 4),
                           (frontier.end - frontier.start) * width * 4)
                }
            }
        }
        return try PixelImage.makeImage(width: width, height: imageHeight, pixels: output)
    }
}

/// Vision proposes a displacement; independent pixels, texture, and alternative offsets must validate it.
struct VisionOffsetEstimator: OffsetEstimating {
    private let maximumShiftFraction = 0.65
    private let validator = OverlapValidator()

    func estimate(previous: PixelImage, current: PixelImage) -> MoveEstimate {
        guard previous.width == current.width, previous.height == current.height,
              previous.width >= 96, previous.height >= 64 else {
            return MoveEstimate(shift: nil, message: "选区太小或画面尺寸发生变化，请重新选择。")
        }
        do {
            let old = try previous.cgImage(), new = try current.cgImage()
            let laneWidth = previous.width / 3
            var candidates: [Double] = []
            for lane in 0..<3 {
                let rect = CGRect(x: lane * laneWidth, y: 0, width: laneWidth, height: previous.height)
                guard let reference = old.cropping(to: rect), let target = new.cropping(to: rect) else { continue }
                let request = VNTranslationalImageRegistrationRequest(targetedCGImage: target)
                try VNImageRequestHandler(cgImage: reference, options: [:]).perform([request])
                guard let transform = request.results?.first?.alignmentTransform,
                      transform.tx.isFinite, transform.ty.isFinite, abs(transform.tx) <= 1.5 else { continue }
                candidates.append(Double(-transform.ty))
            }
            guard candidates.count == 3 else { return unreliable() }
            let maximumShift = Int(Double(previous.height) * maximumShiftFraction)
            // Repeated text can give two lanes the same wrong alias. Validate every proposal on pixels.
            let possibilities = Set(candidates.flatMap { candidate -> [Int] in
                guard abs(candidate) <= Double(maximumShift) else { return [] }
                let nominal = Int(candidate.rounded())
                return (nominal - 2 ... nominal + 2).filter { abs($0) <= maximumShift }
            }).sorted()
            let samples = textureSamples(in: current)
            guard samples.count >= 24 else { return unreliable() }
            let proposed = Set(possibilities)
            let search = possibilities + (-maximumShift...maximumShift).filter { !proposed.contains($0) }
            typealias Match = (shift: Int, mean: Double, badFraction: Double)
            var matches: [Match] = []
            var best: Match?
            // Pixel search also tests offsets Vision missed; it cannot bypass texture or ambiguity gates.
            for shift in search where validator.contentRows(height: current.height, shift: shift) != nil {
                let cutoff = min(0.12, max(0.028, 0.020 + (best?.mean ?? 0.05) * 2))
                let score = sampledError(previous, current, shift: shift, points: samples, cutoff: cutoff)
                let match = (shift: shift, mean: score.mean, badFraction: score.badFraction)
                matches.append(match)
                if match.mean < (best?.mean ?? .infinity) { best = match }
            }
            guard let best, best.mean <= 0.028, best.badFraction <= 0.12,
                  validator.score(previous, current, shift: best.shift).isReliable else { return unreliable() }
            // Repeated list rows can align perfectly at several offsets. Never choose one arbitrarily.
            let ambiguityThreshold = 0.020 + best.mean * 2
            for match in matches where abs(match.shift - best.shift) > 2 {
                if match.mean <= ambiguityThreshold, match.badFraction < 0.16 {
                    return MoveEstimate(shift: nil, message: "画面有重复图案，无法确认位移；请往回滚动恢复或更换选区。")
                }
            }
            return MoveEstimate(shift: best.shift)
        } catch { return unreliable() }
    }

    private func unreliable() -> MoveEstimate {
        MoveEstimate(shift: nil, message: "匹配不可靠，已暂停拼接。请缓慢往回滚动，回到最后确认的位置。")
    }

    private struct SamplePoint { let x: Int; let y: Int }

    private func textureSamples(in image: PixelImage) -> [SamplePoint] {
        let points = image.pixels.withUnsafeBytes { raw -> [SamplePoint] in
            let bytes = raw.bindMemory(to: UInt8.self)
            var result: [SamplePoint] = []
            let margin = image.height / 6
            for y in stride(from: margin, to: image.height - margin - 2, by: max(1, image.height / 128)) {
                for x in stride(from: 0, to: image.width - 2, by: max(1, image.width / 96)) {
                    let p = y * image.bytesPerRow + x * 4
                    var edge = 0
                    for c in 0..<3 {
                        edge += max(abs(Int(bytes[p + c]) - Int(bytes[p + 4 + c])),
                                    abs(Int(bytes[p + c]) - Int(bytes[p + 8 + c])))
                        edge += max(abs(Int(bytes[p + c]) - Int(bytes[p + image.bytesPerRow + c])),
                                    abs(Int(bytes[p + c]) - Int(bytes[p + 2 * image.bytesPerRow + c])))
                    }
                    if edge > 48 { result.append(SamplePoint(x: x, y: y)) }
                }
            }
            return result
        }
        guard points.count > 512 else { return points }
        return (0..<512).map { points[$0 * points.count / 512] }
    }

    /// Test alternative offsets on ink/edges, not mostly-white document margins.
    private func sampledError(_ previous: PixelImage, _ current: PixelImage, shift: Int,
                              points: [SamplePoint], cutoff: Double) -> (mean: Double, badFraction: Double) {
        previous.pixels.withUnsafeBytes { leftRaw in
            current.pixels.withUnsafeBytes { rightRaw in
                let left = leftRaw.bindMemory(to: UInt8.self), right = rightRaw.bindMemory(to: UInt8.self)
                var count = 0, bad = 0, total = 0
                let patchOffsets = [0, 4, current.bytesPerRow]
                let maximumError = cutoff * Double(points.count * 765 * patchOffsets.count)
                let margin = previous.height / 6
                for point in points {
                    let py = point.y + shift
                    guard py >= margin, py < previous.height - margin else { continue }
                    let p = py * previous.bytesPerRow + point.x * 4
                    let q = point.y * current.bytesPerRow + point.x * 4
                    var worst = 0
                    for offset in patchOffsets {
                        for c in 0..<3 {
                            let delta = abs(Int(left[p + offset + c]) - Int(right[q + offset + c]))
                            total += delta; worst = max(worst, delta)
                        }
                    }
                    count += 1
                    if worst > 32 { bad += 1 }
                    if Double(total) > maximumError { return (1, 1) }
                }
                guard count >= max(12, points.count / 4) else { return (1, 1) }
                return (Double(total) / Double(count * 765 * patchOffsets.count), Double(bad) / Double(count))
            }
        }
    }
}

/// Header/footer bands are not dependable document pixels (fades and floating controls).
/// Both viewports must agree on textured interior overlap before any state can advance.
struct OverlapValidator {
    struct Score {
        let mean: Double
        let badFraction: Double
        let laneMeans: [Double]
        let textured: Bool
        var isReliable: Bool {
            textured && mean <= 0.028 && badFraction <= 0.12 && laneMeans.allSatisfy { $0 <= 0.045 }
        }
        static let invalid = Score(mean: 1, badFraction: 1, laneMeans: [1, 1, 1], textured: false)
    }

    func contentRows(height: Int, shift: Int) -> Range<Int>? {
        guard shift > -height, shift < height else { return nil }
        let margin = height / 6
        let start = max(margin, margin - shift), end = min(height - margin, height - margin - shift)
        guard end - start >= max(8, min(24, height / 16)) else { return nil }
        return start..<end
    }

    func score(_ previous: PixelImage, _ current: PixelImage, shift: Int,
               rows requestedRows: Range<Int>? = nil) -> Score {
        guard previous.width == current.width, previous.height == current.height,
              current.width > 1, let content = contentRows(height: current.height, shift: shift) else { return .invalid }
        let rows = requestedRows ?? content
        guard !rows.isEmpty, rows.lowerBound >= content.lowerBound, rows.upperBound <= content.upperBound else {
            return .invalid
        }
        return previous.pixels.withUnsafeBytes { leftRaw in
            current.pixels.withUnsafeBytes { rightRaw in
                let left = leftRaw.bindMemory(to: UInt8.self), right = rightRaw.bindMemory(to: UInt8.self)
                let rowBytes = current.bytesPerRow
                var totals = [Double](repeating: 0, count: 3), counts = [Int](repeating: 0, count: 3)
                var bad = 0, edges = 0, verticalEdges = 0, count = 0
                let nx = min(128, current.width - 1), ny = min(96, rows.count)
                for iy in 0..<ny {
                    let y = rows.lowerBound + iy * rows.count / ny
                    for ix in 0..<nx {
                        let x = ix * (current.width - 1) / nx
                        let p = (y + shift) * rowBytes + x * 4, q = y * rowBytes + x * 4
                        var difference = 0, worst = 0, horizontal = 0, vertical = 0
                        for c in 0..<3 {
                            let value = Int(right[q + c])
                            let delta = abs(Int(left[p + c]) - value)
                            difference += delta; worst = max(worst, delta)
                            horizontal += abs(Int(right[q + 4 + c]) - value)
                            vertical += abs(Int(right[q + rowBytes + c]) - value)
                        }
                        let lane = min(2, x * 3 / current.width)
                        totals[lane] += Double(difference) / 765
                        counts[lane] += 1; count += 1
                        if worst > 32 { bad += 1 }
                        if horizontal + vertical > 48 { edges += 1 }
                        if vertical > 24 { verticalEdges += 1 }
                    }
                }
                let mean = totals.reduce(0, +) / Double(max(1, count))
                let laneMeans = (0..<3).map { totals[$0] / Double(max(1, counts[$0])) }
                return Score(mean: mean, badFraction: Double(bad) / Double(max(1, count)),
                             laneMeans: laneMeans,
                             textured: Double(edges) / Double(max(1, count)) >= 0.012 &&
                                Double(verticalEdges) / Double(max(1, count)) >= 0.004)
            }
        }
    }
}
