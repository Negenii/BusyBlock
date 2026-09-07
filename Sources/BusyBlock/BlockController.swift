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
                let secs = self?.config.pollIntervalSec ?? 2
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

    func pollOnce() async {
        do {
            let snap = try await client.fetchSnapshot()
            failures = 0
            lastError = nil
            apply(BlockDecision.evaluate(snapshot: snap, config: config, now: Date()))
        } catch {
            failures += 1
            lastError = String(describing: error)
            if failures >= maxFailures {
                apply(BlockDecision.evaluate(snapshot: nil, config: config, now: Date()))
            }
        }
    }

    private func apply(_ new: BlockState) {
        let old = state
        // endsAt drifts by poll jitter; treat sub-second differences as equal.
        var cmp = new
        if let a = old.endsAt, let b = new.endsAt, abs(a.timeIntervalSince(b)) < 1.5 { cmp.endsAt = a }
        guard cmp != old else { return }
        state = new
        onChange?(old, new)
    }
}
