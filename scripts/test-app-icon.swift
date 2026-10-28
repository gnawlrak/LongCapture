import CoreGraphics
import Foundation
import ImageIO

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let catalog = root.appendingPathComponent("LongCapture/Resources/Assets.xcassets")
let iconSet = catalog.appendingPathComponent("AppIcon.appiconset")

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "AppIconTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

func json(_ url: URL) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
        throw NSError(domain: "AppIconTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON: \(url.path)"])
    }
    return value
}

do {
    let metadata = try json(iconSet.appendingPathComponent("Contents.json"))
    let entries = metadata["images"] as? [[String: String]] ?? []
    try require(entries.count == 10, "AppIcon must define all ten macOS slots")
    var slots = Set<String>()
    for entry in entries {
        guard let size = entry["size"], let scale = entry["scale"], let filename = entry["filename"],
              let points = Int(size.components(separatedBy: "x")[0]),
              let multiplier = Int(scale.replacingOccurrences(of: "x", with: "")) else {
            throw NSError(domain: "AppIconTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Incomplete icon slot"])
        }
        try require(entry["idiom"] == "mac", "Only macOS icon slots belong here")
        slots.insert("\(size)@\(scale)")
        let url = iconSet.appendingPathComponent(filename)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "AppIconTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unreadable icon: \(filename)"])
        }
        let pixels = points * multiplier
        try require(image.width == pixels && image.height == pixels, "Incorrect pixel size: \(filename)")
        var rgba = [UInt8](repeating: 0, count: pixels * pixels * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: pixels, height: pixels,
                                          bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                            CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw NSError(domain: "AppIconTest", code: 1)
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        }
        for (x, y) in [(0, 0), (pixels - 1, 0), (0, pixels - 1), (pixels - 1, pixels - 1)] {
            try require(rgba[(y * pixels + x) * 4 + 3] == 0, "Icon corners must be transparent: \(filename)")
        }
        let center = ((pixels / 2) * pixels + pixels / 2) * 4
        try require(rgba[center + 3] == 255, "Icon center must be opaque: \(filename)")
        let solid = stride(from: 3, to: rgba.count, by: 4).filter { rgba[$0] >= 250 }.count
        let coverage = Double(solid) / Double(pixels * pixels)
        try require((0.55...0.85).contains(coverage), "Unexpected icon silhouette coverage: \(filename)")
    }
    let expected = Set([16, 32, 128, 256, 512].flatMap { size in
        ["\(size)x\(size)@1x", "\(size)x\(size)@2x"]
    })
    try require(slots == expected, "Missing or duplicated macOS icon slots")
    let catalogInfo = try json(catalog.appendingPathComponent("Contents.json"))["info"] as? [String: Any]
    try require(catalogInfo?["version"] as? Int == 1, "Asset catalog metadata missing")
    let project = try String(contentsOf: root.appendingPathComponent("LongCapture.xcodeproj/project.pbxproj"), encoding: .utf8)
    try require(project.components(separatedBy: "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;").count - 1 == 2,
                "Debug and Release must both select AppIcon")
    try require(project.contains("path = \"LongCapture/Resources/Assets.xcassets\";"), "Asset catalog is not in the project")

    if CommandLine.arguments.count > 1 {
        let app = URL(fileURLWithPath: CommandLine.arguments[1])
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                                                              format: nil) as? [String: Any]
        try require(info?["CFBundleIconName"] as? String == "AppIcon", "Built app must declare AppIcon")
        let name = info?["CFBundleIconFile"] as? String ?? ""
        try require(name == "AppIcon" || name == "AppIcon.icns", "Built app must declare the compiled icon file")
        let icon = app.appendingPathComponent("Contents/Resources/AppIcon.icns")
        let data = try Data(contentsOf: icon)
        try require(data.starts(with: Data("icns".utf8)) && data.count > 1_024, "Compiled app icon is missing or invalid")
        try require(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Resources/Assets.car").path),
                    "Compiled asset catalog is missing")
    }
    print("App icon checks passed: 10 macOS slots, dimensions, alpha, silhouette and project wiring.")
} catch {
    fputs("App icon check failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
