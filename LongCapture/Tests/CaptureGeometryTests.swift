import AppKit
import CoreVideo
import XCTest
@testable import LongCapture

final class CaptureGeometryTests: XCTestCase {
    func testRetinaRegionUsesDisplayLocalTopLeftAndWholePixels() throws {
        let geometry = try CaptureGeometry(displayID: 7,
            displayFrame: CGRect(x: -1440, y: 100, width: 1440, height: 900),
            selection: CGRect(x: -1340.25, y: 200.25, width: 400.5, height: 500.5), scale: 2)
        XCTAssertEqual(geometry.sourceRect, CGRect(x: 99.5, y: 299, width: 401, height: 501))
        XCTAssertEqual(geometry.pixelWidth, 802)
        XCTAssertEqual(geometry.pixelHeight, 1002)
        XCTAssertEqual(geometry.globalRect.maxY, 701)
    }

    func testRejectsCrossDisplayAndTooSmallSelections() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertThrowsError(try CaptureGeometry(displayID: 1, displayFrame: display,
            selection: CGRect(x: 900, y: 100, width: 200, height: 300), scale: 2))
        XCTAssertThrowsError(try CaptureGeometry(displayID: 1, displayFrame: display,
            selection: CGRect(x: 0, y: 0, width: 10, height: 100), scale: 2))
    }

    func testBGRAFrameCopyPreservesColorsAndOwnsSurfaceBytes() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 4, 3, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel))
        memset(base, 0, CVPixelBufferGetBytesPerRow(pixel) * 3)
        let p = base.assumingMemoryBound(to: UInt8.self)
        p[0] = 31; p[1] = 71; p[2] = 201; p[3] = 255
        CVPixelBufferUnlockBaseAddress(pixel, [])
        let image = try XCTUnwrap(ScreenFrameCopy.image(from: pixel))
        CVPixelBufferLockBaseAddress(pixel, [])
        p[2] = 0
        CVPixelBufferUnlockBaseAddress(pixel, [])
        let copiedBytes = image.dataProvider!.data! as Data
        XCTAssertEqual(Array(copiedBytes.prefix(4)), [31, 71, 201, 255])
        XCTAssertEqual(image.alphaInfo, .premultipliedFirst)
        XCTAssertEqual(image.bitmapInfo.intersection(.byteOrderMask), .byteOrder32Little)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 3)
    }
}
