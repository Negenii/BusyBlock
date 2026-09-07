import Foundation

public enum BlockDecision {
    /// Pure mapping from the bar snapshot (nil = unreachable) to the block state.
    /// Fail-open: no bar, no blocking.
    public static func evaluate(snapshot: BusySnapshot?, config: Config, now: Date) -> BlockState {
        let domains = config.blockedDomains
        let screen = config.showScreenInBrowser
        guard let s = snapshot else { return .offline(domains: domains, showScreen: screen) }

        let endsAt = s.phaseTimeLeftMs.map { now.addingTimeInterval(Double($0) / 1000) }
        switch s.kind {
        case .notStarted:
            return BlockState(isBlocking: false, endsAt: nil, paused: false, barConnected: true,
                              phase: "idle", domains: domains, showScreen: screen)
        case .simple, .infinite:
            return BlockState(isBlocking: !s.isPaused, endsAt: endsAt, paused: s.isPaused,
                              barConnected: true, phase: "work", domains: domains, showScreen: screen)
        case .interval:
            let rest = s.isRestPhase
            let blocking = !s.isPaused && (!rest || config.blockDuringRest)
            return BlockState(isBlocking: blocking, endsAt: endsAt, paused: s.isPaused,
                              barConnected: true, phase: rest ? "rest" : "work", domains: domains, showScreen: screen)
        }
    }
}
