import CoreGraphics
import Foundation

/// Only this queue touches the stitcher. A busy matcher retains one newest pending frame.
final class FrameProcessingPipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.longcapture.stitching", qos: .userInitiated)
    private let lock = NSLock()
    private var latest: CGImage?
    private var scheduled = false
    private var accepting = true
    private var cancelled = false
    private var finishing = false
    private let acceptFrame: (CGImage) -> StitchUpdate
    private let finishCapture: () throws -> StitchedCapture
    private let cancelCapture: () -> Void
    private let onUpdate: (StitchUpdate) -> Void

    init(accept: @escaping (CGImage) -> StitchUpdate,
         finish: @escaping () throws -> StitchedCapture,
         cancel: @escaping () -> Void, onUpdate: @escaping (StitchUpdate) -> Void) {
        self.acceptFrame = accept
        self.finishCapture = finish
        self.cancelCapture = cancel
        self.onUpdate = onUpdate
    }

    convenience init(controller: StitchingController, onUpdate: @escaping (StitchUpdate) -> Void) {
        self.init(accept: controller.accept, finish: controller.finish, cancel: controller.cancel, onUpdate: onUpdate)
    }

    func submit(_ image: CGImage) {
        lock.lock()
        guard accepting, !cancelled else { lock.unlock(); return }
        latest = image
        let shouldSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if shouldSchedule { queue.async { self.drain() } }
    }

    func finish(_ completion: @escaping (Result<StitchedCapture, Error>) -> Void) {
        lock.lock()
        guard !finishing else { lock.unlock(); return }
        accepting = false
        finishing = true
        lock.unlock()
        queue.async {
            self.drain()
            self.lock.lock(); let cancelled = self.cancelled; self.lock.unlock()
            guard !cancelled else { completion(.failure(CaptureSessionError.cancelled)); return }
            completion(Result { try self.finishCapture() })
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        accepting = false
        latest = nil
        lock.unlock()
        queue.async { self.cancelCapture() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard !cancelled, let frame = latest else {
                scheduled = false
                lock.unlock()
                return
            }
            latest = nil
            lock.unlock()
            let update = autoreleasepool { acceptFrame(frame) }
            lock.lock(); let report = !cancelled; lock.unlock()
            if report { onUpdate(update) }
        }
    }
}

@MainActor
final class SessionCoordinator {
    enum State: Equatable { case idle, selecting, starting, capturing, finishing, result }
    typealias SourceFactory = @MainActor (CaptureGeometry, @escaping (CGImage) -> Void,
                                         @escaping (Error) -> Void) async throws -> any CaptureFrameSource

    private(set) var state: State = .idle { didSet { onStateChanged(state) } }
    private var pipeline: FrameProcessingPipeline?
    private var source: (any CaptureFrameSource)?
    private var geometry: CaptureGeometry?
    private var generation: UInt = 0
    private let sourceFactory: SourceFactory
    private let now: () -> Date
    private let onResult: (SessionResult) -> Void
    private let onError: (Error) -> Void
    private let onUpdate: (StitchUpdate) -> Void
    private let onStateChanged: (State) -> Void
    private let controllerFactory: (CaptureAxis) -> StitchingController

    init(sourceFactory: @escaping SourceFactory = { geometry, frame, error in
        try await ScreenCaptureController(geometry: geometry, onFrame: frame, onError: error)
    }, now: @escaping () -> Date = Date.init,
         onResult: @escaping (SessionResult) -> Void,
         onError: @escaping (Error) -> Void,
         onUpdate: @escaping (StitchUpdate) -> Void = { _ in },
         onStateChanged: @escaping (State) -> Void = { _ in },
         controllerFactory: @escaping (CaptureAxis) -> StitchingController = { StitchingController(continuesAtLimit: true, axis: $0) }) {
        self.sourceFactory = sourceFactory
        self.now = now
        self.onResult = onResult
        self.onError = onError
        self.onUpdate = onUpdate
        self.onStateChanged = onStateChanged
        self.controllerFactory = controllerFactory
    }

    func prepareForSelection() {
        guard state == .idle else { return }
        state = .selecting
    }

    func beginCapture(geometry: CaptureGeometry, axis: CaptureAxis = .automatic) async {
        guard state == .selecting else { return }
        generation &+= 1
        let token = generation
        self.geometry = geometry
        let pipeline = FrameProcessingPipeline(controller: controllerFactory(axis), onUpdate: { [weak self] update in
            Task { @MainActor in
                guard let self, self.generation == token,
                      self.state == .capturing || self.state == .starting else { return }
                self.onUpdate(update)
                if update.action == .hitLimit { await self.complete(notice: update.message ?? "已达到图像上限。") }
            }
        })
        self.pipeline = pipeline
        state = .starting
        do {
            let source = try await sourceFactory(geometry, { [weak pipeline] image in
                pipeline?.submit(image)
            }, { [weak self] error in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    await self.interrupt(reason: "采集流中断：\(error.localizedDescription)")
                }
            })
            guard generation == token, state == .starting else { await source.stop(); return }
            self.source = source
            try await source.start()
            guard generation == token, state == .starting else { await source.stop(); return }
            state = .capturing
        } catch {
            guard generation == token, state == .starting else { return }
            pipeline.cancel()
            self.pipeline = nil
            let failedSource = source
            source = nil
            state = .idle
            await failedSource?.stop()
            guard generation == token, state == .idle else { return }
            onError(error)
        }
    }

    func complete(notice: String? = nil) async {
        guard state == .capturing || state == .starting,
              let pipeline, let geometry else { return }
        let token = generation
        state = .finishing
        await source?.stop()
        source = nil
        guard token == generation, state == .finishing else { return }
        pipeline.finish { [weak self] outcome in
            Task { @MainActor in
                guard let self, self.generation == token, self.state == .finishing else { return }
                self.pipeline = nil
                switch outcome {
                case .success(let capture):
                    self.state = .result
                    var warnings: [String] = []
                    for warning in [capture.reason, notice].compactMap({ $0 }) where !warning.isEmpty && !warnings.contains(warning) {
                        warnings.append(warning)
                    }
                    self.onResult(SessionResult(image: capture.image, displayScale: geometry.scale,
                        region: geometry.globalRect, screenID: geometry.displayID, screenFrame: geometry.displayFrame,
                        capturedAt: self.now(), incomplete: capture.incomplete || notice != nil,
                        notice: warnings.isEmpty ? nil : warnings.joined(separator: "\n"), document: capture.document))
                case .failure(let error):
                    self.state = .idle
                    self.onError(error)
                }
            }
        }
    }

    func interrupt(reason: String) async {
        if state == .selecting { await cancel() }
        else { await complete(notice: reason + " 已保留确认部分，结果可能不完整。") }
    }

    func cancel() async {
        generation &+= 1
        pipeline?.cancel()
        pipeline = nil
        let oldSource = source
        source = nil
        geometry = nil
        state = .idle
        await oldSource?.stop()
    }

    func resolveResult() {
        guard state == .result else { return }
        geometry = nil
        state = .idle
    }
}

struct SessionResult: @unchecked Sendable {
    let image: CGImage
    let displayScale: CGFloat
    let region: CGRect
    let screenID: CGDirectDisplayID
    let screenFrame: CGRect
    let capturedAt: Date
    let incomplete: Bool
    let notice: String?
    let document: CaptureDocument

    init(image: CGImage, displayScale: CGFloat, region: CGRect, screenID: CGDirectDisplayID,
         screenFrame: CGRect, capturedAt: Date, incomplete: Bool, notice: String?, document: CaptureDocument? = nil) {
        self.image = image; self.displayScale = displayScale; self.region = region; self.screenID = screenID
        self.screenFrame = screenFrame; self.capturedAt = capturedAt; self.incomplete = incomplete; self.notice = notice
        self.document = document ?? CaptureDocument(image: image)
    }
}

enum CaptureSessionError: LocalizedError {
    case noFrames, cancelled
    var errorDescription: String? {
        switch self {
        case .noFrames: return "尚未取得完整画面，请重新开始并等待选区准备就绪。"
        case .cancelled: return "采集已取消。"
        }
    }
}
