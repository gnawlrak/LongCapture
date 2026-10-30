import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import LongCapture

struct TestCanvas {
    let width: Int
    let height: Int
    let pixels: Data

    init(width: Int = 240, height: Int = 1_200, repeatedPeriod: Int? = nil) {
        self.width = width
        self.height = height
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let row = repeatedPeriod.map { y % $0 } ?? y
                let seed = UInt32(truncatingIfNeeded: (x / 2) &* 374_761_393 &+ (row / 2) &* 668_265_263)
                let hash = (seed ^ (seed >> 13)) &* 1_274_126_177
                let p = (y * width + x) * 4
                bytes[p] = UInt8(truncatingIfNeeded: hash)
                bytes[p + 1] = UInt8(truncatingIfNeeded: hash >> 8)
                bytes[p + 2] = UInt8(truncatingIfNeeded: hash >> 16)
            }
        }
        // Small decimal row labels make a visually inspectable numbered canvas, not only noise.
        if repeatedPeriod == nil {
            let glyphs = ["111101101101111", "010110010010111", "111001111100111", "111001111001111",
                          "101101111001001", "111100111001111", "111100111101111", "111001001001001",
                          "111101111101111", "111101111001111"]
            for row in stride(from: 0, to: height - 12, by: 24) {
                for (digitIndex, character) in String(row).enumerated() {
                    let bits = Array(glyphs[character.wholeNumberValue!])
                    for gy in 0..<5 {
                        for gx in 0..<3 where bits[gy * 3 + gx] == "1" {
                            for dy in 0..<2 {
                                for dx in 0..<2 {
                                    let x = 8 + digitIndex * 8 + gx * 2 + dx
                                    let y = row + gy * 2 + dy
                                    guard x < width else { continue }
                                    let p = (y * width + x) * 4
                                    bytes[p] = 0; bytes[p + 1] = 0; bytes[p + 2] = 0
                                }
                            }
                        }
                    }
                }
            }
        }
        pixels = Data(bytes)
    }

    func frame(at y: Int, height frameHeight: Int) -> CGImage {
        precondition(y >= 0 && y + frameHeight <= height)
        return Self.image(width: width, height: frameHeight,
                          pixels: pixels.subdata(in: (y * width * 4)..<((y + frameHeight) * width * 4)))
    }

    /// Synthetic fractional raster motion, including small changes that round to zero pixels.
    func interpolatedFrame(at position: Double, height frameHeight: Int) -> CGImage {
        let row = Int(position.rounded(.down)), fraction = position - Double(row)
        if fraction == 0 { return frame(at: row, height: frameHeight) }
        precondition(row >= 0 && row + frameHeight < height)
        let rowBytes = width * 4, byteCount = rowBytes * frameHeight
        var output = Data(count: byteCount)
        pixels.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                let input = source.bindMemory(to: UInt8.self), result = destination.bindMemory(to: UInt8.self)
                for p in 0..<byteCount {
                    let start = row * rowBytes + p
                    result[p] = UInt8((Double(input[start]) * (1 - fraction) +
                                      Double(input[start + rowBytes]) * fraction).rounded())
                }
            }
        }
        return Self.image(width: width, height: frameHeight, pixels: output)
    }

    static func image(width: Int, height: Int, pixels: Data) -> CGImage {
        CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue),
                provider: CGDataProvider(data: pixels as CFData)!, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func blank(width: Int = 240, height: Int = 240, value: UInt8 = 255) -> CGImage {
        var data = [UInt8](repeating: value, count: width * height * 4)
        for p in stride(from: 3, to: data.count, by: 4) { data[p] = 255 }
        return image(width: width, height: height, pixels: Data(data))
    }
}

struct TextTestCanvas {
    let image: CGImage
    init(width: Int = 640, height: Int = 1_600, lineText: ((Int) -> String)? = nil) {
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                        CGBitmapInfo.byteOrder32Big.rawValue)!
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
            for row in 0..<(height / 24) {
                let number = UInt32(truncatingIfNeeded: row &* 668_265_263)
                let text = lineText?(row) ?? String(format: "%03d Document line %08X : capture text, row %d", row, number, row)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
                    attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                 NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1)]))
                context.textPosition = CGPoint(x: 16, y: height - row * 24 - 18)
                CTLineDraw(line, context)
            }
        }
        image = TestCanvas.image(width: width, height: height, pixels: pixels)
    }
    func frame(at y: Int, height: Int) -> CGImage {
        image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height))!
    }
}

/// Upright horizontal text, rendered independently rather than transposing vertical test content.
struct HorizontalTextTestCanvas {
    let image: CGImage

    init(width: Int = 4_800, height: Int = 128) {
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                        CGBitmapInfo.byteOrder32Big.rawValue)!
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
            for row in 0..<(height / 22) {
                let text = (0..<80).map { column in
                    let value = UInt32(truncatingIfNeeded: column &* 668_265_263 &+ row &* 374_761_393)
                    return String(format: "%02d-%02d:%08X  ", row, column, value)
                }.joined()
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1)
                ]))
                context.textPosition = CGPoint(x: 0, y: height - row * 22 - 17)
                CTLineDraw(line, context)
            }
        }
        image = TestCanvas.image(width: width, height: height, pixels: pixels)
    }

    func frame(at x: Int, width: Int, height: Int) -> CGImage {
        image.cropping(to: CGRect(x: x, y: 0, width: width, height: height))!
    }
}

enum ViewportOverlayEdge { case top, bottom }

/// Continuous, image-like colour fields: unlike glyphs/noise, adjacent offsets remain very similar.
struct PictureTestCanvas {
    let image: CGImage

    init(width: Int = 12_000, height: Int = 160, period: Int? = nil) {
        let cell = 24
        func colour(_ x: Int, _ y: Int, _ channel: Int) -> Int {
            let x = period.map { x % ($0 / cell) } ?? x
            let seed = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263 &+ channel &* 104_729)
            let hash = (seed ^ (seed >> 13)) &* 1_274_126_177
            return 20 + Int((hash >> 8) % 216)
        }
        var pixels = Data(repeating: 255, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let gx = x / cell, gy = y / cell, fx = x % cell, fy = y % cell
                    for c in 0..<3 {
                        let top = colour(gx, gy, c) * (cell - fx) + colour(gx + 1, gy, c) * fx
                        let bottom = colour(gx, gy + 1, c) * (cell - fx) + colour(gx + 1, gy + 1, c) * fx
                        bytes[(y * width + x) * 4 + c] = UInt8((top * (cell - fy) + bottom * fy) / (cell * cell))
                    }
                }
            }
        }
        image = TestCanvas.image(width: width, height: height, pixels: pixels)
    }

    func frame(at x: Int, width: Int = 800) -> CGImage {
        image.cropping(to: CGRect(x: x, y: 0, width: width, height: image.height))!
    }
}

/// A viewport-fixed fade and jump button, not part of the scrolling document.
func withViewportOverlay(_ image: CGImage, edge: ViewportOverlayEdge) throws -> CGImage {
    let source = try PixelImage(image)
    let width = source.width, height = source.height
    let fadeHeight = 72
    precondition(height > fadeHeight && width > 48)
    var pixels = source.pixels
    pixels.withUnsafeMutableBytes { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        for distance in 0..<fadeHeight {
            let y = edge == .bottom ? height - 1 - distance : distance
            for x in 0..<width {
                let p = (y * width + x) * 4
                for c in 0..<3 {
                    let value = Int(bytes[p + c])
                    bytes[p + c] = UInt8(value + (255 - value) * (fadeHeight - distance) / fadeHeight)
                }
            }
        }
        let centerY = edge == .bottom ? height - 36 : 35
        for dy in -14...14 {
            for dx in -14...14 where dx * dx + dy * dy <= 196 {
                let ring = dx * dx + dy * dy >= 169
                let arrow = (abs(dx) <= 1 && (-6...5).contains(dy)) ||
                    ((0...6).contains(dy) && abs(abs(dx) - (6 - dy)) <= 1)
                let value: UInt8 = ring ? 215 : arrow ? 90 : 255
                let p = ((centerY + dy) * width + width / 2 + dx) * 4
                bytes[p] = value; bytes[p + 1] = value; bytes[p + 2] = value
            }
        }
    }
    return TestCanvas.image(width: width, height: height, pixels: pixels)
}

func assertPixelsEqual(_ actual: CGImage, _ expected: CGImage,
                       file: StaticString = #filePath, line: UInt = #line) throws {
    XCTAssertEqual(actual.width, expected.width, file: file, line: line)
    XCTAssertEqual(actual.height, expected.height, file: file, line: line)
    let left = try PixelImage(actual), right = try PixelImage(expected)
    XCTAssertEqual(left.pixels, right.pixels, "Every pixel and row must be in source order", file: file, line: line)
}

final class LongCaptureImageTests: XCTestCase {
    func testNormalizationPreservesRGBAAndRowOrder() throws {
        let image = TestCanvas(width: 120, height: 300).frame(at: 20, height: 240)
        let normalized = try PixelImage(image)
        try assertPixelsEqual(normalized.cgImage(), image)
        XCTAssertEqual(normalized.pixels, image.dataProvider!.data! as Data)
    }

    func testScreenBGRAConvertsToSRGBRGBAWithoutSwappingRows() throws {
        let original = TestCanvas(width: 120, height: 300).frame(at: 20, height: 240)
        var bgra = original.dataProvider!.data! as Data
        bgra.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for p in stride(from: 0, to: bytes.count, by: 4) {
                let red = bytes[p]; bytes[p] = bytes[p + 2]; bytes[p + 2] = red
            }
        }
        let image = CGImage(width: original.width, height: original.height,
                            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: original.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                CGBitmapInfo.byteOrder32Little.rawValue),
                            provider: CGDataProvider(data: bgra as CFData)!, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        XCTAssertEqual(try PixelImage(image).pixels, try PixelImage(original).pixels)
    }
}
