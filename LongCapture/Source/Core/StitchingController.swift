import CoreGraphics
import Foundation

/// Owned exclusively by the session's serial processing queue.
final class StitchingController {
    private let estimator: any OffsetEstimating
    private let limits: StitchLimits
    private let continuesAtLimit: Bool
    private var axis: CaptureAxis
    private var pendingAxisFrame: (frame: PixelImage, axis: CaptureAxis, shift: Int)?
    private var archive: CapturePageArchive?
    private var pages: [CapturePage] = []
    private var state: StitchState?
    private var lastReliable: PixelImage?
    private var terminal = false
    private var cancelled = false
    private var stopped = false
    private var recoveryMessage: String?
    private var referenceImage: CGImage?
    private var seedPosition = 0
    private var absolutePosition = 0
    private var carryoverRows = 0
    private let limitMessage = "单帧已达到图像上限，请缩小选区后重新截图。"
    var retainedPixelBytes: Int {
        (state?.retainedPixelBytes ?? 0) + (lastReliable?.pixels.count ?? 0) +
            (pendingAxisFrame?.frame.pixels.count ?? 0) + pages.reduce(0) { $0 + $1.retainedPixelBytes }
    }

    init(estimator: any OffsetEstimating = VisionOffsetEstimator(), limits: StitchLimits = .default,
         continuesAtLimit: Bool = false, archive: CapturePageArchive = CapturePageArchive(), axis: CaptureAxis = .vertical) {
        self.estimator = estimator; self.limits = limits
        self.continuesAtLimit = continuesAtLimit; self.archive = archive
        self.axis = axis
    }

    @discardableResult
    func accept(_ image: CGImage) -> StitchUpdate {
        guard !terminal else { return update(.rejected, message: "本次截图已结束。") }
        if stopped || state?.atLimit == true { return update(.hitLimit, message: recoveryMessage ?? limitMessage) }
        do {
            let sourceFrame = try PixelImage(image)
            if axis == .automatic { return try acceptAutomatic(sourceFrame) }
            let frame = axis == .horizontal ? try sourceFrame.transposed() : sourceFrame
            return try acceptFrame(frame)
        } catch { return recover(error.localizedDescription) }
    }

    private func acceptAutomatic(_ frame: PixelImage) throws -> StitchUpdate {
        guard let previous = lastReliable else {
            lastReliable = frame
            return update(.grew, progress: .unchanged)
        }
        guard previous.width == frame.width, previous.height == frame.height else {
            return recover("画面尺寸发生变化，请恢复原窗口大小或结束截图。")
        }
        if previous.pixels == frame.pixels {
            pendingAxisFrame = nil
            clearRecovery()
            return update(.stayed, progress: .unchanged)
        }
        var candidates: [(axis: CaptureAxis, shift: Int)] = []
        var stationary = false
        for direction in [CaptureAxis.vertical, .horizontal] {
            let old = direction == .horizontal ? try previous.transposed() : previous
            let current = direction == .horizontal ? try frame.transposed() : frame
            guard let shift = estimator.estimate(previous: old, current: current).shift,
                  shift > -current.height, shift < current.height,
                  OverlapValidator().score(old, current, shift: shift).isReliable else { continue }
            if shift == 0 { stationary = true }
            else { candidates.append((direction, shift)) }
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            if candidates.isEmpty && stationary {
                clearRecovery()
                return update(.stayed, progress: .unchanged)
            }
            return recover("暂时无法确认滚动方向，请回到参考画面，再沿一个方向小幅滚动。")
        }
        // Keep the original anchor: tiny movements accumulate without locking on a one-pixel wobble.
        // A confirmed tiny tail is flushed at Finish even if the locking threshold is never reached.
        pendingAxisFrame = (frame, candidate.axis, candidate.shift)
        if abs(candidate.shift) < 4 {
            clearRecovery()
            return update(.stayed, progress: .unchanged)
        }
        return try lockAutomatic(frame: frame, axis: candidate.axis, shift: candidate.shift)
    }

    private func lockAutomatic(frame: PixelImage, axis selected: CaptureAxis, shift: Int) throws -> StitchUpdate {
        guard let previous = lastReliable else { throw StitchError.noContent }
        let old = selected == .horizontal ? try previous.transposed() : previous
        let current = selected == .horizontal ? try frame.transposed() : frame
        let initial = try StitchState(first: old, limits: limits)
        if !initial.atLimit {
            var probe = initial
            let action = probe.accept(current, shift: shift)
            guard action != .needsRecovery, action != .rejected else {
                pendingAxisFrame = nil
                return recover("接缝未能通过校验，请回到参考画面后继续。")
            }
        }
        axis = selected
        state = initial
        lastReliable = old
        pendingAxisFrame = nil
        if initial.atLimit {
            stopped = true
            recoveryMessage = limitMessage
            return update(.hitLimit, message: limitMessage)
        }
        return try acceptFrame(current, knownEstimate: MoveEstimate(shift: shift))
    }

    private func acceptFrame(_ frame: PixelImage, knownEstimate: MoveEstimate? = nil) throws -> StitchUpdate {
        guard let previous = lastReliable else {
            clearRecovery()
            state = try StitchState(first: frame, limits: limits)
            lastReliable = state?.atLimit == true ? nil : frame
            if state?.atLimit == true {
                stopped = true
                recoveryMessage = continuesAtLimit ? limitMessage : "已达到图像上限，已保留确认部分。"
                return update(.hitLimit, message: recoveryMessage)
            }
            return update(.grew)
        }
        guard frame.width == previous.width, frame.height == previous.height else {
            return recover("画面尺寸发生变化，请恢复原窗口大小或结束截图。")
        }
        let wasRecovering = recoveryMessage != nil
        if frame.pixels == previous.pixels {
            clearRecovery()
            return update(.stayed, progress: wasRecovering ? .recovered : idleProgress)
        }
        let estimate = knownEstimate ?? estimator.estimate(previous: previous, current: frame)
        guard let shift = estimate.shift, shift > -frame.height, shift < frame.height else {
            return recover(estimate.message ?? "重叠或纹理证据不足，请往回滚到参考画面，再减小滚动幅度。")
        }
        guard OverlapValidator().score(previous, frame, shift: shift).isReliable else {
            return recover("无法确认正文重叠，请往回滚到参考画面，再减小滚动幅度。")
        }
        // Retain the integer anchor so subpixel motion can accumulate.
        if shift == 0 {
            clearRecovery()
            return update(.stayed, progress: wasRecovering ? .recovered : idleProgress)
        }
        let action = state?.accept(frame, shift: shift) ?? .rejected
        if action == .needsRecovery || action == .rejected {
            return recover("接缝未能通过校验，请往回滚到参考画面后继续。")
        }
        absolutePosition += shift
        clearRecovery()
        if action == .hitLimit, continuesAtLimit {
            return try continuePage(with: frame)
        }
        lastReliable = state?.atLimit == true ? nil : frame
        return update(action, message: action == .hitLimit ? "已达到图像上限，已保留确认部分。" : nil,
                      progress: wasRecovering ? .recovered : action == .stayed ? idleProgress : .growing)
    }

    private func continuePage(with frame: PixelImage) throws -> StitchUpdate {
        guard let old = state, let direction = old.direction else { throw StitchError.invalidFrame }
        let image = try outputImage(old.render())
        let origin = seedPosition + old.upperBound
        // Keep the crossing viewport, not just its clipped strip: it contains all overflow pixels
        // and remains the exact matching anchor. This also preserves seam context after a reversal.
        let next = try StitchState(first: frame, limits: limits, direction: direction)
        carryoverRows = direction == .down
            ? seedPosition + old.lowerBound - absolutePosition
            : absolutePosition + frame.height - (seedPosition + old.upperBound)
        do {
            guard let archive else { throw StitchError.renderFailed }
            pages.append(try archive.store(image, origin: origin))
        } catch {
            // Disk failure must not erase the sealed page or the crossing frame's overflow.
            pages.append(CapturePage(image: image, origin: origin))
            stopped = true
            recoveryMessage = "临时文件写入失败，已停止增长并保留确认内容：\(error.localizedDescription)"
        }
        state = next
        seedPosition = absolutePosition
        lastReliable = stopped ? nil : frame
        if stopped { return update(.hitLimit, message: recoveryMessage) }
        return update(.grew, progress: .continued)
    }

    func finish() throws -> StitchedCapture {
        guard !cancelled else { throw StitchError.cancelled }
        guard !terminal else { throw StitchError.alreadyFinished }
        if axis == .automatic, let anchor = lastReliable {
            if let pending = pendingAxisFrame {
                let warning = recoveryMessage
                _ = try lockAutomatic(frame: pending.frame, axis: pending.axis, shift: pending.shift)
                if let warning { recoveryMessage = warning }
            }
            if state == nil {
                axis = .vertical
                state = try StitchState(first: anchor, limits: limits)
            }
        }
        guard let state else { throw StitchError.noContent }
        var resultPages = pages
        if pages.isEmpty || state.imageHeight > carryoverRows {
            resultPages.append(CapturePage(image: try outputImage(state.render()), origin: seedPosition + state.upperBound))
        }
        guard let first = resultPages.min(by: { $0.origin < $1.origin }) else { throw StitchError.noContent }
        let firstImage = try first.load()
        let document = CaptureDocument(pages: resultPages, archive: archive, axis: axis)
        let reason = recoveryMessage ?? (state.atLimit ? "已达到图像上限，已保留确认部分。" : nil)
        let result = StitchedCapture(image: firstImage, incomplete: reason != nil, reason: reason, document: document)
        terminal = true
        self.state = nil; lastReliable = nil; pendingAxisFrame = nil; pages = []; archive = nil
        return result
    }

    func cancel() {
        cancelled = true; terminal = true
        state = nil; lastReliable = nil; pendingAxisFrame = nil; recoveryMessage = nil; referenceImage = nil
        pages = []; archive?.cleanup(); archive = nil
    }

    private var idleProgress: StitchProgress {
        guard let state else { return .unchanged }
        if state.direction == .down, state.position + state.frameHeight < state.lowerBound { return .revisiting }
        if state.direction == .up, state.position > state.upperBound { return .revisiting }
        return .unchanged
    }

    private func clearRecovery() { recoveryMessage = nil; referenceImage = nil }

    private func outputImage(_ image: CGImage) throws -> CGImage {
        axis == .horizontal ? try PixelImage(image).transposed().cgImage() : image
    }

    private func recover(_ message: String) -> StitchUpdate {
        recoveryMessage = message
        if referenceImage == nil, let previous = lastReliable {
            let reference = axis == .horizontal ? (try? previous.transposed()) ?? previous : previous
            let scale = min(1, min(240 / CGFloat(reference.width), 140 / CGFloat(reference.height)))
            if let context = CGContext(data: nil, width: max(1, Int(CGFloat(reference.width) * scale)),
                                       height: max(1, Int(CGFloat(reference.height) * scale)), bitsPerComponent: 8,
                                       bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
               let image = try? reference.cgImage() {
                context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
                referenceImage = context.makeImage()
            }
        }
        return update(.needsRecovery, message: message, progress: .recovering)
    }

    private func update(_ action: StitchAction, message: String? = nil,
                        progress: StitchProgress = .growing) -> StitchUpdate {
        StitchUpdate(action: action, height: state?.imageHeight ?? lastReliable?.height ?? 0, message: message, progress: progress,
                     referenceImage: referenceImage, pageCount: pages.count + 1,
                     maximumHeight: state?.maximumHeight ?? limits.maximumHeight, axis: axis)
    }
}
