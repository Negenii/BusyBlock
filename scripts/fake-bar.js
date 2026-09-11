#!/usr/bin/env node
// Fake BUSY Bar for local testing: serves /api/busy/snapshot like the firmware.
//   node scripts/fake-bar.js [port]            (default 8090)
//   curl -X PUT localhost:8090/scenario -d '{"name":"simple"}'
//   scenarios: idle | simple | long | paused | infinite | interval-work | interval-rest
// Scenarios: idle | simple | interval-work | interval-rest | paused | infinite
const http = require("node:http");
const port = Number(process.argv[2] || 8090);
let scenario = process.argv[3] || "idle";
let startedAt = Date.now();
// Stock firmware serves a cached snapshot that only refreshes on user actions
// (start, pause, phase change). Pass --live to emulate the VeryBUSY patch that
// captures live state on every request.
const live = process.argv.includes("--live");
let cached = null;
const WORK = 25 * 60 * 1000, REST = 5 * 60 * 1000;
const secs = (ms) => Math.max(0, Math.floor(ms / 1000) * 1000); // firmware reports whole seconds
const settings = { theme: "on_air", show_work_phase_only: false, trigger_smart_home: true };
const interval_settings = { type: "INTERVAL", interval_work_ms: WORK, interval_rest_ms: REST, interval_work_cycles_count: 4, is_autostart_enabled: false };

function snapshot() {
  const elapsed = Date.now() - startedAt;
  const card_id = "00000000-0000-0000-0000-000000000001";
  switch (scenario) {
    case "simple": return { type: "SIMPLE", card_id, time_left_ms: secs(WORK - elapsed), is_paused: false };
    case "paused": return { type: "SIMPLE", card_id, time_left_ms: 10 * 60 * 1000, is_paused: true };
    case "infinite": return { type: "INFINITE", card_id, is_paused: false };
    // Over an hour, where the bar's own screen switches to h:mm:ss.
    case "long": return { type: "SIMPLE", card_id, time_left_ms: secs(90 * 60 * 1000 - elapsed), is_paused: false };
    case "interval-work": return { type: "INTERVAL", card_id, current_interval: 0, current_interval_time_total_ms: WORK, current_interval_time_left_ms: secs(WORK - elapsed), is_paused: false, interval_settings };
    case "interval-rest": return { type: "INTERVAL", card_id, current_interval: 1, current_interval_time_total_ms: REST, current_interval_time_left_ms: secs(REST - elapsed), is_paused: false, interval_settings };
    default: return { type: "NOT_STARTED" };
  }
}

http.createServer((req, res) => {
  const json = (code, obj) => { res.writeHead(code, { "Content-Type": "application/json" }); res.end(JSON.stringify(obj)); };
  if (req.method === "GET" && req.url === "/api/busy/snapshot") {
    if (live || !cached) cached = { snapshot: { ...snapshot(), busy_bar_settings: settings }, snapshot_timestamp_ms: Date.now() };
    return json(200, cached);
  }
  if (req.method === "PUT" && req.url === "/scenario") {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      try { scenario = JSON.parse(body).name; startedAt = Date.now(); cached = null; json(200, { ok: true, scenario }); }
      catch { json(400, { error: "bad json" }); }
    });
    return;
  }
  if (req.method === "GET" && req.url === "/scenario") return json(200, { scenario });
  json(404, { error: "not found" });
}).listen(port, "127.0.0.1", () => console.log(`fake bar on http://127.0.0.1:${port} scenario=${scenario}`));
