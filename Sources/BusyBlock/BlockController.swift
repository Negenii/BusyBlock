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
    /// Host actually in use (configured or discovered) and how it was found.
    @Published private(set) var activeHost: String
    @Published private(set) var foundVia: BarLocator.Via = .configured
    @Published private(set) var needsToken = false
    /// Called when discovery switches hosts, so the stream can follow.
    var onHostChange: ((String) -> Void)?
    @Published private(set) var discovering = false
    /// True after a discovery round found nothing (until the next round starts).
    @Published private(set) var searchFailed = false
    private var lastDiscovery = Date.distantPast
    private var everConnected = false
    private var lastPreferredCheck = Date.distantPast
    private let maxFailures = 3
    var onChange: ((BlockState, BlockState) -> Void)?

    init(config: Config) {
        self.config = config
        self.client = BarClient(config: config)
        self.activeHost = config.barHost
        self.state = .offline(domains: config.blockedDomains, showScreen: config.showScreenInBrowser)
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
        if hostChanged {
            failures = 0
            activeHost = new.barHost
            foundVia = .configured
            needsToken = false
            lastDiscovery = .distantPast
            onHostChange?(new.barHost)
        }
        // Re-evaluate with the new lists right away.
        var s = state
        s.domains = new.blockedDomains
        s.showScreen = new.showScreenInBrowser
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
        guard !streamConnected, failures == 0, Date().timeIntervalSince(lastTimeSync) > 300 else { return }
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
        everConnected = true
        lastError = nil
        var decided = BlockDecision.evaluate(snapshot: snapshot, config: config, now: receivedAt)
        decided.endsAt = estimator.update(snapshot: snapshot, macNow: receivedAt)
        apply(decided)
    }

    /// On a discovered host (say Wi-Fi), keep checking whether the configured
    /// one (say USB) is back, and return to it when it is.
    private func returnToConfiguredHostIfBack() async {
        guard foundVia != .configured, Date().timeIntervalSince(lastPreferredCheck) > 60 else { return }
        lastPreferredCheck = Date()
        let configured = config.barHost, token = config.barToken
        guard !configured.trimmingCharacters(in: .whitespaces).isEmpty, configured != activeHost else { return }
        let probe = await Task.detached(priority: .utility) { BarLocator.probe(host: configured, token: token) }.value
        guard probe == .ok else { return }
        activeHost = configured
        foundVia = .configured
        needsToken = false
        client.use(host: configured)
        onHostChange?(configured)
    }

    func pollOnce() async {
        await returnToConfiguredHostIfBack()
        await syncClockIfNeeded()
        do {
            let sent = Date()
            let snap = try await client.fetchSnapshot()
            // The bar sampled its clock roughly mid-flight.
            let now = sent.addingTimeInterval(Date().timeIntervalSince(sent) / 2)
            failures = 0
            everConnected = true
            lastError = nil
            var decided = BlockDecision.evaluate(snapshot: snap, config: config, now: now)
            decided.endsAt = estimator.update(snapshot: snap, macNow: now)
            apply(decided)
        } catch {
            failures += 1
            lastError = String(describing: error)
            // A bar that never answered gets searched for right away; one that
            // just dropped out gets three chances first (USB re-enumeration etc.).
            if failures >= maxFailures || !everConnected {
                estimator.reset()
                apply(BlockDecision.evaluate(snapshot: nil, config: config, now: Date()))
                await discoverIfNeeded()
            }
        }
    }

    /// The configured host is silent: try USB, busybar.local, Bonjour. Runs at
    /// most every 20 s while offline, off the main thread.
    private func discoverIfNeeded() async {
        guard config.autoDiscover, !discovering, !streamConnected,
              Date().timeIntervalSince(lastDiscovery) > 20 else { return }
        discovering = true
        lastDiscovery = Date()
        let configured = config.barHost, token = config.barToken
        let found = await Task.detached(priority: .utility) {
            BarLocator.locate(configured: configured, token: token)
        }.value
        discovering = false
        searchFailed = (found == nil)
        guard let found else { return }
        needsToken = found.needsToken
        if found.host != activeHost {
            activeHost = found.host
            foundVia = found.via
            client.use(host: found.host)
            failures = 0
            onHostChange?(found.host)
        } else {
            foundVia = found.via
        }
    }

    private func apply(_ incoming: BlockState) {
        var new = incoming
        new.host = activeHost
        new.via = foundVia.rawValue
        let old = state
        guard new != old else { return }
        state = new
        onChange?(old, new)
    }
}
