const test = require("node:test");
const assert = require("node:assert/strict");
const { shouldBlock, rulesFor, applyRules, stateAfterHelperLoss, formatRemaining, stateURL, goURL } = require("../../extension/shared.js");

test("helper loss holds a running session until its end", () => {
  const now = 1_000_000;
  const running = { isBlocking: true, domains: ["x.com"], endsAt: now + 60_000, barConnected: true, phase: "work" };
  const held = stateAfterHelperLoss(running, now, now - 5000);
  assert.equal(held.isBlocking, true);
  assert.equal(held.helperDown, true);
  assert.deepEqual(held.domains, ["x.com"]);
  assert.equal(stateAfterHelperLoss(running, now + 61_000, now).isBlocking, false, "released after endsAt");
  const infinite = { isBlocking: true, domains: ["x.com"], endsAt: 0 };
  assert.equal(stateAfterHelperLoss(infinite, now + 10 * 60_000, now).isBlocking, true, "infinite held for a while");
  assert.equal(stateAfterHelperLoss(infinite, now + 31 * 60_000, now).isBlocking, false, "…but not forever");
  assert.equal(stateAfterHelperLoss({ isBlocking: false, domains: [] }, now, now).isBlocking, false);
  assert.equal(stateAfterHelperLoss(null, now, now).helperDown, true);
});

function fakeApi(base, initial) {
  let rules = initial.slice();
  const calls = [];
  return { api: { runtime: { getURL: (p) => base + p }, declarativeNetRequest: {
    getDynamicRules: async () => rules.slice(),
    updateDynamicRules: async ({ removeRuleIds, addRules }) => { calls.push({ removeRuleIds, addRules }); rules = rules.filter((r) => !removeRuleIds.includes(r.id)).concat(addRules || []); },
  } }, rules: () => rules, calls };
}

test("applyRules writes block rules in Safari and clears them when not blocking", async () => {
  const f = fakeApi("safari-web-extension://OLD-UUID/", [{ id: 1, action: { type: "redirect", redirect: { extensionPath: "/blocked.html" } }, condition: {} }]);
  const changed = await applyRules(f.api, { isBlocking: true, domains: ["x.com"] }, 48321);
  assert.equal(changed, true);
  assert.equal(f.rules().length, 2);
  assert.deepEqual(f.rules()[0].action, { type: "block" });
  const again = await applyRules(f.api, { isBlocking: true, domains: ["x.com"] }, 48321);
  assert.equal(again, false, "identical rules are left alone");
  await applyRules(f.api, { isBlocking: false, domains: ["x.com"] }, 48321);
  assert.equal(f.rules().length, 0);
});

const on = { isBlocking: true, domains: ["youtube.com", "reddit.com/r"] };

test("blocks host and subdomains", () => {
  assert.equal(shouldBlock("https://youtube.com/", on), true);
  assert.equal(shouldBlock("https://m.youtube.com/watch?v=1", on), true);
  assert.equal(shouldBlock("https://notyoutube.com/", on), false);
});

test("path entries match as prefix", () => {
  assert.equal(shouldBlock("https://reddit.com/r/all", on), true);
  assert.equal(shouldBlock("https://www.reddit.com/r/", on), true);
  assert.equal(shouldBlock("https://reddit.com/user/x", on), false);
});

test("nothing blocked when not blocking or bad input", () => {
  assert.equal(shouldBlock("https://youtube.com/", { isBlocking: false, domains: ["youtube.com"] }), false);
  assert.equal(shouldBlock("not a url", on), false);
  assert.equal(shouldBlock("chrome://extensions", on), false);
  assert.equal(shouldBlock("https://youtube.com/", null), false);
});

test("rulesFor in block mode blocks the main frame instead of redirecting", () => {
  const rules = rulesFor(["youtube.com"], "safari-web-extension://abc/blocked.html", null, "block");
  assert.equal(rules.length, 2);
  assert.deepEqual(rules[0].action, { type: "block" });
  assert.deepEqual(rules[0].condition.resourceTypes, ["main_frame"]);
  assert.deepEqual(rules[1].action, { type: "block" });
});

test("rulesFor makes redirect + block per entry with unique ids", () => {
  const rules = rulesFor(["youtube.com", "reddit.com/r"], "chrome-extension://abc/blocked.html");
  assert.equal(rules.length, 4);
  assert.deepEqual(rules.map((r) => r.id), [1, 2, 3, 4]);
  assert.equal(rules[0].action.type, "redirect");
  assert.equal(rules[0].action.redirect.regexSubstitution, "chrome-extension://abc/blocked.html?u=\\0");
  assert.ok(new RegExp(rules[0].condition.regexFilter).test("https://m.youtube.com/watch?v=1"));
  assert.ok(!new RegExp(rules[0].condition.regexFilter).test("https://notyoutube.com/"));
  assert.ok(new RegExp(rules[2].condition.regexFilter).test("https://reddit.com/r/all"));
  assert.ok(!new RegExp(rules[2].condition.regexFilter).test("https://reddit.com/user"));
  assert.equal(rules[1].condition.urlFilter, "||youtube.com^");
  assert.equal(rules[3].condition.urlFilter, "||reddit.com^");
});

test("applyRules blocks the main frame in Safari (address-bar loads stall on a redirect) and redirects elsewhere", async () => {
  const s = fakeApi("safari-web-extension://UUID/", []);
  await applyRules(s.api, { isBlocking: true, domains: ["x.com"] }, 48321);
  assert.deepEqual(s.rules()[0].action, { type: "block" });
  assert.deepEqual(s.rules()[0].condition.resourceTypes, ["main_frame"]);
  const c = fakeApi("chrome-extension://abc/", []);
  await applyRules(c.api, { isBlocking: true, domains: ["x.com"] }, 48321);
  assert.equal(c.rules()[0].action.redirect.regexSubstitution, "chrome-extension://abc/blocked.html?u=\\0");
});

test("formatRemaining and stateURL", () => {
  assert.equal(formatRemaining(0), "");
  assert.equal(formatRemaining(1000 * 65 + 1000, 1000), "01:05");
  assert.equal(formatRemaining(59_400, 1000), "00:59");
  assert.equal(formatRemaining(59_000, 1000), "00:58");
  // Over an hour the bar switches to hours, and so do we.
  assert.equal(formatRemaining(1000 + 3600_000, 1000), "1:00:00");
  assert.equal(formatRemaining(1000 + 5400_000, 1000), "1:30:00");
  assert.equal(formatRemaining(1000 + 3599_000, 1000), "59:59");
  assert.equal(formatRemaining(1000 + 36_000_000, 1000), "10:00:00");
  assert.equal(stateURL(), "http://127.0.0.1:48321/state");
  assert.equal(stateURL(5000), "http://127.0.0.1:5000/state");
});
