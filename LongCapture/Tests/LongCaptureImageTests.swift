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
    init(width: Int = 640, height: Int = 1_600) {
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
                let text = String(format: "%03d Document line %08X : capture text, row %d", row, number, row)
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
