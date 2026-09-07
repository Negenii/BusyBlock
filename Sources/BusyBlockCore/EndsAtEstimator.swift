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
    /// True once the offset came from a live bar clock reading (stream envelope
    /// or /api/time) rather than from a snapshot that may have been stale.
    public private(set) var calibrated = false
    private var lastTimestampMs: Int?
    private var tracker = EndsAtTracker()
    /// A jump this large means the bar's clock was set, not measurement noise.
    public var clockJumpTolerance: TimeInterval = 30

    public init() {}

    /// Authoritative bar clock reading: the ws envelope timestamp (ms) or
    /// `/api/time` (whole seconds, pass `resolution: 1`). Network latency only
    /// makes `macNow - bar` larger, so the smallest reading wins; a reading
    /// clearly later than the kept one means the bar's clock moved or drifted.
    public mutating func observeBarClock(barMs: Int, macNow: Date, resolution: TimeInterval = 0.001) {
        let observed = macNow.timeIntervalSince1970 - Double(barMs) / 1000 - resolution / 2
        if let off = clockOffset, calibrated {
            if observed < off || observed - off > 2 { clockOffset = observed }
        } else {
            clockOffset = observed
        }
        calibrated = true
    }

    public mutating func update(snapshot s: BusySnapshot, macNow: Date) -> Date? {
        var capturedAt = macNow
        if let ts = s.timestampMs {
            let barTime = Double(ts) / 1000
            let observed = macNow.timeIntervalSince1970 - barTime
            if calibrated {
                // A snapshot can be arbitrarily stale; it says nothing about the clock.
            } else if let off = clockOffset, abs(observed - off) <= clockJumpTolerance {
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
