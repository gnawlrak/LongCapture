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
        guard validator.score(old.frame, frame, shift: shift).isReliable,
              let rows = validator.contentRows(height: frameHeight, shift: shift,
                  insets: old.frame.matchingInsets.merged(with: frame.matchingInsets)) else { return nil }
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

    func makeRecoveryIndex() -> RecoveryIndex {
        let columns = (0..<min(32, width - 1)).map { $0 * (width - 1) / min(32, width - 1) }
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
        let points: [Point] = frame.pixels.withUnsafeBytes { raw in
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

/// Vision proposes a displacement; independent pixels, texture, and alternative offsets must validate it.
struct VisionOffsetEstimator: OffsetEstimating {
    private let maximumShiftFraction = 0.65
    private let validator = OverlapValidator()

    func estimate(previous: PixelImage, current: PixelImage) -> MoveEstimate {
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
            let texture = textureSamples(in: current)
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
                let detailSamples = textureSamples(in: current, dense: true)
                var refined: [Match] = []
                var exactShift: Int?
                for match in alternatives {
                    let score = sampledError(previous, current, shift: match.shift, points: detailSamples, cutoff: 0.12)
                    let overlap = validator.score(previous, current, shift: match.shift)
                    guard overlap.isReliable else { continue }
                    let mean = max(score.mean, overlap.mean), bad = max(score.badFraction, overlap.badFraction)
                    if mean == 0 {
                        if let exactShift, abs(exactShift - match.shift) > 2 { return ambiguous() }
                        exactShift = match.shift
                    }
                    refined.append((match.shift, mean, bad, score.maximumError))
                }
                guard let winner = refined.min(by: { $0.mean < $1.mean }) else { return unreliable() }
                best = winner
                // Independently quantized screen frames can differ by two levels, but RMS must stay within one.
                let quantizationLimited = best.maximumError <= 2 &&
                    validator.score(previous, current, shift: best.shift).nearLossless
                for match in refined where abs(match.shift - best.shift) > 2 &&
                    match.mean <= 0.020 + best.mean * 2 && match.badFraction < 0.16 {
                    guard validator.score(previous, current, shift: match.shift).isReliable else { continue }
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

    private func unreliable() -> MoveEstimate {
        MoveEstimate(shift: nil, message: "匹配不可靠，已暂停拼接。请缓慢往回滚动，回到最后确认的位置。")
    }

    private func ambiguous() -> MoveEstimate {
        MoveEstimate(shift: nil, message: "画面有重复图案，无法确认位移；请往回滚动恢复或更换选区。")
    }

    private struct SamplePoint { let x: Int; let y: Int }

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

    /// A few differing glyphs are evidence only if they independently rule out the alias across the overlap.
    private func distinguishes(_ previous: PixelImage, _ current: PixelImage, best: Int, alternative: Int,
                               quantizationLimited: Bool, points: [SamplePoint], canRefine: Bool = true) -> Bool {
        let insets = previous.matchingInsets.merged(with: current.matchingInsets)
        guard let bestRows = validator.contentRows(height: current.height, shift: best, insets: insets),
              let otherRows = validator.contentRows(height: current.height, shift: alternative, insets: insets) else { return false }
        // A near-lossless match can rule out a shorter, contradictory fragment.
        // A smaller exact fragment cannot claim superiority over a larger, possibly changing body.
        let stableBaseline = quantizationLimited && bestRows.count >= otherRows.count
        let frozenBodyBaseline = !insets.isEmpty && quantizationLimited && bestRows.count >= otherRows.count * 2 &&
            validator.score(previous, current, shift: best).nearLossless
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
                for point in points where point.y >= start && point.y < end {
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
                // Table column labels can occupy a narrow glyph strip but repeat independently across many rows.
                let distributedColumns = frozenBodyBaseline && crossBands.filter { $0 >= 4 }.count >= 4 &&
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
        guard let bestRows = validator.contentRows(height: current.height, shift: best, insets: insets) else { return false }
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
                for iy in 0..<ny {
                    let y = start + iy * (end - start) / ny
                    for ix in 0..<nx {
                        let x = ix * (current.width - 1) / nx
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
                        } else if otherError <= 3, bestError >= 12 { losses += 1 }
                    }
                }
                return nearExact * 100 >= count * 99 && bestSquared <= Double(count * 3) &&
                    otherSquared >= max(Double(count * 3 * 9), bestSquared * 16) &&
                    wins >= max(96, count / 8) && wins >= max(1, losses) * 8 &&
                    rowBands.filter { $0 >= 16 }.count >= 3 && columnBands.filter { $0 >= 16 }.count >= 2
            }
        }
    }

    /// Test alternative offsets on ink/edges, not mostly-white document margins.
    private func sampledError(_ previous: PixelImage, _ current: PixelImage, shift: Int,
                              points: [SamplePoint], cutoff: Double) -> (mean: Double, badFraction: Double, maximumError: Int) {
        let insets = previous.matchingInsets.merged(with: current.matchingInsets)
        guard let rows = validator.contentRows(height: current.height, shift: shift, insets: insets) else { return (1, 1, 255) }
        // Evidence must be relative to the shared body, not to samples outside this displacement's overlap.
        let sampleCount = points.reduce(0) { $0 + (rows.contains($1.y) ? 1 : 0) }
        guard sampleCount >= 24 else { return (1, 1, 255) }
        return previous.pixels.withUnsafeBytes { leftRaw in
            current.pixels.withUnsafeBytes { rightRaw in
                let left = leftRaw.bindMemory(to: UInt8.self), right = rightRaw.bindMemory(to: UInt8.self)
                var count = 0, bad = 0, total = 0, maximum = 0
                let patchOffsets = [0, 4, current.bytesPerRow]
                let maximumError = cutoff * Double(sampleCount * 765 * patchOffsets.count)
                for point in points where rows.contains(point.y) {
                    let py = point.y + shift
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
                    maximum = max(maximum, worst)
                    if Double(total) > maximumError { return (1, 1, 255) }
                }
                return (Double(total) / Double(count * 765 * patchOffsets.count), Double(bad) / Double(count), maximum)
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
        var isReliable: Bool {
            textured && mean <= 0.028 && badFraction <= 0.12 && laneMeans.allSatisfy { $0 <= 0.045 }
        }
        static let invalid = Score(mean: 1, badFraction: 1, laneMeans: [1, 1, 1], textured: false, nearLossless: false)
    }

    func contentRows(height: Int, shift: Int, insets: MatchingInsets = .none) -> Range<Int>? {
        guard shift > -height, shift < height else { return nil }
        let top = max(height / 6, insets.leading), bottom = height - max(height / 6, insets.trailing)
        let start = max(top, top - shift), end = min(bottom, bottom - shift)
        let minimum = max(max(8, min(24, height / 16)), insets.isEmpty ? 0 : (bottom - top) / 5)
        // A frozen band must not turn a tiny repeated fragment into evidence for a large jump.
        guard end - start >= minimum else { return nil }
        return start..<end
    }

    func score(_ previous: PixelImage, _ current: PixelImage, shift: Int,
               rows requestedRows: Range<Int>? = nil) -> Score {
        guard previous.width == current.width, previous.height == current.height,
              current.width > 1, let content = contentRows(height: current.height, shift: shift,
                  insets: previous.matchingInsets.merged(with: current.matchingInsets)) else { return .invalid }
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
                var bad = 0, edges = 0, verticalEdges = 0, count = 0, nearExact = 0, squared = 0.0
                let nx = min(128, current.width - 1), ny = min(96, rows.count)
                for iy in 0..<ny {
                    let y = rows.lowerBound + iy * rows.count / ny
                    for ix in 0..<nx {
                        let x = ix * (current.width - 1) / nx
                        let p = (y + shift) * rowBytes + x * 4, q = y * rowBytes + x * 4
                        let neighborX = y * rowBytes + min(x + 2, current.width - 1) * 4
                        let neighborY = min(y + 2, current.height - 1) * rowBytes + x * 4
                        var difference = 0, worst = 0, horizontal = 0, vertical = 0
                        for c in 0..<3 {
                            let value = Int(right[q + c])
                            var channelDifference = 0
                            for offset in patchOffsets {
                                let delta = abs(Int(left[p + offset + c]) - Int(right[q + offset + c]))
                                channelDifference = max(channelDifference, delta)
                                squared += Double(delta * delta)
                            }
                            difference += channelDifference; worst = max(worst, channelDifference)
                            // Adjacent pairs can hide all edges from a regularly spaced sampling grid.
                            horizontal += max(abs(Int(right[q + 4 + c]) - value),
                                              abs(Int(right[neighborX + c]) - value))
                            vertical += max(abs(Int(right[q + rowBytes + c]) - value),
                                            abs(Int(right[neighborY + c]) - value))
                        }
                        let lane = min(2, x * 3 / current.width)
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
                return Score(mean: mean, badFraction: Double(bad) / Double(max(1, count)),
                             laneMeans: laneMeans,
                             textured: (Double(edges) / Double(max(1, count)) >= 0.012 &&
                                Double(verticalEdges) / Double(max(1, count)) >= 0.004) ||
                                ImageTexture.hasMultiscaleSupport(current, rows: rows),
                             nearLossless: nearExact * 100 >= count * 99 && squared <= Double(count * 3 * patchOffsets.count))
            }
        }
    }
}

/// Coarser curvature detects real image structure without calling a flat/linear gradient textured.
private enum ImageTexture {
    static func curvature(_ bytes: UnsafeBufferPointer<UInt8>, at p: Int, step: Int) -> Int {
        (0..<3).reduce(0) { $0 + abs(Int(bytes[p + $1]) - 2 * Int(bytes[p + 8 * step + $1]) +
                                    Int(bytes[p + 16 * step + $1])) }
    }

    static func hasMultiscaleSupport(_ image: PixelImage, rows: Range<Int>) -> Bool {
        let nx = min(96, image.width - 16), ny = min(96, rows.count - 16)
        guard nx > 0, ny > 0 else { return false }
        return image.pixels.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var edges = 0, verticalEdges = 0
            for iy in 0..<ny {
                let y = rows.lowerBound + iy * (rows.count - 16) / ny
                for ix in 0..<nx {
                    let x = ix * (image.width - 16) / nx, p = y * image.bytesPerRow + x * 4
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
