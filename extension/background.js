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

let lastContact = 0;   // when the helper last answered
async function syncNow() {
  const seq = ++fetchSeq;
  try {
    const state = await fetchState();
    if (seq !== fetchSeq) return lastState;   // a newer response already landed
    lastContact = Date.now();
    await applyState(state);
    return state;
  } catch (_) {
    if (seq !== fetchSeq) return lastState;
    // Helper gone: hold the known session to its end, then release.
    const held = stateAfterHelperLoss(lastState, Date.now(), lastContact || Date.now());
    await applyState(held);
    return held.isBlocking ? held : null;
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
  const down = !!state.helperDown;
  api.action.setBadgeText({ text: down ? "!" : state.isBlocking ? "ON" : "" });
  if (api.action.setBadgeBackgroundColor) api.action.setBadgeBackgroundColor({ color: down ? "#F0A020" : "#E5484D" });
}

function updateRules(state) {
  const key = JSON.stringify([state.isBlocking, state.domains, port]);
  if (key === appliedKey) return Promise.resolve();
  return applyRules(api, state, port).then(() => { appliedKey = key; });
}

// Safari: the rules only block the main frame (see rulesFor), so a blocked
// site leaves a blank tab. The worker moves that tab to the block page.
//
// Two things make this fiddly. Safari preloads the address bar's top hit in a
// hidden tab, and hopping a hidden tab makes it preload again, forever — so
// only the tab in front of the person is ever moved. And a tab whose load was
// blocked sometimes reports no URL at all, so the URL seen in the navigation
// event is remembered and used when the tab itself can't say where it went.
const hopped = new Map();   // url -> when a tab was last moved away from it
const pending = new Map();  // tabId -> url whose load we blocked
let hopTimes = [];          // brake against any loop the throttles miss

function rememberBlocked(tabId, url) {
  if (tabId === undefined || !url || !/^https?:/.test(url)) return;
  if (!lastState || !lastState.isBlocking || !shouldBlock(url, lastState)) return;
  pending.set(tabId, url);
  const now = Date.now();
  for (const [id, u] of pending) if (typeof u !== "string") pending.delete(id);
  if (pending.size > 50) pending.clear();
  hopTimes = hopTimes.filter((t) => now - t < 5000);
}

function hopIfBlocked(tabId, url, why, allowInactive) {
  const target = url && /^https?:/.test(url) ? url : pending.get(tabId);
  if (!target) return;
  const now = Date.now();
  if (now - (hopped.get(target) || 0) < 2000) return;
  hopTimes = hopTimes.filter((t) => now - t < 5000);
  if (hopTimes.length >= 8) { if (hopTimes.length === 8) { hopTimes.push(now); report("hop brake: too many hops, pausing"); } return; }
  const decide = async (s) => {
    if (!s || !s.isBlocking || !shouldBlock(target, s)) return;
    let tab = null;
    try { tab = await api.tabs.get(tabId); } catch (_) { return; }
    if (!tab || (!tab.active && !allowInactive)) return;   // hidden tab: a preload, leave it alone
    if (tab.url && !shouldBlock(tab.url, s)) return;       // already moved on
    if (Date.now() - (hopped.get(target) || 0) < 2000) return;   // several events land per visit
    hopped.set(target, Date.now());
    hopTimes.push(Date.now());
    pending.delete(tabId);
    report("hop " + why + " tab=" + tabId + " " + target.slice(0, 80));
    api.tabs.update(tabId, { url: api.runtime.getURL("blocked.html") + "?u=" + encodeURIComponent(target) }).catch(() => {});
  };
  if (lastState) decide(lastState); else Promise.race([sync(), new Promise((r) => setTimeout(() => r(null), 4000))]).then(decide);
}

// Last resort: every second, look at the tab in front of the person. Covers
// the paths that fire no usable event, above all a preloaded top hit that
// Safari swaps in when Return is pressed.
function sweepActiveTabs() {
  if (!lastState || !lastState.isBlocking) return;
  api.tabs.query({ active: true }).then((tabs) => {
    for (const tab of tabs) if (tab.id !== undefined) hopIfBlocked(tab.id, tab.url || "", "sweep");
  }).catch(() => {});
}

if (IS_SAFARI) {
  api.tabs.onUpdated.addListener((tabId, info, tab) => {
    const url = info.url || (tab && tab.url) || "";
    rememberBlocked(tabId, url);
    if (info.url || info.status === "complete") hopIfBlocked(tabId, url, "onUpdated");
  });
  api.tabs.onActivated.addListener((info) => {
    api.tabs.get(info.tabId).then((tab) => hopIfBlocked(tab.id, tab.url || "", "onActivated")).catch(() => {});
  });
  api.tabs.onRemoved.addListener((tabId) => pending.delete(tabId));
  if (api.webNavigation) {
    api.webNavigation.onBeforeNavigate.addListener((d) => { if (d.frameId === 0) rememberBlocked(d.tabId, d.url); });
    api.webNavigation.onErrorOccurred.addListener((d) => { if (d.frameId === 0) { rememberBlocked(d.tabId, d.url); hopIfBlocked(d.tabId, d.url, "onErrorOccurred"); } });
  }
  setInterval(sweepActiveTabs, 1000);
}

// Rules only fire on navigation; tabs already sitting on a blocked site get moved.
function enforceOpenTabs(state) {
  const page = api.runtime.getURL("blocked.html");
  api.tabs.query({ url: ["http://*/*", "https://*/*"] }).then((tabs) => {
    for (const tab of tabs) {
      if (tab.id === undefined || !tab.url) continue;
      if (!state.isBlocking || !shouldBlock(tab.url, state)) continue;
      // Safari: go through the throttled path, so a hidden tab Safari keeps
      // reloading can't turn this into a loop.
      if (IS_SAFARI) { hopIfBlocked(tab.id, tab.url, "openTab", true); continue; }
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
