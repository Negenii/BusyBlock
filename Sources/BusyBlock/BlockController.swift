import Foundation
import Combine
import BusyBlockCore

/// Polls the bar and turns snapshots into a published `BlockState`.
@MainActor
final class BlockController: ObservableObject {
    @Published private(set) var state: BlockState
    @Published private(set) var lastError: String?

    private(set) var config: Config
    private let client: BarClient
    private var loop: Task<Void, Never>?
    private var failures = 0
    private var estimator = EndsAtEstimator()
    /// While the ws stream delivers timer events, polling is only a safety net.
    var streamConnected = false
    private let maxFailures = 3
    var onChange: ((BlockState, BlockState) -> Void)?

    init(config: Config) {
        self.config = config
        self.client = BarClient(config: config)
        self.state = .offline(domains: config.blockedDomains)
    }

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                let secs = (self?.streamConnected ?? false) ? 10 : (self?.config.pollIntervalSec ?? 2)
                try? await Task.sleep(nanoseconds: UInt64(max(0.5, secs) * 1_000_000_000))
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    func reload(config new: Config) {
        let hostChanged = new.barHost != config.barHost || new.barToken != config.barToken
        config = new
        client.update(config: new)
        if hostChanged { failures = 0 }
        // Re-evaluate with the new lists right away.
        var s = state
        s.domains = new.blockedDomains
        apply(s)
        Task { await pollOnce() }
    }

    /// Bar clock reading (ms) from the websocket envelope or /api/time.
    func calibrate(barMs: Int, receivedAt: Date, resolution: TimeInterval = 0.001) {
        estimator.observeBarClock(barMs: barMs, macNow: receivedAt, resolution: resolution)
    }

    private var lastTimeSync = Date.distantPast

    /// Without the stream the only clock source is /api/time (1 s resolution).
    private func syncClockIfNeeded() async {
        guard !streamConnected, Date().timeIntervalSince(lastTimeSync) > 300 else { return }
        lastTimeSync = Date()
        let sent = Date()
        if let ms = try? await client.fetchBarTimeMs() {
            let mid = sent.addingTimeInterval(Date().timeIntervalSince(sent) / 2)
            calibrate(barMs: ms, receivedAt: mid, resolution: 1)
        }
    }

    /// Timer state pushed by the bar over the websocket.
    func ingest(snapshot: BusySnapshot, receivedAt: Date) {
        failures = 0
        lastError = nil
        var decided = BlockDecision.evaluate(snapshot: snapshot, config: config, now: receivedAt)
        decided.endsAt = estimator.update(snapshot: snapshot, macNow: receivedAt)
        apply(decided)
    }

    func pollOnce() async {
        await syncClockIfNeeded()
        do {
            let sent = Date()
            let snap = try await client.fetchSnapshot()
            // The bar sampled its clock roughly mid-flight.
            let now = sent.addingTimeInterval(Date().timeIntervalSince(sent) / 2)
            failures = 0
            lastError = nil
            var decided = BlockDecision.evaluate(snapshot: snap, config: config, now: now)
            decided.endsAt = estimator.update(snapshot: snap, macNow: now)
            apply(decided)
        } catch {
            failures += 1
            lastError = String(describing: error)
            if failures >= maxFailures {
                estimator.reset()
                apply(BlockDecision.evaluate(snapshot: nil, config: config, now: Date()))
            }
        }
    }

    private func apply(_ new: BlockState) {
        let old = state
        guard new != old else { return }
        state = new
        onChange?(old, new)
    }
}
