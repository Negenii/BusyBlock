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
  // Never navigate a page the person can't see: Safari preloads the address
  // bar's top hit while they are still typing, and Chrome prerenders. Wait
  // until the page is actually shown; a discarded preload never gets there.
  const whenVisible = (fn) => {
    if (document.visibilityState === "visible" && !document.prerendering) { fn(); return; }
    document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") fn(); }, { once: true });
    document.addEventListener("prerenderingchange", fn, { once: true });
  };
  let reply;
  try { reply = api.runtime.sendMessage({ type: "shouldBlock", url }); } catch (_) { return; }
  if (!reply || !reply.then) return;
  reply.then((r) => {
    if (r && r.block && r.page) location.replace(r.page + "?u=" + encodeURIComponent(url));
  }).catch(() => {});
})();
