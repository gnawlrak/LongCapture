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
    private var strips: [Strip] = []
    let width: Int
    let frameHeight: Int
    let maximumHeight: Int
    private(set) var direction: StitchDirection?
    private(set) var upperBound = 0
    private(set) var lowerBound: Int
    private(set) var position = 0
    private(set) var atLimit: Bool
    var imageHeight: Int { lowerBound - upperBound }
    var retainedStripBytes: Int { strips.reduce(0) { $0 + $1.pixels.count } }

    init(first: PixelImage, limits: StitchLimits) throws {
        width = first.width; frameHeight = first.height
        maximumHeight = limits.height(forWidth: first.width)
        guard maximumHeight > 0 else { throw StitchError.invalidFrame }
        lowerBound = min(first.height, maximumHeight)
        atLimit = lowerBound == maximumHeight
        appendRows(from: first, row: 0, count: lowerBound, origin: 0)
    }

    mutating func accept(_ frame: PixelImage, shift: Int) -> StitchAction {
        guard frame.width == width, frame.height == frameHeight else { return .needsRecovery }
        guard !atLimit else { return .hitLimit }
        guard shift > -frameHeight, shift < frameHeight else { return .needsRecovery }
        if shift != 0, direction == nil { direction = shift > 0 ? .down : .up }
        position += shift
        let room = maximumHeight - imageHeight
        var added = 0
        if direction == .down {
            let end = position + frameHeight
            if end > lowerBound {
                added = min(end - lowerBound, room)
                appendRows(from: frame, row: lowerBound - position, count: added, origin: lowerBound)
                lowerBound += added
            }
        } else if direction == .up, position < upperBound {
            added = min(upperBound - position, room)
            let newTop = upperBound - added
            appendRows(from: frame, row: newTop - position, count: added, origin: newTop)
            upperBound = newTop
        }
        atLimit = imageHeight == maximumHeight
        return atLimit ? .hitLimit : added > 0 ? .grew : .stayed
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
        }
        return try PixelImage.makeImage(width: width, height: imageHeight, pixels: output)
    }
}

/// Vision proposes a displacement; independent pixels, texture, and alternative offsets must validate it.
struct VisionOffsetEstimator: OffsetEstimating {
    private let maximumShiftFraction = 0.65

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
            let median = candidates.sorted()[1]
            guard candidates.filter({ abs($0 - median) <= 1.5 }).count >= 2 else { return unreliable() }
            let maximumShift = Int(Double(previous.height) * maximumShiftFraction)
            guard abs(median) <= Double(maximumShift) else { return unreliable() }
            let nominal = Int(median.rounded())
            let possibilities = (nominal - 2 ... nominal + 2).filter { abs($0) <= maximumShift }
            let scores = possibilities.map { ($0, overlap(previous, current, shift: $0, columns: 64, rows: 96)) }
            guard let best = scores.min(by: { $0.1.mean < $1.1.mean }),
                  best.1.textured, best.1.mean <= 0.028, best.1.badFraction <= 0.12,
                  best.1.laneMeans.allSatisfy({ $0 <= 0.045 }) else { return unreliable() }
            let shift = best.0
            // Repeated list rows can align perfectly at several offsets. Never choose one arbitrarily.
            let samples = textureSamples(in: current)
            let ambiguityThreshold = 0.020 + best.1.mean * 2
            for alternative in -maximumShift...maximumShift where abs(alternative - shift) > 2 {
                let score = sampledError(previous, current, shift: alternative,
                                         points: samples, cutoff: ambiguityThreshold)
                if score.mean <= ambiguityThreshold, score.badFraction < 0.16 {
                    return MoveEstimate(shift: nil, message: "画面有重复图案，无法确认位移；请往回滚动恢复或更换选区。")
                }
            }
            return MoveEstimate(shift: shift)
        } catch { return unreliable() }
    }

    private func unreliable() -> MoveEstimate {
        MoveEstimate(shift: nil, message: "匹配不可靠，已暂停拼接。请缓慢往回滚动，回到最后确认的位置。")
    }

    private struct OverlapScore {
        let mean: Double
        let badFraction: Double
        let laneMeans: [Double]
        let textured: Bool
    }

    private struct SamplePoint { let x: Int; let y: Int }

    private func textureSamples(in image: PixelImage) -> [SamplePoint] {
        let points = image.pixels.withUnsafeBytes { raw -> [SamplePoint] in
            let bytes = raw.bindMemory(to: UInt8.self)
            var result: [SamplePoint] = []
            for y in stride(from: 0, to: image.height - 1, by: max(1, image.height / 128)) {
                for x in stride(from: 0, to: image.width - 1, by: max(1, image.width / 96)) {
                    let p = y * image.bytesPerRow + x * 4
                    var edge = 0
                    for c in 0..<3 {
                        edge += abs(Int(bytes[p + c]) - Int(bytes[p + 4 + c]))
                        edge += abs(Int(bytes[p + c]) - Int(bytes[p + image.bytesPerRow + c]))
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
                let maximumError = cutoff * Double(points.count * 765)
                for point in points {
                    let py = point.y + shift
                    guard py >= 0, py < previous.height else { continue }
                    let p = py * previous.bytesPerRow + point.x * 4
                    let q = point.y * current.bytesPerRow + point.x * 4
                    var worst = 0
                    for c in 0..<3 {
                        let delta = abs(Int(left[p + c]) - Int(right[q + c]))
                        total += delta; worst = max(worst, delta)
                    }
                    count += 1
                    if worst > 32 { bad += 1 }
                    if Double(total) > maximumError { return (1, 1) }
                }
                guard count >= max(12, points.count / 4) else { return (1, 1) }
                return (Double(total) / Double(count * 765), Double(bad) / Double(count))
            }
        }
    }

    private func overlap(_ previous: PixelImage, _ current: PixelImage, shift: Int,
                         columns: Int, rows: Int) -> OverlapScore {
        let overlapHeight = current.height - abs(shift)
        guard overlapHeight > 1 else {
            return OverlapScore(mean: 1, badFraction: 1, laneMeans: [1, 1, 1], textured: false)
        }
        return previous.pixels.withUnsafeBytes { leftRaw in
            current.pixels.withUnsafeBytes { rightRaw in
                let left = leftRaw.bindMemory(to: UInt8.self), right = rightRaw.bindMemory(to: UInt8.self)
                let startY = max(0, -shift), rowBytes = current.bytesPerRow
                var totals = [Double](repeating: 0, count: 3), counts = [Int](repeating: 0, count: 3)
                var bad = 0, edges = 0, verticalEdges = 0, count = 0
                let nx = min(columns, current.width - 1), ny = min(rows, overlapHeight - 1)
                for iy in 0..<ny {
                    let y = startY + iy * (overlapHeight - 1) / ny
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
                return OverlapScore(mean: mean, badFraction: Double(bad) / Double(max(1, count)),
                                    laneMeans: laneMeans,
                                    textured: Double(edges) / Double(max(1, count)) >= 0.012 &&
                                        Double(verticalEdges) / Double(max(1, count)) >= 0.004)
            }
        }
    }
}
