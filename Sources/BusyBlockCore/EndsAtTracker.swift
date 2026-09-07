import Foundation

/// The bar reports time left in whole seconds, refreshed once per tick, so
/// `now + timeLeft` overestimates the end by up to a second and jitters with
/// every poll. Within one phase the true end never moves later, so the
/// earliest estimate seen is the best one. Keep it until the phase changes or
/// the estimate jumps clearly later (timer restarted or extended).
public struct EndsAtTracker: Equatable {
    public private(set) var phaseKey: String?
    public private(set) var endsAt: Date?
    /// A candidate this much later than the kept value means a new timer, not jitter.
    public var restartTolerance: TimeInterval = 2.5

    public init() {}

    /// Returns the end to publish for this poll.
    public mutating func update(candidate: Date?, phaseKey key: String) -> Date? {
        guard let candidate else {
            phaseKey = key
            endsAt = nil
            return nil
        }
        if key != phaseKey || endsAt == nil {
            phaseKey = key
            endsAt = candidate
            return candidate
        }
        let kept = endsAt!
        if candidate < kept {
            endsAt = candidate
        } else if candidate.timeIntervalSince(kept) > restartTolerance {
            endsAt = candidate
        }
        return endsAt
    }

    public mutating func reset() {
        phaseKey = nil
        endsAt = nil
    }
}

extension BusySnapshot {
    /// Identifies a run of one phase: kind + interval index + pause flag.
    /// Pausing and resuming starts a fresh tracking run.
    public var phaseKey: String {
        "\(kind.rawValue)|\(currentInterval ?? -1)|\(isPaused)"
    }
}
