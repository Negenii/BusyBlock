// Runs at document_start. Asks the worker (waking it if needed) whether this
// URL is blocked right now, so a timer that started seconds ago is enforced on
// the very next navigation even if the worker was asleep.
(function () {
  if (window !== window.top) return;
  const url = location.href;
  if (!/^https?:/.test(url)) return;
  const api = typeof browser !== "undefined" ? browser : chrome;
  // Safari path: the DNR rule sent us to the helper's /go?u=<site>; finish the
  // hop to the block page with the extension's current URL.
  if (/^http:\/\/127\.0\.0\.1:\d+\/go(\?|$)/.test(url)) {
    const u = new URLSearchParams(location.search).get("u") || "";
    location.replace(api.runtime.getURL("blocked.html") + "?u=" + encodeURIComponent(u));
    return;
  }
  let reply;
  try { reply = api.runtime.sendMessage({ type: "shouldBlock", url }); } catch (_) { return; }
  if (!reply || !reply.then) return;
  reply.then((r) => {
    if (r && r.block && r.page) location.replace(r.page + "?u=" + encodeURIComponent(url));
  }).catch(() => {});
})();
