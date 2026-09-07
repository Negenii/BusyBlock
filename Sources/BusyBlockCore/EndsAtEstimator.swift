import Foundation

/// Turns bar snapshots into a stable end-of-phase time on the Mac's clock.
///
/// Stock firmware answers `/api/busy/snapshot` with a cached snapshot that is
/// refreshed only on user actions, so `time_left_ms` can sit unchanged for
/// minutes while the timer runs. `snapshot_timestamp_ms` says when it was
/// captured, on the bar's clock. The end is therefore
/// `capturedAt + timeLeft`, with `capturedAt` translated to Mac time through an
/// estimated clock offset. The offset is the smallest `macNow - timestamp`
/// seen for a fresh snapshot: the sooner we polled after a capture, the closer
/// that is to the truth. `EndsAtTracker` on top keeps the result monotonic.
public struct EndsAtEstimator: Equatable {
    /// macNow - barTimestamp, seconds.
    public private(set) var clockOffset: TimeInterval?
    private var lastTimestampMs: Int?
    private var tracker = EndsAtTracker()
    /// A jump this large means the bar's clock was set, not measurement noise.
    public var clockJumpTolerance: TimeInterval = 30

    public init() {}

    public mutating func update(snapshot s: BusySnapshot, macNow: Date) -> Date? {
        var capturedAt = macNow
        if let ts = s.timestampMs {
            let barTime = Double(ts) / 1000
            let observed = macNow.timeIntervalSince1970 - barTime
            if let off = clockOffset, abs(observed - off) <= clockJumpTolerance {
                // Fresh snapshot seen sooner than any before → better offset.
                if ts != lastTimestampMs, observed < off { clockOffset = observed }
            } else {
                clockOffset = observed
            }
            lastTimestampMs = ts
            capturedAt = Date(timeIntervalSince1970: barTime + clockOffset!)
        }
        let candidate = s.phaseTimeLeftMs.map { capturedAt.addingTimeInterval(Double($0) / 1000) }
        return tracker.update(candidate: candidate, phaseKey: s.phaseKey)
    }

    public mutating func reset() {
        tracker.reset()
        lastTimestampMs = nil
    }
}
