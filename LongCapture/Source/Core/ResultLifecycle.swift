import Foundation

/// A clock-driven model shared by the thumbnail and the preview; it owns no image data.
final class ResultLifecycle {
    enum State: Equatable { case thumbnail, preview, saving, resolved }
    enum Presentation { case thumbnail, preview }

    private(set) var state: State
    private let now: () -> TimeInterval
    private var remaining: TimeInterval
    private var deadline: TimeInterval?
    private var countdownEnabled: Bool
    private var isHovered = false
    private var isInteracting = false
    private var saveReturnState: State = .thumbnail

    init(presentation: Presentation = .thumbnail, delay: TimeInterval = 5,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        remaining = max(0, delay)
        state = presentation == .thumbnail ? .thumbnail : .preview
        countdownEnabled = presentation == .thumbnail
        deadline = presentation == .thumbnail ? now() + remaining : nil
    }

    var secondsRemaining: TimeInterval {
        deadline.map { max(0, $0 - now()) } ?? remaining
    }

    func setHovered(_ hovered: Bool) {
        guard state == .thumbnail, isHovered != hovered else { return }
        isHovered = hovered
        refreshCountdown()
    }

    func setInteracting(_ interacting: Bool) {
        guard state == .thumbnail, isInteracting != interacting else { return }
        isInteracting = interacting
        refreshCountdown()
    }

    private func refreshCountdown() {
        if isHovered || isInteracting, let deadline {
            remaining = max(0, deadline - now())
            self.deadline = nil
        } else if !isHovered, !isInteracting, countdownEnabled, deadline == nil {
            deadline = now() + remaining
        }
    }

    /// Returns true exactly once when an untouched thumbnail should be saved.
    func tick() -> Bool {
        guard state == .thumbnail, let deadline, now() >= deadline else { return false }
        return beginSave()
    }

    @discardableResult
    func openPreview() -> Bool {
        guard state == .thumbnail else { return false }
        deadline = nil
        countdownEnabled = false
        remaining = 0
        state = .preview
        return true
    }

    @discardableResult
    func beginSave() -> Bool {
        guard state == .thumbnail || state == .preview else { return false }
        saveReturnState = state
        state = .saving
        deadline = nil
        countdownEnabled = false
        remaining = 0
        return true
    }

    func saveFailed() {
        guard state == .saving else { return }
        state = saveReturnState
        // An error needs an explicit retry; do not auto-save repeatedly to a failed destination.
        deadline = nil
        remaining = 0
    }

    func saved() {
        guard state == .saving else { return }
        state = .resolved
        deadline = nil
        countdownEnabled = false
    }

    @discardableResult
    func discard() -> Bool {
        guard state != .saving, state != .resolved else { return false }
        state = .resolved
        deadline = nil
        countdownEnabled = false
        remaining = 0
        return true
    }
}
