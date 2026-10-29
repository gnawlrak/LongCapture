import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ResultStore {
    /// A group is published by one no-replace directory rename: failures expose no partial group.
    func save(document: CaptureDocument, to directory: URL, capturedAt: Date,
              segments: SegmentExportOptions? = nil) throws -> URL {
        guard !document.pages.isEmpty else { throw StitchError.noContent }
        if document.pages.count == 1, segments == nil {
            return try save(image: document.pages[0].load(), to: directory, capturedAt: capturedAt)
        }
        let staging = directory.appendingPathComponent(".LongCapture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let base = baseName(capturedAt) + (segments == nil ? "" : "-分段")
        for (index, page) in document.pages.enumerated() {
            try autoreleasepool {
                let image = try page.load()
                let pageName = String(format: "%@-%03d", base, index + 1)
                if let segments {
                    let horizontal = document.axis == .horizontal
                    for (piece, rows) in try segments.ranges(imageLength: horizontal ? image.width : image.height).enumerated() {
                        try autoreleasepool {
                            let rect = horizontal
                                ? CGRect(x: rows.lowerBound, y: 0, width: rows.count, height: image.height)
                                : CGRect(x: 0, y: rows.lowerBound, width: image.width, height: rows.count)
                            guard let crop = image.cropping(to: rect)
                            else { throw ResultSaveError.cannotEncode }
                            try CapturePageArchive.writePNG(crop, to: staging.appendingPathComponent(
                                String(format: "%@-%03d.png", pageName, piece + 1)))
                        }
                    }
                } else {
                    try CapturePageArchive.writePNG(image, to: staging.appendingPathComponent(pageName + ".png"))
                }
            }
        }
        let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directoryFD >= 0 else { throw posixError(path: directory.path) }
        defer { Darwin.close(directoryFD) }
        for index in 1...10_000 {
            let name = base + (index == 1 ? "" : " (\(index))")
            if renameatx_np(directoryFD, staging.lastPathComponent, directoryFD, name, UInt32(RENAME_EXCL)) == 0 {
                return directory.appendingPathComponent(name, isDirectory: true)
            }
            if errno != EEXIST { throw posixError(path: directory.path) }
        }
        throw ResultSaveError.tooManyCollisions
    }

    func save(image: CGImage, to directory: URL, capturedAt: Date) throws -> URL {
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else {
            throw ResultSaveError.cannotEncode
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ResultSaveError.cannotEncode }

        let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directoryFD >= 0 else { throw posixError(path: directory.path) }
        defer { Darwin.close(directoryFD) }
        let temporaryName = ".LongCapture-\(UUID().uuidString).tmp"
        let fileFD = openat(directoryFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard fileFD >= 0 else { throw posixError(path: directory.path) }
        var isClosed = false
        defer {
            if !isClosed { Darwin.close(fileFD) }
            unlinkat(directoryFD, temporaryName, 0)
        }

        var written = 0
        while written < encoded.length {
            let count = Darwin.write(fileFD, encoded.bytes.advanced(by: written), encoded.length - written)
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError(path: directory.path)
            }
            guard count > 0 else { throw ResultSaveError.cannotWrite }
            written += count
        }
        guard fsync(fileFD) == 0 else { throw posixError(path: directory.path) }
        let closeResult = Darwin.close(fileFD)
        isClosed = true
        guard closeResult == 0 else { throw posixError(path: directory.path) }

        let baseName = baseName(capturedAt)
        for index in 1...10_000 {
            let suffix = index == 1 ? "" : " (\(index))"
            let filename = "\(baseName)\(suffix).png"
            // Publish only a complete PNG, atomically, and never replace an existing name.
            if renameatx_np(directoryFD, temporaryName, directoryFD, filename, UInt32(RENAME_EXCL)) == 0 {
                return directory.appendingPathComponent(filename)
            }
            if errno != EEXIST { throw posixError(path: directory.appendingPathComponent(filename).path) }
        }
        throw ResultSaveError.tooManyCollisions
    }

    private func posixError(path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
    }

    private func baseName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"
        return "长截图 \(formatter.string(from: date))"
    }
}

enum ResultSaveError: LocalizedError {
    case cannotEncode, cannotWrite, tooManyCollisions

    var errorDescription: String? {
        switch self {
        case .cannotEncode: return "无法将截图编码为 PNG。截图仍然保留。"
        case .cannotWrite: return "PNG 写入未完成。请重试或选择其他目录。"
        case .tooManyCollisions: return "目标目录内存在过多同名文件，请选择其他目录。"
        }
    }
}
