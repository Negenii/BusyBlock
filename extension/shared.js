// Shared by the service worker, the block page and the popup. Also loaded by
// `node --test`, hence the CommonJS export at the bottom.

const DEFAULT_PORT = 48321;

function stateURL(port) {
  return "http://127.0.0.1:" + (port || DEFAULT_PORT) + "/state";
}

function goURL(port) {
  return "http://127.0.0.1:" + (port || DEFAULT_PORT) + "/go";
}

// Host equals a blocked entry (or is a subdomain of it); entries with a path
// ("site.com/section") match as a prefix of host + path.
function shouldBlock(url, state) {
  if (!state || !state.isBlocking || !Array.isArray(state.domains)) return false;
  let u;
  try { u = new URL(url); } catch (_) { return false; }
  if (u.protocol !== "http:" && u.protocol !== "https:") return false;
  const host = u.hostname.toLowerCase();
  const hostAndPath = host + u.pathname;
  return state.domains.some((entry) => {
    const slash = entry.indexOf("/");
    const entryHost = slash === -1 ? entry : entry.slice(0, slash);
    const entryPath = slash === -1 ? "" : entry.slice(slash);
    const hostMatches = host === entryHost || host.endsWith("." + entryHost);
    if (!hostMatches) return false;
    if (!entryPath) return true;
    const sub = host.length - entryHost.length;
    return hostAndPath.slice(sub).startsWith(entryHost + entryPath);
  });
}

function escapeRegex(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// Two declarativeNetRequest rules per entry: top-level navigations redirect to
// the block page with the original URL in ?u=, embedded frames just vanish.
// `viaHelper` (Safari): Safari gives the extension a new UUID on every
// reinstall while dynamic rules persist, so a rule must not contain the
// extension URL. Redirect to the helper's /go?u=<site> instead (plain http,
// stable); the content script on that page hops to blocked.html?u=… using the
// current extension URL.
// `mainFrame` = "redirect" (default) or "block". Safari: a redirect to the
// extension page stalls every navigation started from the address bar (blank
// tab, no URL, forever), so there the main frame is blocked outright and the
// worker moves the tab to the block page once the blocked URL has committed.
function rulesFor(domains, blockedPage, viaHelper, mainFrame) {
  const rules = [];
  domains.forEach((domain, index) => {
    const slash = domain.indexOf("/");
    const host = slash === -1 ? domain : domain.slice(0, slash);
    const path = slash === -1 ? "" : domain.slice(slash);
    const tail = path ? escapeRegex(path) + ".*" : "([/?#].*)?";
    const redirect = { regexSubstitution: (viaHelper || blockedPage) + "?u=\\0" };
    rules.push({
      id: index * 2 + 1,
      priority: 1,
      action: mainFrame === "block" ? { type: "block" } : { type: "redirect", redirect },
      condition: { regexFilter: "^https?://([^/]*\\.)?" + escapeRegex(host) + tail + "$", resourceTypes: ["main_frame"] }
    });
    rules.push({
      id: index * 2 + 2,
      priority: 1,
      action: { type: "block" },
      condition: { urlFilter: "||" + host + "^", resourceTypes: ["sub_frame"] }
    });
  });
  return rules;
}

// Makes the browser's dynamic rules match `state`. Used by the worker and by
// the block page itself, so rules still follow the helper when the background
// is asleep (Safari) — otherwise a finished timer would leave stale redirects.
let applyRulesQueue = Promise.resolve();
function applyRules(api, state, port) {
  const domains = state && state.isBlocking && Array.isArray(state.domains) ? state.domains : [];
  const blockedPage = api.runtime.getURL("blocked.html");
  // Direct redirect to our own page everywhere. Safari refuses the body of an
  // https→http redirect (so a helper-served hop page can't work), and a
  // forced hop from the worker would commit Safari's top-hit preload while the
  // person is still typing. The extension URL is a secure scheme, and a
  // preloaded block page just stays hidden until they actually go there.
  // Safari's per-install UUID is handled by rewriting rules on startup.
  const safari = blockedPage.startsWith("safari-web-extension://");
  const wanted = rulesFor(domains, blockedPage, null, safari ? "block" : "redirect");
  const norm = (rs) => JSON.stringify(rs.map((r) => ({ id: r.id, action: r.action, condition: r.condition })).sort((x, y) => x.id - y.id));
  applyRulesQueue = applyRulesQueue.then(async () => {
    const existing = await api.declarativeNetRequest.getDynamicRules();
    if (norm(existing) === norm(wanted)) return false;
    await api.declarativeNetRequest.updateDynamicRules({ removeRuleIds: existing.map((r) => r.id), addRules: wanted });
    return true;
  }).catch((e) => { console.error("rules update failed", e); if (typeof globalThis.onRulesError === "function") globalThis.onRulesError(e); return false; });
  return applyRulesQueue;
}

function offlineState() {
  return { isBlocking: false, domains: [], endsAt: 0, paused: false, barConnected: false, phase: "offline", helperDown: true };
}

// The helper stopped answering (quit, crashed, being updated). Rather than
// unblocking on the spot, keep the session we last knew about running to its
// end: the countdown was already agreed with the bar. Sessions without an end
// (INFINITE) are held for HOLD_INFINITE_MS after the last contact.
const HOLD_INFINITE_MS = 30 * 60 * 1000;
function stateAfterHelperLoss(last, nowMs, lastContactMs) {
  if (!last || !last.isBlocking) return offlineState();
  const until = last.endsAt || (lastContactMs + HOLD_INFINITE_MS);
  if (nowMs >= until) return offlineState();
  return Object.assign({}, last, { helperDown: true, endsAt: last.endsAt || until, barConnected: false });
}

function formatRemaining(endsAtMs, nowMs) {
  if (!endsAtMs) return "";
  // Bar counts whole seconds down: 58.4 s left shows as 59.
  const secs = Math.max(0, Math.ceil((endsAtMs - (nowMs || Date.now())) / 1000 - 0.05));
  const m = Math.floor(secs / 60), s = secs % 60;
  return m + ":" + (s < 10 ? "0" : "") + s;
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = { DEFAULT_PORT, stateURL, goURL, shouldBlock, rulesFor, applyRules, offlineState, stateAfterHelperLoss, formatRemaining, escapeRegex };
}
