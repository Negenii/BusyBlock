const test = require("node:test");
const assert = require("node:assert/strict");
const { shouldBlock, rulesFor, applyRules, formatRemaining, stateURL, goURL } = require("../../extension/shared.js");

function fakeApi(base, initial) {
  let rules = initial.slice();
  const calls = [];
  return { api: { runtime: { getURL: (p) => base + p }, declarativeNetRequest: {
    getDynamicRules: async () => rules.slice(),
    updateDynamicRules: async ({ removeRuleIds, addRules }) => { calls.push({ removeRuleIds, addRules }); rules = rules.filter((r) => !removeRuleIds.includes(r.id)).concat(addRules || []); },
  } }, rules: () => rules, calls };
}

test("applyRules writes helper-based rules in Safari and clears them when not blocking", async () => {
  const f = fakeApi("safari-web-extension://OLD-UUID/", [{ id: 1, action: { type: "redirect", redirect: { extensionPath: "/blocked.html" } }, condition: {} }]);
  const changed = await applyRules(f.api, { isBlocking: true, domains: ["x.com"] }, 48321);
  assert.equal(changed, true);
  assert.equal(f.rules().length, 2);
  assert.equal(f.rules()[0].action.redirect.regexSubstitution, "safari-web-extension://OLD-UUID/blocked.html?u=\\0");
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

test("applyRules redirects straight to the extension page in Safari too", async () => {
  const f = fakeApi("safari-web-extension://UUID/", []);
  await applyRules(f.api, { isBlocking: true, domains: ["x.com"] }, 48321);
  assert.equal(f.rules()[0].action.redirect.regexSubstitution, "safari-web-extension://UUID/blocked.html?u=\\0");
});

test("formatRemaining and stateURL", () => {
  assert.equal(formatRemaining(0), "");
  assert.equal(formatRemaining(1000 * 65 + 1000, 1000), "1:05");
  assert.equal(formatRemaining(59_400, 1000), "0:59");
  assert.equal(formatRemaining(59_000, 1000), "0:58");
  assert.equal(stateURL(), "http://127.0.0.1:48321/state");
  assert.equal(stateURL(5000), "http://127.0.0.1:5000/state");
});
