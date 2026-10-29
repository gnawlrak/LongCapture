import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin

/// Sealed pages live on disk; only the current page needs full-resolution pixel storage.
struct CapturePage: @unchecked Sendable {
    let origin: Int
    let width: Int
    let height: Int
    let fileURL: URL?
    private let image: CGImage?
    var retainedPixelBytes: Int { image == nil ? 0 : width * height * 4 }

    init(image: CGImage, origin: Int = 0, fileURL: URL? = nil) {
        self.origin = origin; width = image.width; height = image.height
        self.fileURL = fileURL
        self.image = fileURL == nil ? image : nil
    }

    func load() throws -> CGImage {
        if let image { return image }
        guard let fileURL,
              let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw StitchError.renderFailed }
        return image
    }
}

final class CapturePageArchive: @unchecked Sendable {
    let directory: URL
    private var created = false

    init(root: URL = FileManager.default.temporaryDirectory) {
        directory = root.appendingPathComponent("LongCapture-\(UUID().uuidString)", isDirectory: true)
    }

    func store(_ image: CGImage, origin: Int) throws -> CapturePage {
        if !created {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            created = true
        }
        let file = directory.appendingPathComponent(UUID().uuidString + ".png")
        do {
            try Self.writePNG(image, to: file)
            return CapturePage(image: image, origin: origin, fileURL: file)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        // The containing directory is private; create the file privately before ImageIO writes it.
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                            attributes: [.posixPermissions: 0o600]),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw StitchError.renderFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw StitchError.renderFailed }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw StitchError.renderFailed }
        defer { Darwin.close(descriptor) }
        // ImageIO may replace the pre-created file during finalization.
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw StitchError.renderFailed }
        guard fsync(descriptor) == 0 else { throw StitchError.renderFailed }
    }

    func cleanup() {
        guard created else { return }
        try? FileManager.default.removeItem(at: directory)
        created = false
    }

    deinit { cleanup() }
}

/// Pages follow reading order: top-to-bottom or left-to-right, independent of capture direction.
final class CaptureDocument: @unchecked Sendable {
    let pages: [CapturePage]
    let axis: CaptureAxis
    private let archive: CapturePageArchive?

    init(pages: [CapturePage], archive: CapturePageArchive? = nil, axis: CaptureAxis = .vertical) {
        self.pages = pages.sorted { $0.origin < $1.origin }
        self.archive = archive
        self.axis = axis
    }

    convenience init(image: CGImage) { self.init(pages: [CapturePage(image: image)]) }
    deinit { archive?.cleanup() }
}

struct SegmentExportOptions: Equatable, Sendable {
    var length = 2400
    var overlap = 120

    func ranges(imageLength: Int) throws -> [Range<Int>] {
        guard length >= 256, length <= 20_000, overlap >= 0, overlap <= length / 2,
              imageLength > 0 else { throw SegmentExportError.invalidOptions }
        var ranges: [Range<Int>] = []
        var top = 0
        while top < imageLength {
            let end = min(imageLength, top + length)
            ranges.append(top..<end)
            if end == imageLength { break }
            top = end - overlap
        }
        return ranges
    }
}

enum SegmentExportError: LocalizedError {
    case invalidOptions, busy
    var errorDescription: String? {
        switch self {
        case .invalidOptions: return "分段长度应为 256–20,000 像素，重叠应在 0 到分段长度的一半之间。"
        case .busy: return "正在导出，请完成后再保存或退出。"
        }
    }
}
