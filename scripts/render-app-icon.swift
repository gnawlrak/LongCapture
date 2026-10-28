import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let catalog = root.appendingPathComponent("LongCapture/Resources/Assets.xcassets")
let iconSet = catalog.appendingPathComponent("AppIcon.appiconset")
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func gradient(_ context: CGContext, path: CGPath, colors: [CGColor], from start: CGPoint, to end: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

func drawIcon(_ context: CGContext, scale: CGFloat) {
    let tile = rounded(CGRect(x: 64, y: 64, width: 896, height: 896), radius: 202)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 20 * scale, color: color(0x092C2B, alpha: 0.26))
    context.addPath(tile)
    context.setFillColor(color(0x176E65))
    context.fillPath()
    context.restoreGState()
    gradient(context, path: tile, colors: [color(0x4FAE96), color(0x247F73), color(0x10544F)],
             from: CGPoint(x: 196, y: 960), to: CGPoint(x: 818, y: 64))

    context.saveGState()
    context.addPath(tile)
    context.clip()
    let glow = CGGradient(colorsSpace: space,
                          colors: [color(0xD8FEEB, alpha: 0.16), color(0xD8FEEB, alpha: 0)] as CFArray,
                          locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 228, y: 910), startRadius: 0,
                               endCenter: CGPoint(x: 228, y: 910), endRadius: 780, options: [])
    context.restoreGState()
    context.addPath(tile)
    context.setStrokeColor(color(0xE3FFF0, alpha: 0.22))
    context.setLineWidth(2)
    context.strokePath()

    let paper = CGMutablePath()
    paper.move(to: CGPoint(x: 360, y: 846))
    paper.addLine(to: CGPoint(x: 664, y: 846))
    paper.addQuadCurve(to: CGPoint(x: 688, y: 822), control: CGPoint(x: 688, y: 846))
    paper.addLine(to: CGPoint(x: 688, y: 250))
    paper.addCurve(to: CGPoint(x: 610, y: 164), control1: CGPoint(x: 688, y: 188), control2: CGPoint(x: 658, y: 164))
    paper.addLine(to: CGPoint(x: 412, y: 164))
    paper.addCurve(to: CGPoint(x: 336, y: 246), control1: CGPoint(x: 364, y: 164), control2: CGPoint(x: 336, y: 194))
    paper.addLine(to: CGPoint(x: 336, y: 822))
    paper.addQuadCurve(to: CGPoint(x: 360, y: 846), control: CGPoint(x: 336, y: 846))
    paper.closeSubpath()
    context.saveGState()
    context.setShadow(offset: CGSize(width: 7 * scale, height: -15 * scale), blur: 24 * scale, color: color(0x052D2B, alpha: 0.30))
    context.addPath(paper)
    context.setFillColor(color(0xF3F6EC))
    context.fillPath()
    context.restoreGState()
    gradient(context, path: paper, colors: [color(0xFFFEF8), color(0xF8FAF1), color(0xDFEAE0)],
             from: CGPoint(x: 382, y: 846), to: CGPoint(x: 650, y: 164))
    context.addPath(paper)
    context.setStrokeColor(color(0xFFFFFF, alpha: 0.64))
    context.setLineWidth(2)
    context.strokePath()

    for (y, width) in [(746.0, 220.0), (678, 166), (610, 220), (478, 220), (410, 146), (314, 182)] {
        let line = rounded(CGRect(x: 382, y: y, width: width, height: 19), radius: 9.5)
        gradient(context, path: line, colors: [color(0x86ADA0), color(0xA1BFB1)],
                 from: CGPoint(x: 382, y: y), to: CGPoint(x: 602, y: y + 19))
    }

    // The strip remains continuous below the capture frame, then turns gently toward the viewer.
    let curl = CGMutablePath()
    curl.move(to: CGPoint(x: 336, y: 264))
    curl.addCurve(to: CGPoint(x: 414, y: 226), control1: CGPoint(x: 352, y: 237), control2: CGPoint(x: 380, y: 226))
    curl.addLine(to: CGPoint(x: 610, y: 226))
    curl.addCurve(to: CGPoint(x: 688, y: 264), control1: CGPoint(x: 647, y: 226), control2: CGPoint(x: 673, y: 238))
    curl.addLine(to: CGPoint(x: 688, y: 246))
    curl.addCurve(to: CGPoint(x: 610, y: 164), control1: CGPoint(x: 688, y: 191), control2: CGPoint(x: 657, y: 164))
    curl.addLine(to: CGPoint(x: 412, y: 164))
    curl.addCurve(to: CGPoint(x: 336, y: 246), control1: CGPoint(x: 365, y: 164), control2: CGPoint(x: 336, y: 195))
    curl.closeSubpath()
    gradient(context, path: curl, colors: [color(0xA6BEB1), color(0xF4F8EE), color(0xDFE9DF)],
             from: CGPoint(x: 512, y: 272), to: CGPoint(x: 512, y: 164))

    let corners = CGMutablePath()
    let left: CGFloat = 230, right: CGFloat = 794, top: CGFloat = 844, bottom: CGFloat = 378, arm: CGFloat = 78
    for (x, direction) in [(left, CGFloat(1)), (right, CGFloat(-1))] {
        corners.move(to: CGPoint(x: x, y: top - arm))
        corners.addLine(to: CGPoint(x: x, y: top - 12))
        corners.addQuadCurve(to: CGPoint(x: x + direction * 12, y: top), control: CGPoint(x: x, y: top))
        corners.addLine(to: CGPoint(x: x + direction * arm, y: top))
        corners.move(to: CGPoint(x: x, y: bottom + arm))
        corners.addLine(to: CGPoint(x: x, y: bottom + 12))
        corners.addQuadCurve(to: CGPoint(x: x + direction * 12, y: bottom), control: CGPoint(x: x, y: bottom))
        corners.addLine(to: CGPoint(x: x + direction * arm, y: bottom))
    }
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -5 * scale), blur: 7 * scale, color: color(0x063C36, alpha: 0.23))
    context.addPath(corners)
    context.setLineWidth(32)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(color(0xF1FFF4))
    context.strokePath()
    context.restoreGState()
}

func writeIcon(pixels: Int, to url: URL) throws {
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                  bytesPerRow: pixels * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                    CGBitmapInfo.byteOrder32Big.rawValue) else {
        throw NSError(domain: "AppIconRenderer", code: 1)
    }
    context.setAllowsAntialiasing(true)
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    drawIcon(context, scale: scale)
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "AppIconRenderer", code: 2)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "AppIconRenderer", code: 3) }
}

func writeJSON(_ value: [String: Any], to url: URL) throws {
    var data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    data.append(0x0A)
    try data.write(to: url)
}

try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
let info: [String: Any] = ["author": "xcode", "version": 1]
try writeJSON(["info": info], to: catalog.appendingPathComponent("Contents.json"))
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try writeIcon(pixels: size * scale, to: iconSet.appendingPathComponent(filename))
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": filename])
    }
}
try writeJSON(["images": images, "info": info], to: iconSet.appendingPathComponent("Contents.json"))
print("Rendered ten macOS app-icon slots in \(iconSet.path)")
