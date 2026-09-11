import Foundation

/// How much time is left, written the way the bar's own screen writes it:
/// `MM:SS` under an hour, `H:MM:SS` over it. Both minutes and seconds are
/// padded, so the text keeps its width from one second to the next instead of
/// jittering in the menu bar.
public enum Countdown {
    public static func text(seconds: Int) -> String {
        let total = max(0, seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }

    /// Whole seconds left, rounded the way the bar rounds them: with 58.4 s to
    /// go the bar reads 59, so BusyBlock has to read 59 too.
    public static func secondsLeft(until end: Date, now: Date = Date()) -> Int {
        max(0, Int((end.timeIntervalSince(now) - 0.05).rounded(.up)))
    }

    public static func text(until end: Date, now: Date = Date()) -> String {
        text(seconds: secondsLeft(until: end, now: now))
    }
}
