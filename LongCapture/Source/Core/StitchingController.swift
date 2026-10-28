import CoreGraphics
import Foundation

/// Owned exclusively by the session's serial processing queue.
final class StitchingController {
    private let estimator: any OffsetEstimating
    private let limits: StitchLimits
    private var state: StitchState?
    private var lastReliable: PixelImage?
    private var terminal = false
    private var cancelled = false
    private var recoveryMessage: String?
    private let limitMessage = "已达到 6,400 万像素或 50,000 像素高度上限，已保留确认的部分。"
    /// Conservative upper bound; the anchor and frontier usually share the same immutable Data.
    var retainedPixelBytes: Int { (state?.retainedPixelBytes ?? 0) + (lastReliable?.pixels.count ?? 0) }

    init(estimator: any OffsetEstimating = VisionOffsetEstimator(), limits: StitchLimits = .default) {
        self.estimator = estimator; self.limits = limits
    }

    @discardableResult
    func accept(_ image: CGImage) -> StitchUpdate {
        guard !terminal else { return update(.rejected, message: "本次截图已结束。") }
        if state?.atLimit == true { return update(.hitLimit, message: limitMessage) }
        do {
            let frame = try PixelImage(image)
            guard let previous = lastReliable else {
                state = try StitchState(first: frame, limits: limits)
                lastReliable = state?.atLimit == true ? nil : frame
                return state?.atLimit == true ? update(.hitLimit, message: limitMessage) : update(.grew)
            }
            guard frame.width == previous.width, frame.height == previous.height else {
                return recover("画面尺寸发生变化，已暂停拼接。")
            }
            if frame.pixels == previous.pixels {
                recoveryMessage = nil
                return update(.stayed)
            }
            let estimate = estimator.estimate(previous: previous, current: frame)
            guard let shift = estimate.shift, shift > -frame.height, shift < frame.height else {
                return recover(estimate.message ?? "匹配不可靠，已暂停拼接。请往回滚动恢复。")
            }
            guard OverlapValidator().score(previous, frame, shift: shift).isReliable else {
                return recover("无法确认正文重叠，已暂停拼接。请往回滚动恢复。")
            }
            let action = state?.accept(frame, shift: shift) ?? .rejected
            if action == .needsRecovery || action == .rejected { return recover("无法确认画面重叠，请往回滚动恢复。") }
            lastReliable = state?.atLimit == true ? nil : frame
            recoveryMessage = nil
            return update(action, message: action == .hitLimit ? limitMessage : nil)
        } catch { return recover(error.localizedDescription) }
    }

    func finish() throws -> StitchedCapture {
        guard !cancelled else { throw StitchError.cancelled }
        guard !terminal else { throw StitchError.alreadyFinished }
        terminal = true
        guard let state else { throw StitchError.noContent }
        let reason = state.atLimit ? limitMessage : recoveryMessage
        let result = StitchedCapture(image: try state.render(), incomplete: reason != nil, reason: reason)
        self.state = nil
        lastReliable = nil
        return result
    }

    func cancel() {
        cancelled = true; terminal = true
        state = nil; lastReliable = nil; recoveryMessage = nil
    }

    private func recover(_ message: String) -> StitchUpdate {
        recoveryMessage = message
        return update(.needsRecovery, message: message)
    }

    private func update(_ action: StitchAction, message: String? = nil) -> StitchUpdate {
        StitchUpdate(action: action, height: state?.imageHeight ?? 0, message: message)
    }
}
