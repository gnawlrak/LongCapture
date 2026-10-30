import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers

enum ResultTransferError: LocalizedError {
    case cannotEncode
    var errorDescription: String? { "无法生成原始像素 PNG 副本，原图仍然保留。" }
}

/// The promise owns its pixels independently of the preview, source document and archive files.
final class ResultTransferPayload: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private static let activity = TransferWriteActivity()
    static var hasActiveWrites: Bool { activity.isActive }
    let image: CGImage
    let fileName: String
    private let lock = NSLock()
    private var encoded: Data?
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "LongCapture.PNGTransfer"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    init(image: CGImage, capturedAt: Date = Date()) {
        self.image = image
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"
        fileName = "长截图 \(formatter.string(from: capturedAt)).png"
    }

    func pngRepresentation() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let encoded { return encoded }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw ResultTransferError.cannotEncode }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ResultTransferError.cannotEncode }
        let encoded = data as Data
        self.encoded = encoded
        return encoded
    }

    func writePNG(to url: URL) throws {
        guard url.isFileURL else { throw ResultTransferError.cannotEncode }
        let data = try pngRepresentation()
        let directory = url.deletingLastPathComponent()
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError(directory.path) }
        defer { Darwin.close(descriptor) }
        let staging = ".LongCapture-transfer-\(UUID().uuidString).tmp"
        let file = openat(descriptor, staging, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { throw posixError(directory.path) }
        defer { Darwin.close(file); unlinkat(descriptor, staging, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posixError(url.path) }
                offset += count
            }
        }
        guard fsync(file) == 0,
              renameatx_np(descriptor, staging, descriptor, url.lastPathComponent, UInt32(RENAME_EXCL)) == 0
        else { throw posixError(url.path) }
    }

    private func posixError(_ path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
    }

    @MainActor
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        fileName
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        Self.activity.begin()
        defer { Self.activity.end() }
        do { try writePNG(to: url); completionHandler(nil) }
        catch { completionHandler(error) }
    }

    @MainActor
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }
}

private final class TransferWriteActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return count > 0 }
    func begin() { lock.lock(); defer { lock.unlock() }; count += 1 }
    func end() { lock.lock(); defer { lock.unlock() }; count -= 1 }
}

@MainActor
final class ResultFilePromiseProvider: NSFilePromiseProvider {
    private let payload: ResultTransferPayload

    init(payload: ResultTransferPayload) {
        self.payload = payload
        super.init()
        fileType = UTType.png.identifier
        delegate = payload
        userInfo = payload
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.png]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .png ? try? payload.pngRepresentation() : super.pasteboardPropertyList(forType: type)
    }

}

/// Both thumbnail and preview use the same native copy-only drag and click/drag threshold.
@MainActor
class ResultDragSourceView: NSView, NSDraggingSource {
    private static var activeDragCount = 0
    static var hasActiveDrag: Bool { activeDragCount > 0 }
    let transferImage: NSImage
    var onInteraction: (Bool) -> Void = { _ in }
    var canDrag: () -> Bool = { true }
    var onClick: () -> Void = {}
    private var mouseOrigin: NSPoint?
    private(set) var isDraggingImage = false

    init(frame: NSRect, image: NSImage) {
        transferImage = image
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func draggingItem(at point: NSPoint) throws -> NSDraggingItem {
        guard let image = transferImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw ResultTransferError.cannotEncode }
        let writer = ResultFilePromiseProvider(payload: ResultTransferPayload(image: image))
        let item = NSDraggingItem(pasteboardWriter: writer)
        let scale = min(1, 180 / max(transferImage.size.width, transferImage.size.height))
        let size = NSSize(width: max(1, transferImage.size.width * scale), height: max(1, transferImage.size.height * scale))
        item.setDraggingFrame(NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                     width: size.width, height: size.height), contents: transferImage)
        return item
    }

    override func mouseDown(with event: NSEvent) {
        guard canDrag() else { return }
        mouseOrigin = event.locationInWindow
        onInteraction(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = mouseOrigin, !isDraggingImage, canDrag(),
              hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 5 else { return }
        do {
            let item = try draggingItem(at: convert(event.locationInWindow, from: nil))
            isDraggingImage = true
            Self.activeDragCount += 1
            startImageDrag(item, event: event)
        } catch { endImageDrag(); NSSound.beep() }
    }

    func startImageDrag(_ item: NSDraggingItem, event: NSEvent) {
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseOrigin != nil, !isDraggingImage else { return }
        mouseOrigin = nil
        onInteraction(false)
        onClick()
    }

    func endImageDrag() {
        guard mouseOrigin != nil || isDraggingImage else { return }
        if isDraggingImage { Self.activeDragCount -= 1 }
        mouseOrigin = nil
        isDraggingImage = false
        onInteraction(false)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { endImageDrag() }
}
