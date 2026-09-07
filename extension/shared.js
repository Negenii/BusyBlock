// Shared by the service worker, the block page and the popup. Also loaded by
// `node --test`, hence the CommonJS export at the bottom.

const DEFAULT_PORT = 48321;

function stateURL(port) {
  return "http://127.0.0.1:" + (port || DEFAULT_PORT) + "/state";
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
function rulesFor(domains, blockedPage) {
  const rules = [];
  domains.forEach((domain, index) => {
    const slash = domain.indexOf("/");
    const host = slash === -1 ? domain : domain.slice(0, slash);
    const path = slash === -1 ? "" : domain.slice(slash);
    const tail = path ? escapeRegex(path) + ".*" : "([/?#].*)?";
    rules.push({
      id: index * 2 + 1,
      priority: 1,
      action: { type: "redirect", redirect: { regexSubstitution: blockedPage + "?u=\\0" } },
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

function offlineState() {
  return { isBlocking: false, domains: [], endsAt: 0, paused: false, barConnected: false, phase: "offline" };
}

function formatRemaining(endsAtMs, nowMs) {
  if (!endsAtMs) return "";
  const secs = Math.max(0, Math.round((endsAtMs - (nowMs || Date.now())) / 1000));
  const m = Math.floor(secs / 60), s = secs % 60;
  return m + ":" + (s < 10 ? "0" : "") + s;
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = { DEFAULT_PORT, stateURL, shouldBlock, rulesFor, offlineState, formatRemaining, escapeRegex };
}
