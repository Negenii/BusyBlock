const test = require("node:test");
const assert = require("node:assert/strict");
const { shouldBlock, rulesFor, formatRemaining, stateURL } = require("../../extension/shared.js");

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

test("formatRemaining and stateURL", () => {
  assert.equal(formatRemaining(0), "");
  assert.equal(formatRemaining(1000 * 65 + 1000, 1000), "1:05");
  assert.equal(formatRemaining(59_400, 1000), "0:59");
  assert.equal(formatRemaining(59_000, 1000), "0:58");
  assert.equal(stateURL(), "http://127.0.0.1:48321/state");
  assert.equal(stateURL(5000), "http://127.0.0.1:5000/state");
});
