import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ResultStore {
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

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"
        let baseName = "长截图 \(formatter.string(from: capturedAt))"
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
