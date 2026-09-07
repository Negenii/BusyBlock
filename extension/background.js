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
const IS_SAFARI = api.runtime.getURL("").startsWith("safari-web-extension://");
// Last real page URL per tab, so a Safari block page (no ?u=) can still say
// which site it stands in for and return there when the timer ends.
const lastSiteURL = new Map();
api.tabs.onUpdated.addListener((tabId, info) => {
  if (info.url && /^https?:/.test(info.url)) lastSiteURL.set(tabId, info.url);
});
api.tabs.onRemoved.addListener((tabId) => lastSiteURL.delete(tabId));
let appliedKey = null;
let rulesQueue = Promise.resolve();

api.storage.local.get({ port: DEFAULT_PORT }).then((v) => { port = Number(v.port) || DEFAULT_PORT; sync(); });
api.storage.onChanged.addListener((changes, area) => {
  if (area === "local" && changes.port) { port = Number(changes.port.newValue) || DEFAULT_PORT; sync(); }
});

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
  // Coalesce: interval, alarm and content scripts all call this; one request at a time.
  if (inflight) return inflight;
  inflight = syncNow().finally(() => { inflight = null; });
  return inflight;
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

async function applyState(state) {
  const changed = JSON.stringify(state) !== JSON.stringify(lastState);
  lastState = state;
  updateBadge(state);
  await updateRules(state);
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
  const domains = state.isBlocking && Array.isArray(state.domains) ? state.domains : [];
  const blockedPage = api.runtime.getURL("blocked.html");
  // The extension's base URL is part of the key: Safari assigns a new UUID on
  // every reinstall, and dynamic rules persist, so stale rules would redirect
  // to an origin that no longer exists (blank tab).
  const key = blockedPage + "\n" + domains.join("\n");
  rulesQueue = rulesQueue.then(async () => {
    if (key === appliedKey) return;
    const existing = await api.declarativeNetRequest.getDynamicRules();
    const stale = existing.some((r) => r.action && r.action.redirect && (
      (IS_SAFARI && r.action.redirect.regexSubstitution) ||
      (r.action.redirect.regexSubstitution && !r.action.redirect.regexSubstitution.startsWith(blockedPage))));
    const same = !stale && existing.length === domains.length * 2 && domains.every((d) =>
      existing.some((r) => r.condition && r.condition.urlFilter === "||" + (d.split("/")[0]) + "^"));
    if (same && existing.length > 0) { appliedKey = key; return; }
    await api.declarativeNetRequest.updateDynamicRules({
      removeRuleIds: existing.map((r) => r.id),
      addRules: rulesFor(domains, blockedPage, IS_SAFARI)
    });
    appliedKey = key;
  }).catch((e) => { appliedKey = null; console.error("rules update failed", e); });
  return rulesQueue;
}

// Rules only fire on navigation; tabs already sitting on a blocked site get moved.
function enforceOpenTabs(state) {
  if (!state.isBlocking) return;
  const page = api.runtime.getURL("blocked.html");
  api.tabs.query({ url: ["http://*/*", "https://*/*"] }).then((tabs) => {
    for (const tab of tabs) {
      if (tab.id === undefined || !tab.url || !shouldBlock(tab.url, state)) continue;
      api.tabs.update(tab.id, { url: page + "?u=" + encodeURIComponent(tab.url) }).catch(() => {});
    }
  }).catch(() => {});
}

api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const type = message && message.type;
  if (type === "getState") {
    sync().then((s) => sendResponse(s || lastState || offlineState()));
    return true;
  }
  if (type === "originalURL") {
    const id = sender && sender.tab ? sender.tab.id : message.tabId;
    sendResponse({ url: (id !== undefined && lastSiteURL.get(id)) || "" });
    return false;
  }
  if (type === "shouldBlock") {
    sync().then((s) => sendResponse({ block: shouldBlock(message.url, s || lastState), page: api.runtime.getURL("blocked.html") }));
    return true;
  }
  return false;
});
