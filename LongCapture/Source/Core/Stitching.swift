import CoreGraphics
import Foundation
import Vision

enum CaptureAxis: String, Equatable, Sendable {
    case automatic, vertical, horizontal
    var title: String {
        switch self {
        case .automatic: return "自动"
        case .vertical: return "纵向"
        case .horizontal: return "横向"
        }
    }
    var lengthTitle: String { self == .automatic ? "长度" : self == .vertical ? "高度" : "宽度" }
}

/// Viewport-fixed bands along the normalized scrolling axis; pixels are retained, not cropped.
struct MatchingInsets: Equatable {
    var leading = 0
    var trailing = 0
    static let none = MatchingInsets()
    var isEmpty: Bool { leading == 0 && trailing == 0 }
    func merged(with other: MatchingInsets) -> MatchingInsets {
        MatchingInsets(leading: max(leading, other.leading), trailing: max(trailing, other.trailing))
    }
}

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
enum StitchProgress: Equatable, Sendable { case growing, unchanged, revisiting, recovering, recovered, continued }

struct StitchUpdate: @unchecked Sendable {
    let action: StitchAction
    let height: Int
    let message: String?
    let progress: StitchProgress
    let referenceImage: CGImage?
    let pageCount: Int
    let maximumHeight: Int
    let axis: CaptureAxis

    init(action: StitchAction, height: Int, message: String? = nil,
         progress: StitchProgress = .growing, referenceImage: CGImage? = nil,
         pageCount: Int = 1, maximumHeight: Int = 50_000, axis: CaptureAxis = .vertical) {
        self.action = action; self.height = height; self.message = message
        self.progress = progress; self.referenceImage = referenceImage
        self.pageCount = pageCount; self.maximumHeight = maximumHeight
        self.axis = axis
    }
}

struct StitchedCapture {
    let image: CGImage
    let incomplete: Bool
    let reason: String?
    let document: CaptureDocument

    init(image: CGImage, incomplete: Bool, reason: String?, document: CaptureDocument? = nil) {
        self.image = image; self.incomplete = incomplete; self.reason = reason
        self.document = document ?? CaptureDocument(image: image)
    }
}

struct MoveEstimate {
    enum Failure { case unreliable, ambiguous }
    /// Positive shifts mean the viewport has moved down in document coordinates.
    let shift: Int?
    let message: String?
    let failure: Failure?
    init(shift: Int?, message: String? = nil, failure: Failure? = nil) {
        self.shift = shift; self.message = message; self.failure = failure
    }
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
    let matchingInsets: MatchingInsets
    var bytesPerRow: Int { width * 4 }

    init(_ image: CGImage) throws {
        let width = image.width, height = image.height
        self.width = width; self.height = height
        matchingInsets = .none
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

    /// A lossless transpose maps horizontal movement onto the same checked vertical engine.
    /// Tiling keeps both source and destination accesses local; no resampling or color conversion.
    func transposed() throws -> PixelImage {
        var output = Data(count: pixels.count)
        pixels.withUnsafeBytes { sourceBytes in
            output.withUnsafeMutableBytes { destinationBytes in
                let source = sourceBytes.bindMemory(to: UInt32.self)
                let destination = destinationBytes.bindMemory(to: UInt32.self)
                for top in stride(from: 0, to: height, by: 32) {
                    for left in stride(from: 0, to: width, by: 32) {
                        for y in top..<min(height, top + 32) {
                            for x in left..<min(width, left + 32) {
                                destination[x * height + y] = source[y * width + x]
                            }
                        }
                    }
                }
            }
        }
        return PixelImage(width: height, height: width, pixels: output)
    }

    func withMatchingInsets(_ insets: MatchingInsets) -> PixelImage {
        PixelImage(width: width, height: height, pixels: pixels, matchingInsets: insets)
    }

    fileprivate init(width: Int, height: Int, pixels: Data, matchingInsets: MatchingInsets = .none) {
        self.width = width; self.height = height; self.pixels = pixels
        self.matchingInsets = matchingInsets
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

/// A proposal only: independent moving-body registration and a seam must still validate it.
enum FrozenEdgeDetector {
    static func detect(previous: PixelImage, current: PixelImage) -> MatchingInsets {
        guard previous.width == current.width, previous.height == current.height else { return .none }
        let width = current.width, height = current.height, maximum = height / 2
        guard width > 2, maximum > 2 else { return .none }
        return previous.pixels.withUnsafeBytes { oldRaw in
            current.pixels.withUnsafeBytes { newRaw in
                let old = oldRaw.bindMemory(to: UInt8.self), new = newRaw.bindMemory(to: UInt8.self)
                let nx = min(128, width - 1)
                func stationary(_ y: Int) -> Bool {
                    var squared = 0
                    for ix in 0..<nx {
                        let p = (y * width + ix * (width - 1) / nx) * 4
                        for c in 0..<3 {
                            let difference = abs(Int(old[p + c]) - Int(new[p + c]))
                            if difference > 2 { return false }
                            squared += difference * difference
                        }
                    }
                    return squared <= nx * 3
                }
                func informative(_ rows: Range<Int>) -> Bool {
                    guard rows.count > 2 else { return false }
                    let ny = min(128, rows.count - 1)
                    var edges = 0, bands = Set<Int>()
                    for iy in 0..<ny {
                        let y = rows.lowerBound + iy * (rows.count - 1) / ny
                        for ix in 0..<nx {
                            let p = (y * width + ix * (width - 1) / nx) * 4
                            var edge = 0
                            for c in 0..<3 {
                                edge += abs(Int(new[p + c]) - Int(new[p + 4 + c])) +
                                    abs(Int(new[p + c]) - Int(new[p + width * 4 + c]))
                            }
                            if edge > 48 { edges += 1; bands.insert(iy * 4 / ny) }
                        }
                    }
                    return edges >= 24 && bands.count >= 2
                }
                var leading = 0, trailing = 0
                while leading < maximum, stationary(leading) { leading += 1 }
                while trailing < maximum, stationary(height - trailing - 1) { trailing += 1 }
                if leading == maximum, trailing == maximum, height % 2 == 0 || stationary(maximum) { return .none }
                if leading <= height / 6 + 2 || !informative(0..<leading) { leading = 0 }
                if trailing <= height / 6 + 2 || !informative((height - trailing)..<height) { trailing = 0 }
                guard leading > 0 || trailing > 0 else { return .none }
                // Too little moving body must fail closed, not fall back to matching the static header.
                guard leading < maximum, trailing < maximum,
                      height - leading - trailing >= max(96, height / 3) else {
                    return MatchingInsets(leading: height)
                }
                return MatchingInsets(leading: leading, trailing: trailing)
            }
        }
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
    private(set) var matchingInsets: MatchingInsets
    var imageHeight: Int { lowerBound - upperBound }
    var retainedPixelBytes: Int {
        strips.reduce(0) { $0 + $1.pixels.count } + (frontier?.frame.pixels.count ?? 0)
    }

    init(first: PixelImage, limits: StitchLimits, direction: StitchDirection? = nil) throws {
        self.direction = direction
        width = first.width; frameHeight = first.height
        matchingInsets = first.matchingInsets
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
        matchingInsets = matchingInsets.merged(with: frame.matchingInsets)
        position = nextPosition
        direction = nextDirection
        atLimit = imageHeight == maximumHeight
        if atLimit { sealFrontier() }
        return atLimit ? .hitLimit : added > 0 ? .grew : .stayed
    }

    private func matchingSeam(_ old: Frontier, frame: PixelImage, position: Int) -> Int? {
        let shift = position - old.position
        let validator = OverlapValidator()
        let overlap = validator.edgeAwareScore(old.frame, frame, shift: shift)
        let localized = overlap.excludedColumns != nil || overlap.excludedRows != nil
        guard overlap.isReliable,
              let rows = validator.contentRows(height: frameHeight, shift: shift,
                  insets: old.frame.matchingInsets.merged(with: frame.matchingInsets), includesEdges: true) else { return nil }
        let interior = validator.contentRows(height: frameHeight, shift: shift,
            insets: old.frame.matchingInsets.merged(with: frame.matchingInsets))
        let start = max(rows.lowerBound, old.start - position)
        let end = min(rows.upperBound, old.end - position)
        guard start < end else { return nil }
        // Leave the largest replaceable frontier; an animated caption must not be sealed a slice at a time.
        let radius = min(12, (end - start) / 4)
        let forward = (direction ?? (shift > 0 ? .down : .up)) == .down
        let ordered = forward ? Array((start + radius)..<(end - radius)) : Array(((start + radius)..<(end - radius)).reversed())
        let preferred = ordered.filter { interior?.contains($0 - radius) == true && interior?.contains($0 + radius) == true }
        let selected = Set(preferred)
        let candidates = preferred + ordered.filter { !selected.contains($0) }
        for row in candidates {
            let band = (row - radius)..<(row + radius + 1)
            guard band.lowerBound >= start, band.upperBound <= end else { continue }
            let edge = interior?.contains(band.lowerBound) != true || interior?.contains(band.upperBound - 1) != true
            let score = validator.score(old.frame, frame, shift: shift, rows: band, includesEdges: true)
            if (!(localized || edge) || score.nearLossless), score.mean <= 0.008, score.badFraction <= 0.02,
               score.laneMeans.allSatisfy({ $0 <= 0.012 }) { return position + row }
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

    /// Only the viewport position changes: relocation cannot append, erase, or reverse the document.
    mutating func relocate(to position: Int) -> Bool {
        guard position >= upperBound, position <= lowerBound - frameHeight else { return false }
        self.position = position
        return true
    }

    func recoveryViewport(at position: Int) -> PixelImage? {
        guard position >= upperBound, position <= lowerBound - frameHeight else { return nil }
        var pixels = Data(count: width * frameHeight * 4)
        pixels.withUnsafeMutableBytes { destination in
            visitRegions { source, sourceRow, origin, count in
                let start = max(position, origin), end = min(position + frameHeight, origin + count)
                guard start < end else { return }
                _ = source.withUnsafeBytes { bytes in
                    memcpy(destination.baseAddress!.advanced(by: (start - position) * width * 4),
                           bytes.baseAddress!.advanced(by: (sourceRow + start - origin) * width * 4),
                           (end - start) * width * 4)
                }
            }
        }
        return PixelImage(width: width, height: frameHeight, pixels: pixels, matchingInsets: matchingInsets)
    }

    func makeRecoveryIndex(additionalColumns: [Int] = []) -> RecoveryIndex {
        let regularCount = min(additionalColumns.isEmpty ? 32 : 16, width - 1)
        let regular = (0..<regularCount).map { $0 * (width - 1) / regularCount }
        let columns = Array(Set(regular + additionalColumns.prefix(16).filter { $0 >= 0 && $0 < width - 1 })).sorted()
        var pixels = Data(count: columns.count * imageHeight * 4)
        pixels.withUnsafeMutableBytes { destination in
            let output = destination.bindMemory(to: UInt32.self)
            visitRegions { source, sourceRow, origin, count in
                source.withUnsafeBytes { bytes in
                    let input = bytes.bindMemory(to: UInt32.self)
                    for row in 0..<count {
                        for (index, x) in columns.enumerated() {
                            output[(origin - upperBound + row) * columns.count + index] = input[(sourceRow + row) * width + x]
                        }
                    }
                }
            }
        }
        return RecoveryIndex(origin: upperBound, width: width, height: imageHeight, columns: columns, pixels: pixels)
    }

    private func visitRegions(_ body: (Data, Int, Int, Int) -> Void) {
        for strip in strips { body(strip.pixels, 0, strip.origin, strip.rows) }
        if let frontier {
            body(frontier.frame.pixels, frontier.start - frontier.position, frontier.start, frontier.end - frontier.start)
        }
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

/// Sparse columns locate a viewport without rendering or retaining a second full-resolution long image.
/// The index only proposes positions; full viewport registration and ambiguity checks authorize recovery.
struct RecoveryIndex {
    let origin: Int
    let width: Int
    let height: Int
    let columns: [Int]
    let pixels: Data
    var retainedPixelBytes: Int { pixels.count }

    func locate(_ frame: PixelImage, viewport: (Int) -> PixelImage?) -> Int? {
        guard frame.width == width, frame.height <= height, !columns.isEmpty else { return nil }
        struct Point { let column: Int; let y: Int }
        var points: [Point] = frame.pixels.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var points: [Point] = []
            let start = max(frame.height / 6, frame.matchingInsets.leading)
            let end = frame.height - max(frame.height / 6, frame.matchingInsets.trailing)
            guard end - start > 2 else { return [] }
            for y in stride(from: start, to: end - 2, by: max(1, (end - start) / 128)) {
                for (index, x) in columns.enumerated() {
                    let p = y * frame.bytesPerRow + x * 4
                    var edge = 0
                    for c in 0..<3 {
                        edge += abs(Int(bytes[p + c]) - Int(bytes[p + 4 + c]))
                        edge += abs(Int(bytes[p + c]) - Int(bytes[p + frame.bytesPerRow + c]))
                    }
                    if x + 16 < frame.width, y + 16 < end {
                        edge = max(edge, ImageTexture.curvature(bytes, at: p, step: 4) +
                                   ImageTexture.curvature(bytes, at: p, step: frame.bytesPerRow))
                    }
                    if edge > 48 { points.append(Point(column: index, y: y)) }
                }
            }
            return points.count <= 128 ? points : (0..<128).map { points[$0 * points.count / 128] }
        }
        let sparse = SparseLandmarks.samples(in: frame).compactMap { point -> Point? in
            guard let column = columns.firstIndex(of: point.x) else { return nil }
            return Point(column: column, y: point.y)
        }
        if sparse.count >= 24 { points = sparse }
        guard points.count >= 24 else { return nil }
        let candidates: [(position: Int, error: Int)] = pixels.withUnsafeBytes { referenceRaw in
            frame.pixels.withUnsafeBytes { currentRaw in
                let reference = referenceRaw.bindMemory(to: UInt8.self), current = currentRaw.bindMemory(to: UInt8.self)
                var candidates: [(Int, Int)] = []
                let maximumError = Int(0.028 * Double(points.count * 765))
                let maximumBad = Int(0.12 * Double(points.count))
                for top in 0...(height - frame.height) {
                    var total = 0, bad = 0
                    for point in points {
                        let p = ((top + point.y) * columns.count + point.column) * 4
                        let q = point.y * frame.bytesPerRow + columns[point.column] * 4
                        var worst = 0
                        for c in 0..<3 {
                            let error = abs(Int(reference[p + c]) - Int(current[q + c]))
                            total += error; worst = max(worst, error)
                        }
                        if worst > 32 { bad += 1 }
                        if total > maximumError || bad > maximumBad { break }
                    }
                    if total <= maximumError && bad <= maximumBad { candidates.append((origin + top, total)) }
                    // Too many plausible positions is ambiguity, not permission to choose the first.
                    if candidates.count > 128 { return [] }
                }
                return candidates.sorted { $0.1 < $1.1 }
            }
        }
        let estimator = VisionOffsetEstimator()
        let validator = OverlapValidator()
        var found: Int?
        for candidate in candidates {
            let verified = autoreleasepool {
                guard let expected = viewport(candidate.position),
                      validator.score(expected, frame, shift: 0).isReliable else { return false }
                return estimator.estimate(previous: expected, current: frame).shift == 0
            }
            guard verified else { continue }
            if let found, abs(found - candidate.position) > 2 { return nil }
            if found == nil { found = candidate.position }
        }
        return found
    }
}

private struct RasterEvidence {
    var count = 0
    var total = 0.0
    var bad = 0
    var maximum = 0
    var nearExact = 0
    var squared = 0.0

    mutating func record(mean: Double, worst: Int, squared: Double) {
        count += 1; total += mean; maximum = max(maximum, worst)
        if worst > 32 { bad += 1 }
        if worst <= 2 { nearExact += 1 }
        self.squared += squared
    }

    var nearLossless: Bool { count > 0 && nearExact * 100 >= count * 99 && squared <= Double(count * 9) }
}

/// A bounded proposal for a moving caption, not a general permission to ignore changed pixels.
private enum LocalizedMotion {
    static let bandCount = 12

    static func columns(_ bands: [RasterEvidence], width: Int) -> Range<Int>? {
        guard width >= 192, let excluded = excludedBands(bands) else { return nil }
        return (excluded.lowerBound * width / bandCount)..<(excluded.upperBound * width / bandCount)
    }

    static func rows(_ bands: [RasterEvidence], within range: Range<Int>) -> Range<Int>? {
        guard range.count >= 192, let excluded = excludedBands(bands),
              excluded.lowerBound == 0 || excluded.upperBound == bandCount else { return nil }
        let lower = range.lowerBound + excluded.lowerBound * range.count / bandCount
        let upper = range.lowerBound + excluded.upperBound * range.count / bandCount
        return lower..<upper
    }

    static func maximumRemovable(_ bands: [RasterEvidence]) -> Double {
        guard bands.count == bandCount else { return 0 }
        return (0...(bandCount * 2 / 3)).map { start in
            (start..<(start + bandCount / 3)).reduce(0.0) { $0 + bands[$1].total }
        }.max() ?? 0
    }

    private static func excludedBands(_ bands: [RasterEvidence]) -> Range<Int>? {
        guard bands.count == bandCount else { return nil }
        let changed = bands.indices.filter { bands[$0].count > 0 && !bands[$0].nearLossless }
        guard let first = changed.first, let last = changed.last, last - first + 1 <= bandCount / 3,
              bands.indices.filter({ $0 < first || $0 > last }).reduce(0, { $0 + bands[$1].count }) >= 24 else { return nil }
        return first..<(last + 1)
    }

}

/// A few animated UI regions may change while the document itself stays put.
/// Require ordered, textured evidence that never comes from a single static sidebar.
enum StationaryFrameMatcher {
    private static let columnCount = 12
    private static let rowCount = 8
    private static let sampleColumns = 16
    private static let sampleRows = 12

    static func matches(_ previous: PixelImage, _ current: PixelImage) -> Bool {
        guard previous.width == current.width, previous.height == current.height,
              previous.width >= 192, previous.height >= 192 else { return false }
        let width = current.width, height = current.height, rowBytes = current.bytesPerRow
        return previous.pixels.withUnsafeBytes { leftRaw in
            current.pixels.withUnsafeBytes { rightRaw in
                let left = leftRaw.bindMemory(to: UInt8.self)
                let right = rightRaw.bindMemory(to: UInt8.self)
                var stableRows = [Int](repeating: 0, count: rowCount)
                var stableColumns = [Int](repeating: 0, count: columnCount)
                var stableTextured = 0

                for row in 0..<rowCount {
                    let top = row * height / rowCount
                    let bottom = (row + 1) * height / rowCount
                    for column in 0..<columnCount {
                        let leftX = column * width / columnCount
                        let rightX = (column + 1) * width / columnCount
                        var samples = 0, nearExact = 0, edges = 0
                        for iy in 0..<sampleRows {
                            let y = top + iy * (bottom - top) / sampleRows
                            for ix in 0..<sampleColumns {
                                let x = leftX + ix * (rightX - leftX) / sampleColumns
                                let p = y * rowBytes + x * 4
                                var worst = 0
                                for channel in 0..<3 {
                                    worst = max(worst, abs(Int(left[p + channel]) - Int(right[p + channel])))
                                }
                                if worst <= 2 { nearExact += 1 }
                                samples += 1

                                let nextX = min(x + 4, width - 1)
                                let nextY = min(y + 2, height - 1)
                                let edge = (0..<3).reduce(0) { total, channel in
                                    total +
                                        abs(Int(right[p + channel]) - Int(right[y * rowBytes + nextX * 4 + channel])) +
                                        abs(Int(right[p + channel]) - Int(right[nextY * rowBytes + x * 4 + channel]))
                                }
                                if edge > 48 { edges += 1 }
                            }
                        }
                        guard samples > 0, nearExact * 100 >= samples * 99,
                              edges * 100 >= samples * 3 else { continue }
                        stableTextured += 1
                        stableRows[row] += 1
                        stableColumns[column] += 1
                    }
                }

                let rows = stableRows.filter { $0 >= 2 }.count
                let columns = stableColumns.filter { $0 >= 2 }.count
                return stableTextured * 2 >= rowCount * columnCount &&
                    rows >= 4 && columns >= 6
            }
        }
    }
}

/// Vision proposes a displacement; independent pixels, texture, and alternative offsets must validate it.
struct VisionOffsetEstimator: OffsetEstimating {
    private let maximumShiftFraction = 0.65
    private let validator = OverlapValidator()

    func estimate(previous: PixelImage, current: PixelImage) -> MoveEstimate {
        let primary = estimatePrimary(previous: previous, current: current)
        if primary.shift != nil { return primary }
        if primary.failure == .ambiguous { return primary }
        let fallback = estimateEdgeLocalized(previous: previous, current: current)
        return fallback ?? primary
    }

    private func estimatePrimary(previous: PixelImage, current: PixelImage) -> MoveEstimate {
        // Horizontal normalization swaps the accepted 96 x 64 viewport dimensions.
        guard previous.width == current.width, previous.height == current.height,
              min(previous.width, previous.height) >= 64,
              max(previous.width, previous.height) >= 96 else {
            return MoveEstimate(shift: nil, message: "选区太小或画面尺寸发生变化，请重新选择。")
        }
        do {
            let old = try previous.cgImage(), new = try current.cgImage()
            let insets = previous.matchingInsets.merged(with: current.matchingInsets)
            guard let body = validator.contentRows(height: current.height, shift: 0, insets: insets) else {
                return unreliable()
            }
            let visionRows = insets.isEmpty ? 0..<current.height : body
            let laneWidth = previous.width / 3
            var candidates: [Double] = []
            for lane in 0..<3 {
                let rect = CGRect(x: lane * laneWidth, y: visionRows.lowerBound, width: laneWidth, height: visionRows.count)
                guard let reference = old.cropping(to: rect), let target = new.cropping(to: rect) else { continue }
                let request = VNTranslationalImageRegistrationRequest(targetedCGImage: target)
                do { try VNImageRequestHandler(cgImage: reference, options: [:]).perform([request]) }
                catch { continue }
                guard let transform = request.results?.first?.alignmentTransform,
                      transform.tx.isFinite, transform.ty.isFinite, abs(transform.tx) <= 1.5 else { continue }
                candidates.append(Double(-transform.ty))
            }
            // A feature-poor or misregistered lane must not veto independently verifiable pixel evidence.
            let maximumShift = Int(Double(previous.height) * maximumShiftFraction)
            // Repeated text can give two lanes the same wrong alias. Validate every proposal on pixels.
            let possibilities = Set(candidates.flatMap { candidate -> [Int] in
                guard abs(candidate) <= Double(maximumShift) else { return [] }
                let nominal = Int(candidate.rounded())
                return (nominal - 2 ... nominal + 2).filter { abs($0) <= maximumShift }
            }).sorted()
            // Frozen table edges retain their existing matching path, not the gallery boundary path.
            let boundaries = insets.isEmpty ? boundarySamples(in: current) : []
            let regularTexture = textureSamples(in: current) + boundaries
            let sparse = regularTexture.count < 256 && insets.isEmpty ? SparseLandmarks.samples(in: current) : []
            let texture = regularTexture + sparse.map { SamplePoint(x: $0.x, y: $0.y) }
            guard texture.count >= 24 else { return unreliable() }
            let samples = texture.count <= 512 ? texture :
                (0..<512).map { texture[$0 * texture.count / 512] }
            let proposed = Set(possibilities)
            let search = possibilities + (-maximumShift...maximumShift).filter { !proposed.contains($0) }
            typealias Match = (shift: Int, mean: Double, badFraction: Double, maximumError: Int)
            var matches: [Match] = []
            var best: Match?
            // Pixel search also tests offsets Vision missed; it cannot bypass texture or ambiguity gates.
            for shift in search where validator.contentRows(height: current.height, shift: shift, insets: insets) != nil {
                let cutoff = min(0.12, max(0.028, 0.020 + (best?.mean ?? 0.05) * 2))
                let score = sampledError(previous, current, shift: shift, points: samples, cutoff: cutoff)
                let match = (shift: shift, mean: score.mean, badFraction: score.badFraction, maximumError: score.maximumError)
                matches.append(match)
                if match.mean < (best?.mean ?? .infinity) { best = match }
            }
            guard var best, best.mean <= 0.028, best.badFraction <= 0.12 else { return unreliable() }
            let ambiguityThreshold = 0.020 + best.mean * 2
            let alternatives = matches.filter { $0.mean <= ambiguityThreshold && $0.badFraction < 0.16 }
            if alternatives.contains(where: { abs($0.shift - best.shift) > 2 }) {
                // Sparse numbering can disappear from the fast sample. Re-rank aliases on a denser edge grid.
                let detailSamples = textureSamples(in: current, dense: true) + boundaries +
                    sparse.map { SamplePoint(x: $0.x, y: $0.y) }
                // Check likely offsets first, but authorize them only with rigid pixels and interior overlap.
                let reference = alternatives.sorted { a, b in
                    let aProposed = proposed.contains(a.shift), bProposed = proposed.contains(b.shift)
                    return aProposed != bProposed ? aProposed : abs(a.shift) < abs(b.shift)
                }.first { match in
                    guard match.maximumError <= 2,
                          boundarySupport(previous, current, shift: match.shift, excluded: nil, points: boundaries) else { return false }
                    let overlap = validator.score(previous, current, shift: match.shift)
                    return overlap.nearLossless && overlap.isReliable && boundarySupport(previous, current,
                        shift: match.shift, excluded: overlap.excludedColumns,
                        excludedRows: overlap.excludedRows, points: boundaries)
                }
                let referenceScore = reference.map { validator.score(previous, current, shift: $0.shift) }
                let referenceRows = reference.flatMap {
                    validator.contentRows(height: current.height, shift: $0.shift, insets: insets)
                }
                var refined: [Match] = []
                var exactShift: Int?
                for match in alternatives {
                    if let reference, let referenceRows, abs(match.shift - reference.shift) > 2,
                       let rows = validator.contentRows(height: current.height, shift: match.shift, insets: insets),
                       rows.count <= referenceRows.count,
                       !boundarySupport(previous, current, shift: match.shift,
                                        excluded: referenceScore?.excludedColumns,
                                        excludedRows: referenceScore?.excludedRows, points: boundaries) { continue }
                    let score = sampledError(previous, current, shift: match.shift, points: detailSamples, cutoff: 0.12)
                    let overlap = validator.score(previous, current, shift: match.shift)
                    guard overlap.isReliable else { continue }
                    let mean = max(score.mean, overlap.mean), bad = max(score.badFraction, overlap.badFraction)
                    if mean == 0, overlap.excludedColumns == nil, overlap.excludedRows == nil {
                        if let exactShift, abs(exactShift - match.shift) > 2 { return ambiguous() }
                        exactShift = match.shift
                    }
                    refined.append((match.shift, mean, bad, score.maximumError))
                }
                // A complete near-lossless match outranks one obtained by hiding a differing number/label.
                let complete = refined.filter { $0.maximumError <= 2 &&
                    validator.score(previous, current, shift: $0.shift).excludedColumns == nil &&
                    validator.score(previous, current, shift: $0.shift).excludedRows == nil &&
                    validator.score(previous, current, shift: $0.shift).nearLossless }
                guard let winner = (complete.isEmpty ? refined : complete).min(by: { $0.mean < $1.mean }) else { return unreliable() }
                best = winner
                // Independently quantized screen frames can differ by two levels, but RMS must stay within one.
                let quantizationLimited = best.maximumError <= 2 &&
                    validator.score(previous, current, shift: best.shift).nearLossless
                let bestRows = validator.contentRows(height: current.height, shift: best.shift, insets: insets)
                let bestOverlap = validator.score(previous, current, shift: best.shift)
                let rigidBoundary = quantizationLimited && boundarySupport(previous, current,
                    shift: best.shift, excluded: bestOverlap.excludedColumns,
                    excludedRows: bestOverlap.excludedRows, points: boundaries)
                for match in refined where abs(match.shift - best.shift) > 2 &&
                    match.mean <= 0.020 + best.mean * 2 && match.badFraction < 0.16 {
                    guard validator.score(previous, current, shift: match.shift).isReliable else { continue }
                    if rigidBoundary, let bestRows,
                       let otherRows = validator.contentRows(height: current.height, shift: match.shift, insets: insets),
                       bestRows.count >= otherRows.count,
                       !boundarySupport(previous, current, shift: match.shift,
                                        excluded: bestOverlap.excludedColumns,
                                        excludedRows: bestOverlap.excludedRows, points: boundaries) { continue }
                    if !distinguishes(previous, current, best: best.shift, alternative: match.shift,
                                      quantizationLimited: quantizationLimited, points: detailSamples) {
                        return ambiguous()
                    }
                }
            }
            guard best.mean <= 0.028, best.badFraction <= 0.12,
                  validator.score(previous, current, shift: best.shift).isReliable else { return unreliable() }
            return MoveEstimate(shift: best.shift)
        } catch { return unreliable() }
    }

    private func estimateEdgeLocalized(previous: PixelImage, current: PixelImage) -> MoveEstimate? {
        guard previous.width == current.width, previous.height == current.height,
              min(previous.width, previous.height) >= 64,
              max(previous.width, previous.height) >= 96 else { return nil }
        do {
            let old = try previous.cgImage(), new = try current.cgImage()
            let insets = previous.matchingInsets.merged(with: current.matchingInsets)
            guard let body = validator.contentRows(height: current.height, shift: 0, insets: insets) else {
                return nil
            }
            let visionRows = body
            let laneWidth = previous.width / 3
            var candidates: [Int] = []
            for lane in 0..<3 {
                let rect = CGRect(x: lane * laneWidth, y: visionRows.lowerBound,
                                  width: laneWidth, height: visionRows.count)
                guard let reference = old.cropping(to: rect), let target = new.cropping(to: rect) else { continue }
                let request = VNTranslationalImageRegistrationRequest(targetedCGImage: target)
                do { try VNImageRequestHandler(cgImage: reference, options: [:]).perform([request]) }
                catch { continue }
                guard let transform = request.results?.first?.alignmentTransform,
                      transform.tx.isFinite, transform.ty.isFinite, abs(transform.tx) <= 1.5 else { continue }
                candidates.append(Int((-transform.ty).rounded()))
            }
            let maximumShift = Int(Double(previous.height) * maximumShiftFraction)
            let shifts = Set(candidates.flatMap { candidate in
                (candidate - 2...candidate + 2).filter { abs($0) <= maximumShift }
            })
            let matches = shifts.compactMap { shift -> (shift: Int, score: OverlapValidator.Score)? in
                let score = validator.edgeAwareScore(previous, current, shift: shift)
                guard score.isReliable, score.mean <= 0.012, score.badFraction <= 0.06,
                      score.excludedRows != nil || score.excludedColumns != nil else { return nil }
                return (shift, score)
            }.sorted { $0.score.mean < $1.score.mean }
            guard let best = matches.first else { return nil }
            if matches.dropFirst().contains(where: {
                abs($0.shift - best.shift) > 2 && $0.score.mean <= best.score.mean + 0.012
            }) { return nil }
            return MoveEstimate(shift: best.shift)
        } catch {
            return nil
        }
    }

    private func unreliable() -> MoveEstimate {
        MoveEstimate(shift: nil,
                     message: "匹配不可靠，已暂停拼接。请缓慢往回滚动，回到最后确认的位置。",
                     failure: .unreliable)
    }

    private func ambiguous() -> MoveEstimate {
        MoveEstimate(shift: nil,
                     message: "画面有重复图案，无法确认位移；请往回滚动恢复或更换选区。",
                     failure: .ambiguous)
    }

    private struct SamplePoint {
        let x: Int
        let y: Int
        var span = 1
    }

    private func textureSamples(in image: PixelImage, dense: Bool = false, alternatePhase: Bool = false) -> [SamplePoint] {
        let start = max(image.height / 6, image.matchingInsets.leading)
        let end = image.height - max(image.height / 6, image.matchingInsets.trailing)
        let xStep = max(1, image.width / (dense ? 256 : 96))
        let sampledHeight = image.matchingInsets.isEmpty ? image.height : end - start
        let yStep = max(1, sampledHeight / (dense ? 256 : 128))
        let xPhase = alternatePhase && xStep > 1 ? xStep / 2 : 0
        let yPhase = alternatePhase && xStep == 1 && yStep > 1 ? yStep / 2 : 0
        if alternatePhase, xPhase == 0, yPhase == 0 { return [] }
        return image.pixels.withUnsafeBytes { raw -> [SamplePoint] in
            let bytes = raw.bindMemory(to: UInt8.self)
            var result: [SamplePoint] = []
            guard end - start > 2 else { return [] }
            for y in stride(from: start + yPhase, to: end - 2, by: yStep) {
                for x in stride(from: xPhase, to: image.width - 2, by: xStep) {
                    let p = y * image.bytesPerRow + x * 4
                    var edge = 0
                    for c in 0..<3 {
                        edge += max(abs(Int(bytes[p + c]) - Int(bytes[p + 4 + c])),
                                    abs(Int(bytes[p + c]) - Int(bytes[p + 8 + c])))
                        edge += max(abs(Int(bytes[p + c]) - Int(bytes[p + image.bytesPerRow + c])),
                                    abs(Int(bytes[p + c]) - Int(bytes[p + 2 * image.bytesPerRow + c])))
                    }
                    if x + 16 < image.width, y + 16 < end {
                        edge = max(edge, ImageTexture.curvature(bytes, at: p, step: 4) +
                                   ImageTexture.curvature(bytes, at: p, step: image.bytesPerRow))
                    }
                    if edge > 48 { result.append(SamplePoint(x: x, y: y)) }
                }
            }
            return result
        }
    }

    /// A regular grid can miss a narrow card divider entirely. Sample strong cross-axis boundaries explicitly.
    private func boundarySamples(in image: PixelImage) -> [SamplePoint] {
        guard image.width >= 192,
              let rows = validator.contentRows(height: image.height, shift: 0, insets: image.matchingInsets),
              rows.count > 32 else { return [] }
        return image.pixels.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var candidates: [(row: Int, energy: Int)] = []
            for y in stride(from: rows.lowerBound, to: rows.upperBound - 16, by: max(1, image.height / 2_048)) {
                var energy = 0
                var bands = Set<Int>()
                for column in 0..<48 {
                    let x = column * (image.width - 2) / 48, p = y * image.bytesPerRow + x * 4
                    var edge = 0
                    for channel in 0..<3 {
                        edge += abs(Int(bytes[p + channel]) - 2 * Int(bytes[p + 8 * image.bytesPerRow + channel]) +
                            Int(bytes[p + 16 * image.bytesPerRow + channel]))
                    }
                    energy += edge
                    if edge > 48 { bands.insert(x * 12 / image.width) }
                }
                if bands.count >= 6 { candidates.append((y, energy)) }
            }
            var selected: [Int] = []
            for candidate in candidates.sorted(by: { $0.energy > $1.energy }) {
                if selected.allSatisfy({ abs($0 - candidate.row) > 16 }) { selected.append(candidate.row) }
                if selected.count == 16 { break }
            }
            return selected.flatMap { y in
                (0..<48).map { SamplePoint(x: $0 * (image.width - 2) / 48, y: y, span: 16) }
            }
        }
    }

    /// Only an already near-lossless, at-least-as-large overlap may rule out a boundary-less white alias.
    /// Repeated dividers still support multiple offsets and must pass the existing ambiguity checks.
    private func boundarySupport(_ previous: PixelImage, _ current: PixelImage, shift: Int,
                                 excluded: Range<Int>?, excludedRows: Range<Int>? = nil,
                                 points: [SamplePoint]) -> Bool {
        let insets = previous.matchingInsets.merged(with: current.matchingInsets)
        guard let rows = validator.contentRows(height: current.height, shift: shift, insets: insets) else { return false }
        return previous.pixels.withUnsafeBytes { leftRaw in
            current.pixels.withUnsafeBytes { rightRaw in
                let left = leftRaw.bindMemory(to: UInt8.self), right = rightRaw.bindMemory(to: UInt8.self)
                var bands = [Int](repeating: 0, count: 12)
                for point in points where point.y >= rows.lowerBound && point.y + 16 < rows.upperBound &&
                    excluded?.contains(point.x) != true &&
                    excludedRows?.overlaps(point.y..<(point.y + 16)) != true {
                    let q = point.y * current.bytesPerRow + point.x * 4, p = q + shift * current.bytesPerRow
                    var worst = 0, edge = 0
                    for offset in [0, 1, 2, 8, 16] {
                        for channel in 0..<3 {
                            worst = max(worst, abs(Int(left[p + offset * current.bytesPerRow + channel]) -
                                Int(right[q + offset * current.bytesPerRow + channel])))
                        }
                    }
                    for channel in 0..<3 {
                        edge += abs(Int(right[q + channel]) - 2 * Int(right[q + 8 * current.bytesPerRow + channel]) +
                            Int(right[q + 16 * current.bytesPerRow + channel]))
                    }
                    if worst <= 2, edge > 48 { bands[min(11, point.x * 12 / current.width)] += 1 }
                }
                let supported = bands.indices.filter { bands[$0] >= 4 }
                guard supported.count >= 6, let first = supported.first, let last = supported.last else { return false }
                return last - first + 1 >= 8
            }
        }
    }

    /// A few differing glyphs are evidence only if they independently rule out the alias across the overlap.
    private func distinguishes(_ previous: PixelImage, _ current: PixelImage, best: Int, alternative: Int,
                               quantizationLimited: Bool, points: [SamplePoint], canRefine: Bool = true) -> Bool {
        let insets = previous.matchingInsets.merged(with: current.matchingInsets)
        guard let bestRows = validator.contentRows(height: current.height, shift: best, insets: insets),
              let otherRows = validator.contentRows(height: current.height, shift: alternative, insets: insets) else { return false }
        let changed = validator.score(previous, current, shift: best)
        let excluded = changed.excludedColumns, excludedRows = changed.excludedRows
        // A near-lossless match can rule out a shorter, contradictory fragment.
        // A smaller exact fragment cannot claim superiority over a larger, possibly changing body.
        let stableBaseline = quantizationLimited && bestRows.count >= otherRows.count
        let rigidBaseline = quantizationLimited && bestRows.count >= otherRows.count
        let start = stableBaseline ? otherRows.lowerBound : max(bestRows.lowerBound, otherRows.lowerBound)
        let end = stableBaseline ? otherRows.upperBound : min(bestRows.upperBound, otherRows.upperBound)
        guard end - start >= 24 else { return false }
        let decisive = previous.pixels.withUnsafeBytes { leftRaw in
            current.pixels.withUnsafeBytes { rightRaw in
                let left = leftRaw.bindMemory(to: UInt8.self), right = rightRaw.bindMemory(to: UInt8.self)
                let offsets = [0, 4, current.bytesPerRow]
                var wins = 0, losses = 0, bands = [Int](repeating: 0, count: 4)
                var crossBands = [Int](repeating: 0, count: 6)
                var firstWin = end, lastWin = start
                var firstCross = current.width, lastCross = 0
                for point in points where point.y >= start && point.y < end &&
                    excluded?.contains(point.x) != true && excludedRows?.contains(point.y) != true {
                    let q = point.y * current.bytesPerRow + point.x * 4
                    let p = q + best * current.bytesPerRow, a = q + alternative * current.bytesPerRow
                    var bestError = 0, otherError = 0
                    for offset in offsets {
                        for c in 0..<3 {
                            let value = Int(right[q + offset + c])
                            if bestRows.contains(point.y) {
                                bestError = max(bestError, abs(Int(left[p + offset + c]) - value))
                            }
                            otherError = max(otherError, abs(Int(left[a + offset + c]) - value))
                        }
                    }
                    if bestError <= 12, otherError >= 48 {
                        wins += 1
                        firstWin = min(firstWin, point.y); lastWin = max(lastWin, point.y)
                        bands[min(3, (point.y - start) * 4 / (end - start))] += 1
                        crossBands[min(5, point.x * 6 / current.width)] += 1
                        firstCross = min(firstCross, point.x); lastCross = max(lastCross, point.x)
                    } else if otherError <= 12, bestError >= 48 { losses += 1 }
                }
                let requiredBands = end - start >= 144 ? 3 : 2
                let distributedRows = bands.filter { $0 >= 4 }.count >= requiredBands &&
                    lastWin - firstWin >= min(24, (end - start) / 3)
                // A rigid boundary can be narrow along motion but independently visible across the viewport.
                let distributedColumns = rigidBaseline && crossBands.filter { $0 >= 4 }.count >= 4 &&
                    lastCross - firstCross >= current.width / 2
                return wins >= 24 && wins >= max(1, losses) * 8 &&
                    (distributedRows || distributedColumns)
            }
        }
        guard !decisive, canRefine else { return decisive }
        // Confirm sparse glyph evidence with a second, nonduplicating grid phase before declaring ambiguity.
        let extra = textureSamples(in: current, dense: true, alternatePhase: true)
        if !extra.isEmpty,
           distinguishes(previous, current, best: best, alternative: alternative,
                         quantizationLimited: quantizationLimited, points: points + extra, canRefine: false) { return true }
        return quantizationLimited && rasterDistinguishes(previous, current, best: best, alternative: alternative,
                                                         rows: start..<end)
    }

    /// Smooth images need distributed low-contrast evidence, not only high-contrast glyph edges.
    /// This path requires a near-lossless winner across a separate uniform grid, never a short exact patch.
    private func rasterDistinguishes(_ previous: PixelImage, _ current: PixelImage, best: Int, alternative: Int,
                                    rows: Range<Int>) -> Bool {
        let insets = previous.matchingInsets.merged(with: current.matchingInsets)
        guard let bestRows = validator.contentRows(height: current.height, shift: best, insets: insets),
              let otherRows = validator.contentRows(height: current.height, shift: alternative, insets: insets) else { return false }
        let changed = validator.score(previous, current, shift: best)
        let excluded = changed.excludedColumns, excludedRows = changed.excludedRows
        let start = max(rows.lowerBound, bestRows.lowerBound), end = min(rows.upperBound, bestRows.upperBound)
        // Unlike glyph baseline inference, raster comparisons must read real dependable pixels at both offsets.
        guard end - start >= 24 else { return false }
        let nx = min(128, current.width - 1), ny = min(128, end - start)
        guard nx >= 16, ny >= 24 else { return false }
        return previous.pixels.withUnsafeBytes { leftRaw in
            current.pixels.withUnsafeBytes { rightRaw in
                let left = leftRaw.bindMemory(to: UInt8.self), right = rightRaw.bindMemory(to: UInt8.self)
                var wins = 0, losses = 0, count = 0, nearExact = 0
                var bestSquared = 0.0, otherSquared = 0.0
                var rowBands = [Int](repeating: 0, count: 4), columnBands = [Int](repeating: 0, count: 3)
                var crossBands = [Int](repeating: 0, count: 6), firstCross = current.width, lastCross = 0
                for iy in 0..<ny {
                    let y = start + iy * (end - start) / ny
                    for ix in 0..<nx {
                        let x = ix * (current.width - 1) / nx
                        if excluded?.contains(x) == true || excludedRows?.contains(y) == true { continue }
                        let q = y * current.bytesPerRow + x * 4
                        let p = q + best * current.bytesPerRow, a = q + alternative * current.bytesPerRow
                        var bestError = 0, otherError = 0, worst = 0
                        for c in 0..<3 {
                            let value = Int(right[q + c])
                            let b = abs(Int(left[p + c]) - value), o = abs(Int(left[a + c]) - value)
                            bestError += b; otherError += o; worst = max(worst, b)
                            bestSquared += Double(b * b); otherSquared += Double(o * o)
                        }
                        count += 1
                        if worst <= 2 { nearExact += 1 }
                        if bestError <= 3, otherError >= 12, otherError >= max(1, bestError) * 4 {
                            wins += 1
                            rowBands[min(3, iy * 4 / ny)] += 1
                            columnBands[min(2, ix * 3 / nx)] += 1
                            crossBands[min(5, x * 6 / current.width)] += 1
                            firstCross = min(firstCross, x); lastCross = max(lastCross, x)
                        } else if otherError <= 3, bestError >= 12 { losses += 1 }
                    }
                }
                let distributedImage = otherSquared >= Double(count * 3 * 9) && wins >= max(96, count / 8) &&
                    rowBands.filter { $0 >= 16 }.count >= 3 && columnBands.filter { $0 >= 16 }.count >= 2
                // A card boundary spans the cross axis, even if most of its surrounding canvas is white.
                let distributedBoundary = bestRows.count >= otherRows.count && wins >= 96 &&
                    otherSquared >= Double(wins * 3 * 9) && crossBands.filter { $0 >= 8 }.count >= 4 &&
                    lastCross - firstCross >= current.width * 2 / 3
                return nearExact * 100 >= count * 99 && bestSquared <= Double(count * 3) &&
                    otherSquared >= bestSquared * 16 && wins >= max(1, losses) * 8 &&
                    (distributedImage || distributedBoundary)
            }
        }
    }

    /// Test alternative offsets on ink/edges, not mostly-white document margins.
    private func sampledError(_ previous: PixelImage, _ current: PixelImage, shift: Int,
                              points: [SamplePoint], cutoff: Double) -> (mean: Double, badFraction: Double, maximumError: Int) {
        let insets = previous.matchingInsets.merged(with: current.matchingInsets)
        guard let rows = validator.contentRows(height: current.height, shift: shift, insets: insets) else { return (1, 1, 255) }
        // Evidence must be relative to the shared body, not to samples outside this displacement's overlap.
        let sampleCount = points.reduce(0) {
            $0 + (rows.contains($1.y) && ($1.span == 1 || $1.y + $1.span < rows.upperBound) ? 1 : 0)
        }
        guard sampleCount >= 24 else { return (1, 1, 255) }
        return previous.pixels.withUnsafeBytes { leftRaw in
            current.pixels.withUnsafeBytes { rightRaw in
                let left = leftRaw.bindMemory(to: UInt8.self), right = rightRaw.bindMemory(to: UInt8.self)
                var bands = [RasterEvidence](repeating: RasterEvidence(), count: LocalizedMotion.bandCount)
                var visited = 0, totalError = 0.0
                for point in points where rows.contains(point.y) && (point.span == 1 || point.y + point.span < rows.upperBound) {
                    let patchOffsets = point.span == 1 ? [0, 4, current.bytesPerRow] :
                        [0, 4, current.bytesPerRow, 8 * current.bytesPerRow, 16 * current.bytesPerRow]
                    let py = point.y + shift
                    let p = py * previous.bytesPerRow + point.x * 4
                    let q = point.y * current.bytesPerRow + point.x * 4
                    var worst = 0, total = 0, squared = 0.0
                    for offset in patchOffsets {
                        for c in 0..<3 {
                            let delta = abs(Int(left[p + offset + c]) - Int(right[q + offset + c]))
                            total += delta; worst = max(worst, delta)
                            squared += Double(delta * delta)
                        }
                    }
                    let band = min(LocalizedMotion.bandCount - 1, point.x * LocalizedMotion.bandCount / current.width)
                    let error = Double(total) / Double(765 * patchOffsets.count)
                    bands[band].record(mean: error, worst: worst, squared: squared)
                    visited += 1; totalError += error
                    if visited % 16 == 0, totalError > cutoff * Double(sampleCount) {
                        // Even removing the worst allowed contiguous caption cannot rescue this offset.
                        let removable = LocalizedMotion.maximumRemovable(bands)
                        if totalError - removable > cutoff * Double(sampleCount) { return (1, 1, 255) }
                    }
                }
                // Sparse evidence may propose a localized exclusion; the independent raster grid must prove it.
                let excluded = LocalizedMotion.columns(bands, width: current.width)
                let kept = bands.indices.filter { excluded?.contains($0 * current.width / LocalizedMotion.bandCount) != true }
                let count = kept.reduce(0) { $0 + bands[$1].count }
                guard count >= 24 else { return (1, 1, 255) }
                return (kept.reduce(0.0) { $0 + bands[$1].total } / Double(count),
                        Double(kept.reduce(0) { $0 + bands[$1].bad }) / Double(count),
                        kept.map { bands[$0].maximum }.max() ?? 255)
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
        let nearLossless: Bool
        var excludedColumns: Range<Int>? = nil
        var excludedRows: Range<Int>? = nil
        var isReliable: Bool {
            textured && mean <= 0.028 && badFraction <= 0.12 && laneMeans.allSatisfy { $0 <= 0.045 }
        }
        static let invalid = Score(mean: 1, badFraction: 1, laneMeans: [1, 1, 1], textured: false, nearLossless: false)
    }

    func contentRows(height: Int, shift: Int, insets: MatchingInsets = .none, includesEdges: Bool = false) -> Range<Int>? {
        guard shift > -height, shift < height else { return nil }
        let margin = includesEdges ? 1 : height / 6
        let top = max(margin, insets.leading), bottom = height - max(margin, insets.trailing)
        let start = max(top, top - shift), end = min(bottom, bottom - shift)
        let minimum = max(max(8, min(24, height / 16)), insets.isEmpty ? 0 : (bottom - top) / 5)
        // A frozen band must not turn a tiny repeated fragment into evidence for a large jump.
        guard end - start >= minimum else { return nil }
        return start..<end
    }

    func score(_ previous: PixelImage, _ current: PixelImage, shift: Int,
               rows requestedRows: Range<Int>? = nil, includesEdges: Bool = false) -> Score {
        guard previous.width == current.width, previous.height == current.height,
              current.width > 1, let content = contentRows(height: current.height, shift: shift,
                  insets: previous.matchingInsets.merged(with: current.matchingInsets), includesEdges: includesEdges) else { return .invalid }
        let rows = requestedRows ?? content
        guard !rows.isEmpty, rows.lowerBound >= content.lowerBound, rows.upperBound <= content.upperBound else {
            return .invalid
        }
        return previous.pixels.withUnsafeBytes { leftRaw in
            current.pixels.withUnsafeBytes { rightRaw in
                let left = leftRaw.bindMemory(to: UInt8.self), right = rightRaw.bindMemory(to: UInt8.self)
                let rowBytes = current.bytesPerRow
                let patchOffsets = [0, 4, rowBytes]
                var totals = [Double](repeating: 0, count: 3), counts = [Int](repeating: 0, count: 3)
                var bands = [RasterEvidence](repeating: RasterEvidence(), count: LocalizedMotion.bandCount)
                var bad = 0, edges = 0, verticalEdges = 0, count = 0, nearExact = 0, squared = 0.0
                let nx = min(128, current.width - 1), ny = min(96, rows.count)
                for iy in 0..<ny {
                    let y = rows.lowerBound + iy * rows.count / ny
                    for ix in 0..<nx {
                        let x = ix * (current.width - 1) / nx
                        let p = (y + shift) * rowBytes + x * 4, q = y * rowBytes + x * 4
                        let neighborX = y * rowBytes + min(x + 2, current.width - 1) * 4
                        let neighborY = min(y + 2, rows.upperBound - 1) * rowBytes + x * 4
                        var difference = 0, worst = 0, horizontal = 0, vertical = 0, pointSquared = 0.0
                        for c in 0..<3 {
                            let value = Int(right[q + c])
                            var channelDifference = 0
                            for offset in patchOffsets {
                                let delta = abs(Int(left[p + offset + c]) - Int(right[q + offset + c]))
                                channelDifference = max(channelDifference, delta)
                                squared += Double(delta * delta)
                                pointSquared += Double(delta * delta)
                            }
                            difference += channelDifference; worst = max(worst, channelDifference)
                            // Adjacent pairs can hide all edges from a regularly spaced sampling grid.
                            horizontal += max(abs(Int(right[q + 4 + c]) - value),
                                              abs(Int(right[neighborX + c]) - value))
                            vertical += max(abs(Int(right[q + rowBytes + c]) - value),
                                            abs(Int(right[neighborY + c]) - value))
                        }
                        let lane = min(2, x * 3 / current.width)
                        let band = min(LocalizedMotion.bandCount - 1, x * LocalizedMotion.bandCount / current.width)
                        bands[band].record(mean: Double(difference) / 765, worst: worst, squared: pointSquared)
                        totals[lane] += Double(difference) / 765
                        counts[lane] += 1; count += 1
                        if worst > 32 { bad += 1 }
                        if worst <= 2 { nearExact += 1 }
                        if horizontal + vertical > 48 { edges += 1 }
                        if vertical > 24 { verticalEdges += 1 }
                    }
                }
                let mean = totals.reduce(0, +) / Double(max(1, count))
                let laneMeans = (0..<3).map { totals[$0] / Double(max(1, counts[$0])) }
                var original = Score(mean: mean, badFraction: Double(bad) / Double(max(1, count)),
                             laneMeans: laneMeans,
                             textured: (Double(edges) / Double(max(1, count)) >= 0.012 &&
                                Double(verticalEdges) / Double(max(1, count)) >= 0.004) ||
                                ImageTexture.hasMultiscaleSupport(current, rows: rows),
                             nearLossless: nearExact * 100 >= count * 99 && squared <= Double(count * 3 * patchOffsets.count))
                if requestedRows == nil, !original.textured, original.nearLossless,
                   previous.matchingInsets.isEmpty, current.matchingInsets.isEmpty,
                   SparseLandmarks.matches(previous, current, shift: shift, rows: rows) {
                    original = Score(mean: mean, badFraction: original.badFraction, laneMeans: laneMeans,
                                     textured: true, nearLossless: true)
                }
                // A seam always checks every pixel band. Only registration can exclude localized motion.
                guard requestedRows == nil,
                      let excluded = LocalizedMotion.columns(bands, width: current.width) else { return original }
                let kept = bands.indices.filter { !excluded.contains($0 * current.width / LocalizedMotion.bandCount) }
                let supported = kept.filter { band in
                    ImageTexture.hasMultiscaleSupport(current, rows: rows,
                        columns: (band * current.width / LocalizedMotion.bandCount)..<((band + 1) * current.width / LocalizedMotion.bandCount))
                }
                guard supported.count >= 6, let first = supported.first, let last = supported.last,
                      (last - first + 1) * 3 >= LocalizedMotion.bandCount * 2 else { return original }
                let staticCount = kept.reduce(0) { $0 + bands[$1].count }
                let staticLaneMeans = (0..<3).map { lane -> Double in
                    let indices = kept.filter { $0 / 4 == lane }
                    return indices.reduce(0.0) { $0 + bands[$1].total } /
                        Double(max(1, indices.reduce(0) { $0 + bands[$1].count }))
                }
                return Score(mean: kept.reduce(0.0) { $0 + bands[$1].total } / Double(staticCount),
                             badFraction: Double(kept.reduce(0) { $0 + bands[$1].bad }) / Double(staticCount),
                             laneMeans: staticLaneMeans, textured: true, nearLossless: true, excludedColumns: excluded)
            }
        }
    }

    /// A lazy-loaded strip at either end of the motion overlap may change after scrolling starts.
    /// The unchanged body must still prove one near-lossless displacement across every column lane.
    func edgeAwareScore(_ previous: PixelImage, _ current: PixelImage, shift: Int) -> Score {
        let base = score(previous, current, shift: shift)
        guard !base.isReliable else { return base }
        let insets = previous.matchingInsets.merged(with: current.matchingInsets)
        guard previous.width == current.width, previous.height == current.height,
              let rows = contentRows(height: current.height, shift: shift, insets: insets),
              rows.count >= 192 else { return base }
        return previous.pixels.withUnsafeBytes { leftRaw in
            current.pixels.withUnsafeBytes { rightRaw in
                let left = leftRaw.bindMemory(to: UInt8.self), right = rightRaw.bindMemory(to: UInt8.self)
                let rowBytes = current.bytesPerRow
                let patchOffsets = [0, 4, rowBytes]
                var rowBands = [RasterEvidence](repeating: RasterEvidence(), count: LocalizedMotion.bandCount)
                var rowLanes = Array(repeating: Array(repeating: RasterEvidence(),
                                                      count: 3), count: LocalizedMotion.bandCount)
                let nx = min(128, current.width - 1), ny = min(96, rows.count)
                for iy in 0..<ny {
                    let y = rows.lowerBound + iy * rows.count / ny
                    for ix in 0..<nx {
                        let x = ix * (current.width - 1) / nx
                        let p = (y + shift) * rowBytes + x * 4, q = y * rowBytes + x * 4
                        var difference = 0, worst = 0, squared = 0.0
                        for c in 0..<3 {
                            var channelDifference = 0
                            for offset in patchOffsets {
                                let delta = abs(Int(left[p + offset + c]) - Int(right[q + offset + c]))
                                channelDifference = max(channelDifference, delta)
                                squared += Double(delta * delta)
                            }
                            difference += channelDifference
                            worst = max(worst, channelDifference)
                        }
                        let lane = min(2, x * 3 / current.width)
                        let band = min(LocalizedMotion.bandCount - 1,
                                       (y - rows.lowerBound) * LocalizedMotion.bandCount / rows.count)
                        let mean = Double(difference) / 765
                        rowBands[band].record(mean: mean, worst: worst, squared: squared)
                        rowLanes[band][lane].record(mean: mean, worst: worst, squared: squared)
                    }
                }
                guard let excludedRows = LocalizedMotion.rows(rowBands, within: rows) else { return base }
                let keptRows = rowBands.indices.filter { index in
                    let lower = rows.lowerBound + index * rows.count / LocalizedMotion.bandCount
                    let upper = rows.lowerBound + (index + 1) * rows.count / LocalizedMotion.bandCount
                    return upper <= excludedRows.lowerBound || lower >= excludedRows.upperBound
                }
                let ranges = [
                    rows.lowerBound..<excludedRows.lowerBound,
                    excludedRows.upperBound..<rows.upperBound
                ].filter { $0.count >= 24 }
                let supportedRows = ranges.reduce(0) { $0 + $1.count }
                let textured = supportedRows * 3 >= rows.count * 2 && ranges.contains {
                    $0.count >= rows.count / 2 && ImageTexture.hasMultiscaleSupport(current, rows: $0)
                }
                var staticCount = 0, staticBad = 0, staticNear = 0, staticSquared = 0.0
                var laneTotals = [Double](repeating: 0, count: 3)
                var laneCounts = [Int](repeating: 0, count: 3)
                for row in keptRows {
                    for lane in 0..<3 {
                        let evidence = rowLanes[row][lane]
                        staticCount += evidence.count
                        staticBad += evidence.bad
                        staticNear += evidence.nearExact
                        staticSquared += evidence.squared
                        laneTotals[lane] += evidence.total
                        laneCounts[lane] += evidence.count
                    }
                }
                let minimumLaneCount = max(8, staticCount / 8)
                guard staticCount >= 24, laneCounts.allSatisfy({ $0 >= minimumLaneCount }) else { return base }
                let localized = Score(
                    mean: laneTotals.reduce(0, +) / Double(staticCount),
                    badFraction: Double(staticBad) / Double(staticCount),
                    laneMeans: (0..<3).map { laneTotals[$0] / Double(laneCounts[$0]) },
                    textured: textured,
                    nearLossless: staticNear * 100 >= staticCount * 99 &&
                        staticSquared <= Double(staticCount * 3 * patchOffsets.count),
                    excludedRows: excludedRows)
                return localized.isReliable && localized.mean < base.mean ? localized : base
            }
        }
    }
}

/// Sparse marks need several independently matching patches, not a lower global texture threshold.
enum SparseLandmarks {
    struct Point { let x: Int; let y: Int }

    static func samples(in image: PixelImage) -> [Point] {
        guard image.matchingInsets.isEmpty,
              let rows = OverlapValidator().contentRows(height: image.height, shift: 0),
              !ImageTexture.hasMultiscaleSupport(image, rows: rows) else { return [] }
        let anchors = anchors(in: image, rows: rows)
        guard distributed(anchors, width: image.width, rows: rows) else { return [] }
        return anchors.flatMap { point in
            [point, Point(x: point.x + 1, y: point.y), Point(x: point.x, y: point.y + 1),
             Point(x: point.x + 1, y: point.y + 1)]
        }
    }

    static func recoveryColumns(in image: PixelImage) -> [Int] {
        let columns = Array(Set(samples(in: image).map(\.x))).sorted()
        return columns.count <= 16 ? columns : (0..<16).map { columns[$0 * columns.count / 16] }
    }

    static func matches(_ previous: PixelImage, _ current: PixelImage, shift: Int, rows: Range<Int>) -> Bool {
        let candidates = anchors(in: current, rows: rows)
        guard distributed(candidates, width: current.width, rows: rows) else { return false }
        return previous.pixels.withUnsafeBytes { leftRaw in
            current.pixels.withUnsafeBytes { rightRaw in
                let left = leftRaw.bindMemory(to: UInt8.self), right = rightRaw.bindMemory(to: UInt8.self)
                var matched: [Point] = []
                for point in candidates {
                    var maximum = 0, squared = 0
                    for dy in -2...2 {
                        for dx in -2...2 {
                            let q = (point.y + dy) * current.bytesPerRow + (point.x + dx) * 4
                            let p = q + shift * current.bytesPerRow
                            for channel in 0..<3 {
                                let difference = abs(Int(left[p + channel]) - Int(right[q + channel]))
                                maximum = max(maximum, difference); squared += difference * difference
                            }
                        }
                    }
                    // Every detected patch must agree: a moving label cannot hide in the white average.
                    guard maximum <= 2, squared <= 75 else { return false }
                    matched.append(point)
                }
                return distributed(matched, width: current.width, rows: rows)
            }
        }
    }

    private static func distributed(_ points: [Point], width: Int, rows: Range<Int>) -> Bool {
        guard points.count >= 6, rows.count >= 24 else { return false }
        var rowBands = [Int](repeating: 0, count: 3), columnBands = [Int](repeating: 0, count: 3)
        for point in points {
            rowBands[min(2, (point.y - rows.lowerBound) * 3 / rows.count)] += 1
            columnBands[min(2, point.x * 3 / width)] += 1
        }
        guard rowBands.filter({ $0 >= 2 }).count >= 2, columnBands.allSatisfy({ $0 >= 2 }),
              let firstY = points.map(\.y).min(), let lastY = points.map(\.y).max(),
              let firstX = points.map(\.x).min(), let lastX = points.map(\.x).max() else { return false }
        return lastY - firstY >= max(24, rows.count / 3) && lastX - firstX >= width / 2
    }

    private static func anchors(in image: PixelImage, rows: Range<Int>) -> [Point] {
        guard image.width >= 64, rows.count >= 24 else { return [] }
        return image.pixels.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var cells: [Int: (point: Point, energy: Int)] = [:]
            for y in stride(from: rows.lowerBound + 2, to: rows.upperBound - 3, by: max(1, image.height / 768)) {
                for x in stride(from: 2, to: image.width - 3, by: max(1, image.width / 512)) {
                    let p = y * image.bytesPerRow + x * 4
                    var horizontal = 0, vertical = 0
                    for c in 0..<3 {
                        horizontal += abs(Int(bytes[p - 8 + c]) - 2 * Int(bytes[p + c]) + Int(bytes[p + 8 + c]))
                        vertical += abs(Int(bytes[p - 2 * image.bytesPerRow + c]) - 2 * Int(bytes[p + c]) +
                            Int(bytes[p + 2 * image.bytesPerRow + c]))
                    }
                    guard vertical > 48, horizontal + vertical > 96 else { continue }
                    let cell = (y - rows.lowerBound) * 12 / rows.count * 12 + x * 12 / image.width
                    let energy = horizontal + vertical
                    if energy > (cells[cell]?.energy ?? 0) { cells[cell] = (Point(x: x, y: y), energy) }
                }
            }
            // Keep the support evenly distributed rather than taking only the darkest single label.
            let points = cells.sorted { $0.key < $1.key }.map { $0.value.point }
            return points.count <= 32 ? points : (0..<32).map { points[$0 * points.count / 32] }
        }
    }
}

/// Coarser curvature detects real image structure without calling a flat/linear gradient textured.
private enum ImageTexture {
    static func curvature(_ bytes: UnsafeBufferPointer<UInt8>, at p: Int, step: Int) -> Int {
        (0..<3).reduce(0) { $0 + abs(Int(bytes[p + $1]) - 2 * Int(bytes[p + 8 * step + $1]) +
                                    Int(bytes[p + 16 * step + $1])) }
    }

    static func hasMultiscaleSupport(_ image: PixelImage, rows: Range<Int>, columns: Range<Int>? = nil) -> Bool {
        let columns = columns ?? 0..<image.width
        let nx = min(96, columns.count - 16), ny = min(96, rows.count - 16)
        guard nx > 0, ny > 0 else { return false }
        return image.pixels.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var edges = 0, verticalEdges = 0
            for iy in 0..<ny {
                let y = rows.lowerBound + iy * (rows.count - 16) / ny
                for ix in 0..<nx {
                    let x = columns.lowerBound + ix * (columns.count - 16) / nx, p = y * image.bytesPerRow + x * 4
                    let horizontal = curvature(bytes, at: p, step: 4)
                    let vertical = curvature(bytes, at: p, step: image.bytesPerRow)
                    if horizontal + vertical > 48 { edges += 1 }
                    if vertical > 24 { verticalEdges += 1 }
                }
            }
            return Double(edges) / Double(nx * ny) >= 0.012 && Double(verticalEdges) / Double(nx * ny) >= 0.004
        }
    }
}
