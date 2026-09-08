// BusyBlock service worker: polls the helper on 127.0.0.1 and keeps the
// declarativeNetRequest rules in step with it.
// Chrome runs this as a service worker (shared.js via importScripts);
// Firefox/Safari load shared.js first through background.scripts.
if (typeof shouldBlock === "undefined" && typeof importScripts === "function") importScripts("shared.js");

const api = typeof browser !== "undefined" ? browser : chrome;
const SYNC_ALARM = "busyblock-sync";
const ALARM_MINUTES = 0.5;      // Chrome's floor; setInterval covers the gap while awake
const LIVE_POLL_MS = 1000;   // loopback; the helper itself reacts to bar events instantly

let lastState = null;
let port = DEFAULT_PORT;
let fetchSeq = 0;          // sync() calls overlap (interval, alarm, content scripts); ignore stale responses
let inflight = null;       // the one request in flight (declared before schedule() runs below)
let appliedKey = null;     // last [blocking, domains, port] written to the browser's rules
const IS_SAFARI = api.runtime.getURL("").startsWith("safari-web-extension://");
api.runtime.onInstalled.addListener(schedule);
api.runtime.onStartup.addListener(schedule);
api.alarms.onAlarm.addListener((a) => { if (a.name === SYNC_ALARM) sync(); });
schedule();
setInterval(sync, LIVE_POLL_MS);

function schedule() {
  api.alarms.create(SYNC_ALARM, { periodInMinutes: ALARM_MINUTES });
  sync();
}

async function fetchState() {
  // Hard timeout: a stuck connection pool must not freeze sync() forever.
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 3000);
  try {
    const res = await fetch(stateURL(port), { cache: "no-store", signal: ctl.signal });
    if (!res.ok) throw new Error("helper responded " + res.status);
    return await res.json();
  } finally {
    clearTimeout(timer);
  }
}

function sync() {
  // Coalesce: interval, alarm and content scripts all call this; one request at
  // a time. A request that neither resolves nor aborts (seen in Safari after the
  // background was suspended mid-fetch) must not pin every later sync, so the
  // slot frees itself after 3.5 s regardless.
  if (inflight) return inflight;
  const slot = Promise.race([
    syncNow(),
    new Promise((resolve) => setTimeout(() => resolve(lastState), 3500)),
  ]).catch(() => lastState).finally(() => { if (inflight === slot) inflight = null; });
  inflight = slot;
  return slot;
}

async function syncNow() {
  const seq = ++fetchSeq;
  try {
    const state = await fetchState();
    if (seq !== fetchSeq) return lastState;   // a newer response already landed
    await applyState(state);
    return state;
  } catch (_) {
    if (seq !== fetchSeq) return lastState;
    // Helper not running: fail open.
    await applyState(offlineState());
    return null;
  }
}

// Diagnostics to the helper's log (it only accepts extension origins).
function report(msg) {
  // `page` lets the helper's /go page hop straight to blocked.html even when
  // the browser doesn't inject our content script on 127.0.0.1 (Safari after
  // a reinstall, until the site permission is granted again).
  fetch("http://127.0.0.1:" + port + "/log", { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ msg, page: api.runtime.getURL("blocked.html") }) }).catch(() => {});
}
report("worker started");
let lastReport = "";
let lastReportAt = 0;
globalThis.onRulesError = (e) => report("rules error: " + (e && e.message || e));

async function applyState(state) {
  const changed = JSON.stringify(state) !== JSON.stringify(lastState);
  lastState = state;
  updateBadge(state);
  try {
    await updateRules(state);
    const n = (await api.declarativeNetRequest.getDynamicRules()).length;
    const line = "rules=" + n + " blocking=" + state.isBlocking + " domains=" + (state.domains || []).length;
    // Also a heartbeat every 15 s: a restarted helper must relearn our page URL.
    if (line !== lastReport || Date.now() - lastReportAt > 15000) { lastReport = line; lastReportAt = Date.now(); report(line); }
  } catch (e) {
    report("rules error: " + (e && e.message || e));
  }
  if (changed) {
    api.runtime.sendMessage({ type: "stateUpdated", state }).catch(() => {});
    enforceOpenTabs(state);
  }
}

function updateBadge(state) {
  if (!api.action || !api.action.setBadgeText) return;
  api.action.setBadgeText({ text: state.isBlocking ? "ON" : "" });
  if (api.action.setBadgeBackgroundColor) api.action.setBadgeBackgroundColor({ color: "#E5484D" });
}

function updateRules(state) {
  const key = JSON.stringify([state.isBlocking, state.domains, port]);
  if (key === appliedKey) return Promise.resolve();
  return applyRules(api, state, port).then(() => { appliedKey = key; });
}

// Rules only fire on navigation; tabs already sitting on a blocked site get moved.
function enforceOpenTabs(state) {
  const page = api.runtime.getURL("blocked.html");
  api.tabs.query({ url: ["http://*/*", "https://*/*"] }).then((tabs) => {
    for (const tab of tabs) {
      if (tab.id === undefined || !tab.url) continue;
      if (!state.isBlocking || !shouldBlock(tab.url, state)) continue;
      api.tabs.update(tab.id, { url: page + "?u=" + encodeURIComponent(tab.url) }).catch(() => {});
    }
  }).catch(() => {});
}

api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const type = message && message.type;
  // Answer within 4 s no matter what the helper fetch does.
  const bounded = (p) => Promise.race([p, new Promise((r) => setTimeout(() => r(null), 4000))]);
  if (type === "getState") {
    bounded(sync()).then((s) => sendResponse(s || lastState || offlineState()));
    return true;
  }
  if (type === "shouldBlock") {
    bounded(sync()).then((s) => sendResponse({ block: shouldBlock(message.url, s || lastState), page: api.runtime.getURL("blocked.html") }));
    return true;
  }
  return false;
});
