import Foundation
import BusyBlockCore

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

// MARK: domains
check(Domain.normalize("https://www.YouTube.com/watch?v=1") == "youtube.com/watch?v=1", "normalize keeps path")
check(Domain.normalize("Twitter.com:443") == "twitter.com", "normalize strips port")
check(Domain.normalize("localhost") == "", "normalize rejects no-dot")
check(Domain.matches(host: "m.youtube.com", path: "/", entry: "youtube.com"), "subdomain matches")
check(!Domain.matches(host: "notyoutube.com", path: "/", entry: "youtube.com"), "suffix without dot does not match")
check(Domain.matches(host: "reddit.com", path: "/r/all", entry: "reddit.com/r"), "path prefix matches")
check(!Domain.matches(host: "reddit.com", path: "/user", entry: "reddit.com/r"), "other path does not match")

if failures == 0 { print("all \(checks) checks passed"); exit(0) }
print("\(failures) of \(checks) checks failed"); exit(1)
