import AppKit
import CoreGraphics
import CoreVideo
import ScreenCaptureKit

struct CaptureGeometry: Sendable {
    let displayID: CGDirectDisplayID
    let displayFrame: CGRect
    let globalRect: CGRect
    let sourceRect: CGRect
    let scale: CGFloat
    let pixelWidth: Int
    let pixelHeight: Int

    init(displayID: CGDirectDisplayID, displayFrame: CGRect, selection: CGRect, scale: CGFloat) throws {
        guard scale.isFinite, scale > 0, selection.width >= 24, selection.height >= 24,
              selection.minX.isFinite, selection.minY.isFinite,
              selection.maxX.isFinite, selection.maxY.isFinite,
              displayFrame.contains(selection) else { throw ScreenCaptureError.invalidSelection }
        let left = floor((selection.minX - displayFrame.minX) * scale) / scale
        let top = floor((displayFrame.maxY - selection.maxY) * scale) / scale
        let right = ceil((selection.maxX - displayFrame.minX) * scale) / scale
        let bottom = ceil((displayFrame.maxY - selection.minY) * scale) / scale
        let rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        let width = Int((rect.width * scale).rounded())
        let height = Int((rect.height * scale).rounded())
        guard width >= 96, height >= 64 else { throw ScreenCaptureError.invalidSelection }
        guard height <= 50_000,
              width <= 64_000_000 / height else { throw ScreenCaptureError.initialFrameTooLarge }
        self.displayID = displayID
        self.displayFrame = displayFrame
        self.sourceRect = rect
        self.globalRect = CGRect(x: displayFrame.minX + left, y: displayFrame.maxY - bottom,
                                 width: rect.width, height: rect.height)
        self.scale = scale
        self.pixelWidth = width
        self.pixelHeight = height
    }
}

protocol CaptureFrameSource: AnyObject {
    func start() async throws
    func stop() async
}

@MainActor
final class ScreenCaptureController: CaptureFrameSource {
    private let stream: SCStream
    private let output: StreamOutput
    private let sampleQueue = DispatchQueue(label: "com.longcapture.frames", qos: .userInitiated)

    init(geometry: CaptureGeometry, onFrame: @escaping (CGImage) -> Void,
         onError: @escaping (Error) -> Void) async throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw ScreenCaptureError.permissionDenied
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == geometry.displayID }) else {
            throw ScreenCaptureError.displayUnavailable
        }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        guard abs(CGFloat(filter.pointPixelScale) - geometry.scale) < 0.01 else {
            throw ScreenCaptureError.displayUnavailable
        }
        let config = SCStreamConfiguration()
        config.sourceRect = geometry.sourceRect
        config.width = geometry.pixelWidth
        config.height = geometry.pixelHeight
        config.colorSpaceName = CGColorSpace.sRGB
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.capturesAudio = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.queueDepth = 3
        let output = StreamOutput(width: geometry.pixelWidth, height: geometry.pixelHeight,
                                  onFrame: onFrame, onError: onError)
        self.output = output
        self.stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
    }

    func start() async throws { try await stream.startCapture() }

    func stop() async {
        output.suppressErrors()
        try? await stream.stopCapture()
        // A barrier follows all already-delivered buffers, so Finish includes the last complete frame.
        await withCheckedContinuation { continuation in
            sampleQueue.async { [output] in
                output.deactivate()
                continuation.resume()
            }
        }
    }
}

private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let width: Int
    private let height: Int
    private let onFrame: (CGImage) -> Void
    private let onError: (Error) -> Void
    private let lock = NSLock()
    private var active = true
    private var stopping = false

    init(width: Int, height: Int, onFrame: @escaping (CGImage) -> Void, onError: @escaping (Error) -> Void) {
        self.width = width
        self.height = height
        self.onFrame = onFrame
        self.onError = onError
    }

    func suppressErrors() { lock.lock(); stopping = true; lock.unlock() }
    func deactivate() { lock.lock(); active = false; lock.unlock() }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        lock.lock(); let enabled = active; lock.unlock()
        guard enabled, type == .screen, CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusValue) == .complete,
              let pixel = sampleBuffer.imageBuffer,
              CVPixelBufferGetWidth(pixel) == width, CVPixelBufferGetHeight(pixel) == height,
              let image = ScreenFrameCopy.image(from: pixel) else { return }
        onFrame(image)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); let report = active && !stopping; lock.unlock()
        if report { onError(error) }
    }
}

enum ScreenFrameCopy {
    static func image(from pixel: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
        guard let base = CVPixelBufferGetBaseAddress(pixel), width > 0, height > 0 else { return nil }
        let targetStride = width * 4
        let sourceStride = CVPixelBufferGetBytesPerRow(pixel)
        var bytes = Data(count: targetStride * height)
        bytes.withUnsafeMutableBytes { destination in
            guard let target = destination.baseAddress else { return }
            for row in 0..<height {
                memcpy(target.advanced(by: row * targetStride), base.advanced(by: row * sourceStride), targetStride)
            }
        }
        guard let provider = CGDataProvider(data: bytes as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: targetStride, space: space, bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

enum ScreenCaptureError: LocalizedError {
    case displayUnavailable, permissionDenied, invalidSelection, initialFrameTooLarge

    var errorDescription: String? {
        switch self {
        case .displayUnavailable: return "显示器已断开或分辨率发生变化，请重新框选。"
        case .permissionDenied: return "尚未允许屏幕录制。请在系统设置的隐私与安全性中允许「长截图」，必要时重新启动应用。"
        case .invalidSelection: return "请在同一显示器内选择纵向滚动区域，至少 24 × 24 点且不小于 96 × 64 像素。"
        case .initialFrameTooLarge: return "选区超过 6,400 万像素或 50,000 像素高度，请缩小选区。"
        }
    }
}
