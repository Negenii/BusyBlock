// BusyBlock service worker: polls the helper on 127.0.0.1 and keeps the
// declarativeNetRequest rules in step with it.
// Chrome runs this as a service worker (shared.js via importScripts);
// Firefox/Safari load shared.js first through background.scripts.
if (typeof shouldBlock === "undefined" && typeof importScripts === "function") importScripts("shared.js");

const api = typeof browser !== "undefined" ? browser : chrome;
const SYNC_ALARM = "busyblock-sync";
const ALARM_MINUTES = 0.5;      // Chrome's floor; setInterval covers the gap while awake
const LIVE_POLL_MS = 3000;

let lastState = null;
let port = DEFAULT_PORT;
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
  const res = await fetch(stateURL(port), { cache: "no-store" });
  if (!res.ok) throw new Error("helper responded " + res.status);
  return res.json();
}

async function sync() {
  try {
    const state = await fetchState();
    await applyState(state);
    return state;
  } catch (_) {
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
  const key = domains.join("\n");
  rulesQueue = rulesQueue.then(async () => {
    if (key === appliedKey) return;
    const existing = await api.declarativeNetRequest.getDynamicRules();
    await api.declarativeNetRequest.updateDynamicRules({
      removeRuleIds: existing.map((r) => r.id),
      addRules: rulesFor(domains, api.runtime.getURL("blocked.html"))
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
  if (type === "shouldBlock") {
    sync().then((s) => sendResponse({ block: shouldBlock(message.url, s || lastState), page: api.runtime.getURL("blocked.html") }));
    return true;
  }
  return false;
});
