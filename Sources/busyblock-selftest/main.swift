import Foundation
import BusyBlockCore

// `busyblock-selftest --fetch 10.0.4.20` does one live GET and prints the result.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--fetch" {
    let started = Date()
    do {
        let data = try RawHTTPClient.get(host: CommandLine.arguments[2], path: "/api/busy/snapshot")
        let snap = try BusySnapshot.decode(data)
        print("ok in \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(snap.kind.rawValue) paused=\(snap.isPaused) left=\(snap.phaseTimeLeftMs ?? -1)")
        exit(0)
    } catch {
        print("error after \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(error)")
        exit(2)
    }
}

var failures = 0
var checks = 0
func check(_ cond: @autoclosure () -> Bool, _ name: String, file: String = #file, line: Int = #line) {
    checks += 1
    if !cond() { failures += 1; print("FAIL: \(name) (\(file):\(line))") }
}

let now = Date(timeIntervalSince1970: 1_700_000_000)
let cfg = Config(blockedDomains: ["youtube.com", "x.com"])

// MARK: snapshot decoding
do {
    let json = #"{"snapshot":{"type":"SIMPLE","card_id":"0","time_left_ms":9000,"is_paused":false,"busy_bar_settings":{"theme":"on_air","show_work_phase_only":false,"trigger_smart_home":true}},"snapshot_timestamp_ms":1}"#
    let s = try BusySnapshot.decode(Data(json.utf8))
    check(s.kind == .simple && s.timeLeftMs == 9000 && !s.isPaused, "decode SIMPLE")
    check(s.timestampMs == 1, "decode snapshot_timestamp_ms")
    check(s.phaseTimeLeftMs == 9000, "SIMPLE phase time")

    let interval = #"{"snapshot":{"type":"INTERVAL","card_id":"0","current_interval":1,"current_interval_time_total_ms":60000,"current_interval_time_left_ms":42690,"is_paused":true,"interval_settings":{"type":"INTERVAL","interval_work_ms":120000,"interval_rest_ms":60000,"interval_work_cycles_count":3,"is_autostart_enabled":false}}}"#
    let i = try BusySnapshot.decode(Data(interval.utf8))
    check(i.kind == .interval && i.isRestPhase && i.isPaused && i.phaseTimeLeftMs == 42690, "decode INTERVAL rest paused")

    let inf = try BusySnapshot.decode(Data(#"{"snapshot":{"type":"INFINITE","card_id":"0","is_paused":false}}"#.utf8))
    check(inf.kind == .infinite && inf.phaseTimeLeftMs == nil, "decode INFINITE")

    let ns = try BusySnapshot.decode(Data(#"{"type":"NOT_STARTED"}"#.utf8))
    check(ns.kind == .notStarted, "decode bare NOT_STARTED")

    check((try? BusySnapshot.decode(Data(#"{"snapshot":{"type":"WEIRD"}}"#.utf8))) == nil, "unknown type throws")
} catch { failures += 1; print("FAIL: decoding threw \(error)") }

// MARK: block decision
do {
    let off = BlockDecision.evaluate(snapshot: nil, config: cfg, now: now)
    check(!off.isBlocking && !off.barConnected && off.phase == "offline" && off.domains == cfg.blockedDomains, "offline fails open")

    let idle = BlockDecision.evaluate(snapshot: BusySnapshot(kind: .notStarted), config: cfg, now: now)
    check(!idle.isBlocking && idle.barConnected && idle.phase == "idle", "not started = idle")

    let simple = BlockDecision.evaluate(snapshot: BusySnapshot(kind: .simple, timeLeftMs: 60_000), config: cfg, now: now)
    check(simple.isBlocking && simple.endsAt == now.addingTimeInterval(60) && simple.phase == "work", "simple blocks with endsAt")

    let paused = BlockDecision.evaluate(snapshot: BusySnapshot(kind: .simple, isPaused: true, timeLeftMs: 60_000), config: cfg, now: now)
    check(!paused.isBlocking && paused.paused, "paused does not block")

    let inf = BlockDecision.evaluate(snapshot: BusySnapshot(kind: .infinite), config: cfg, now: now)
    check(inf.isBlocking && inf.endsAt == nil, "infinite blocks without endsAt")

    let work = BlockDecision.evaluate(snapshot: BusySnapshot(kind: .interval, currentInterval: 2, currentIntervalTimeLeftMs: 5000), config: cfg, now: now)
    check(work.isBlocking && work.phase == "work", "interval even = work")

    let rest = BlockDecision.evaluate(snapshot: BusySnapshot(kind: .interval, currentInterval: 1, currentIntervalTimeLeftMs: 5000), config: cfg, now: now)
    check(!rest.isBlocking && rest.phase == "rest", "interval odd = rest, not blocking")

    var restCfg = cfg; restCfg.blockDuringRest = true
    let restBlock = BlockDecision.evaluate(snapshot: BusySnapshot(kind: .interval, currentInterval: 1, currentIntervalTimeLeftMs: 5000), config: restCfg, now: now)
    check(restBlock.isBlocking && restBlock.phase == "rest", "blockDuringRest blocks rest")
}

// MARK: wire JSON
do {
    let s = BlockDecision.evaluate(snapshot: BusySnapshot(kind: .simple, timeLeftMs: 1000), config: cfg, now: now)
    let obj = try JSONSerialization.jsonObject(with: s.wireJSON()) as? [String: Any]
    check(obj?["endsAt"] as? Int == 1_700_000_001_000, "endsAt in ms")
    check(obj?["isBlocking"] as? Bool == true, "isBlocking on wire")
    let off = BlockState.offline(domains: [])
    let offObj = try JSONSerialization.jsonObject(with: off.wireJSON()) as? [String: Any]
    check(offObj?["endsAt"] as? Int == 0, "nil endsAt = 0")
} catch { failures += 1; print("FAIL: wire json \(error)") }

// MARK: config
do {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("busyblock-selftest-\(UUID().uuidString)/config.json")
    var c = Config.defaults
    c.blockedApps = ["com.example.a"]
    c.blockedDomains = ["YouTube.com"]
    c.barToken = "t"
    try c.save(to: tmp)
    let back = try Config.load(from: tmp)
    check(back.blockedApps == ["com.example.a"] && back.barToken == "t", "config roundtrip")
    check(back.blockedDomains == ["youtube.com"], "domains normalised on load")
    let partial = try Config.decode(Data(#"{"barHost":"192.168.1.5","blockedDomains":["https://www.X.com/","bad"]}"#.utf8))
    check(partial.barHost == "192.168.1.5" && partial.localPort == 48321 && partial.blockedDomains == ["x.com"], "partial config gets defaults")
    let created = Config.loadOrCreate(at: tmp.deletingLastPathComponent().appendingPathComponent("new.json"))
    check(created == .defaults, "loadOrCreate writes defaults")
    try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
} catch { failures += 1; print("FAIL: config \(error)") }

// MARK: raw http client
do {
    check(RawHTTPClient.parseHost("10.0.4.20")! == ("10.0.4.20", 80), "parseHost bare ip")
    check(RawHTTPClient.parseHost("127.0.0.1:8321")! == ("127.0.0.1", 8321), "parseHost with port")
    check(RawHTTPClient.parseHost("http://busy.local:8080/")! == ("busy.local", 8080), "parseHost strips scheme and path")
    check(RawHTTPClient.parseHost("") == nil, "parseHost empty")
    let ok = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}".utf8)
    check((try? RawHTTPClient.parse(ok)) == Data("{}".utf8), "parse 200 body")
    check((try? RawHTTPClient.parse(Data("HTTP/1.1 404 Not Found\r\n\r\n{}".utf8))) == nil, "parse rejects 404")
    check((try? RawHTTPClient.parse(Data("garbage".utf8))) == nil, "parse rejects garbage")
}

// MARK: domains
check(Domain.normalize("https://www.YouTube.com/watch?v=1") == "youtube.com/watch?v=1", "normalize keeps path")
check(Domain.normalize("Twitter.com:443") == "twitter.com", "normalize strips port")
check(Domain.normalize("localhost") == "", "normalize rejects no-dot")
check(Domain.matches(host: "m.youtube.com", path: "/", entry: "youtube.com"), "subdomain matches")
check(!Domain.matches(host: "notyoutube.com", path: "/", entry: "youtube.com"), "suffix without dot does not match")
check(Domain.matches(host: "reddit.com", path: "/r/all", entry: "reddit.com/r"), "path prefix matches")
check(!Domain.matches(host: "reddit.com", path: "/user", entry: "reddit.com/r"), "other path does not match")

// MARK: endsAt tracker
do {
    var t = EndsAtTracker()
    let base = now
    // True end is base+60. Bar reports whole seconds, so a poll just before a
    // tick sees "60" and estimates late; the next poll after the tick sees "59"
    // and lands closer. Estimates never move later inside one phase.
    let key = "SIMPLE|-1|false"
    let e1 = t.update(candidate: base.addingTimeInterval(0.95 + 60), phaseKey: key)
    let e2 = t.update(candidate: base.addingTimeInterval(1.6 + 59), phaseKey: key)
    let e3 = t.update(candidate: base.addingTimeInterval(2.3 + 59), phaseKey: key)
    let e4 = t.update(candidate: base.addingTimeInterval(3.0 + 58), phaseKey: key)
    check(abs(e1!.timeIntervalSince(base.addingTimeInterval(60.95))) < 0.001, "tracker takes first estimate")
    check(abs(e2!.timeIntervalSince(base.addingTimeInterval(60.6))) < 0.001, "earlier estimate wins")
    check(e3 == e2, "later estimate within a phase is ignored")
    check(e4 == e2, "never moves later inside the phase")
    let e5 = t.update(candidate: base.addingTimeInterval(4.02 + 56), phaseKey: key)
    check(abs(e5!.timeIntervalSince(base.addingTimeInterval(60.02))) < 0.001, "poll right after a tick tightens the bound")

    let restarted = t.update(candidate: base.addingTimeInterval(1500), phaseKey: "SIMPLE|-1|false")
    check(restarted == base.addingTimeInterval(1500), "jump > tolerance = restarted timer")

    let rest = t.update(candidate: base.addingTimeInterval(300), phaseKey: "INTERVAL|1|false")
    check(rest == base.addingTimeInterval(300), "new phase key resets")
    let paused = t.update(candidate: base.addingTimeInterval(310), phaseKey: "INTERVAL|1|true")
    check(paused == base.addingTimeInterval(310), "pause is a new key")
    check(t.update(candidate: nil, phaseKey: "INFINITE|-1|false") == nil, "nil candidate clears")

    let s = BusySnapshot(kind: .interval, isPaused: false, currentInterval: 3)
    check(s.phaseKey == "INTERVAL|3|false", "snapshot phaseKey")
}

// MARK: endsAt estimator (stock firmware serves a frozen snapshot)
do {
    var e = EndsAtEstimator()
    let mac0 = now.timeIntervalSince1970
    let barTs = Int((mac0 - 0.5) * 1000)      // captured 0.5 s before our first poll, bar clock == mac clock
    func snap(_ left: Int, ts: Int, paused: Bool = false, interval: Int = 0) -> BusySnapshot {
        BusySnapshot(kind: .interval, isPaused: paused, currentInterval: interval,
                     currentIntervalTimeLeftMs: left, timestampMs: ts)
    }
    // Ten polls of the same frozen snapshot over 20 s: the end must not move.
    var ends: [Date?] = []
    for i in 0..<10 {
        ends.append(e.update(snapshot: snap(1_380_000, ts: barTs), macNow: now.addingTimeInterval(Double(i) * 2)))
    }
    check(Set(ends.map { $0?.timeIntervalSince1970 ?? 0 }).count == 1, "frozen snapshot gives one endsAt")
    check(abs(ends[0]!.timeIntervalSince1970 - (mac0 + 1380)) < 0.001, "first sighting: end = now + left")

    // Pause 19 s in: fresh snapshot, paused → still meaningful end for display.
    let pauseTs = Int((mac0 + 18.5) * 1000)
    let paused = e.update(snapshot: snap(1_361_000, ts: pauseTs, paused: true), macNow: now.addingTimeInterval(19.5))
    check(paused != nil, "paused snapshot still yields an end")

    // Resume: polled 0.1 s after capture → offset improves from 0.5 to 0.1.
    let resumeTs = Int((mac0 + 40) * 1000)
    let resumed = e.update(snapshot: snap(1_361_000, ts: resumeTs), macNow: now.addingTimeInterval(40.1))
    check(abs(e.clockOffset! - 0.1) < 0.001, "clock offset takes the tightest observation")
    check(abs(resumed!.timeIntervalSince1970 - (mac0 + 40.1 + 1361)) < 0.001, "resumed end from capture time")
    // Same frozen snapshot 30 s later: unchanged.
    let later = e.update(snapshot: snap(1_361_000, ts: resumeTs), macNow: now.addingTimeInterval(70))
    check(later == resumed, "frozen snapshot after resume stays put")

    // Bar clock set forward by 2 minutes → offset resets instead of being ignored.
    let jumpTs = Int((mac0 + 200 + 120) * 1000)
    _ = e.update(snapshot: snap(1_200_000, ts: jumpTs, interval: 1), macNow: now.addingTimeInterval(200))
    check(abs(e.clockOffset! - (-120)) < 0.001, "clock jump resets offset")

    // No timestamp at all: falls back to poll time.
    var f = EndsAtEstimator()
    let plain = f.update(snapshot: BusySnapshot(kind: .simple, timeLeftMs: 5000), macNow: now)
    check(plain == now.addingTimeInterval(5), "no timestamp → now + left")

    // Replay of real samples (2026-09-07, stock 1.2.3). The bar's timestamp is
    // constant within a run; runs began when the person pressed pause/start.
    // (t of poll, left ms, run index, paused); run capture times on the bar
    // clock, relative to mac0: 0: -0.538, 1: 18.957, 2: 37.316, 3: 48.869.
    let runTs: [Double] = [-0.538, 18.957, 37.316, 48.869]
    let rows: [(Double, Int, Int, Bool)] = [
        (0.0, 1380000, 0, false), (4.6, 1380000, 0, false), (9.3, 1380000, 0, false),
        (14.4, 1380000, 0, false), (19.0, 1380000, 0, false),
        (19.5, 1361000, 1, true), (29.4, 1361000, 1, true),
        (37.7, 1361000, 2, false), (41.8, 1361000, 2, false), (48.5, 1361000, 2, false),
        (49.0, 1350000, 3, true), (59.9, 1350000, 3, true),
    ]
    var r = EndsAtEstimator()
    var byRun: [Int: Set<Int>] = [:]
    for (t, left, run, paused) in rows {
        let mac = now.addingTimeInterval(t)
        let ts = Int(((mac0 + runTs[run]) * 1000).rounded())
        let end = r.update(snapshot: snap(left, ts: ts, paused: paused), macNow: mac)
        byRun[run, default: []].insert(Int((end!.timeIntervalSince1970 * 1000).rounded()))
    }
    check(byRun.values.allSatisfy { $0.count == 1 }, "replay: end constant within every run")
    check(abs(r.clockOffset! - 0.131) < 0.001, "replay: offset converges to best sighting")
}

if failures == 0 { print("all \(checks) checks passed"); exit(0) }
print("\(failures) of \(checks) checks failed"); exit(1)
