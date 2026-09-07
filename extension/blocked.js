(function () {
  const api = typeof browser !== "undefined" ? browser : chrome;
  const original = new URLSearchParams(location.search).get("u") || "";
  let host = "";
  try { host = new URL(original).hostname.replace(/^www\./, ""); } catch (_) {}
  const hostEl = document.getElementById("host"), favEl = document.getElementById("favicon");
  hostEl.textContent = host || "this site";
  document.getElementById("site").title = host;
  if (host) {
    // The site's own icon stands in for its name; fall back to the name if it has none.
    favEl.onload = () => { favEl.hidden = false; hostEl.hidden = true; };
    favEl.onerror = () => { favEl.hidden = true; hostEl.hidden = false; };
    favEl.src = "https://" + host + "/favicon.ico";
  }

  let state = null;
  let leaving = false;
  const timeEl = document.getElementById("time");
  const subEl = document.getElementById("sub");
  const card = document.getElementById("card");
  const panel = document.getElementById("panel");
  const device = document.getElementById("device");

  function render() {
    if (!state) return;
    if (!state.isBlocking) {
      card.classList.add("done");
      timeEl.textContent = "";
      subEl.textContent = original ? "Timer's done, taking you back…" : "Timer's done.";
      if (original && !leaving) { leaving = true; setTimeout(() => location.replace(original), 800); }
      return;
    }
    // With the bar's own screen on show there is no second timer to disagree with it.
    const mirror = state.showScreen !== false;
    device.hidden = !mirror;
    timeEl.hidden = mirror;
    const rem = formatRemaining(state.endsAt);
    timeEl.textContent = rem || "∞";
    subEl.textContent = state.phase === "rest" ? "You're on a BUSY rest" : "You're BUSY";
  }

  function setState(s) { state = s; render(); }

  // Live feed from the helper, only while this tab is on screen: browsers cap
  // connections per host (~6), so background tabs must not hold one. Until a
  // frame arrives, the panel shows the countdown in LEDs drawn here.
  let feed = null, port = DEFAULT_PORT, lastFrameAt = 0, lastTint = 0;
  const feedEl = document.getElementById("feed");

  function connectFeed() {
    if (feed || document.visibilityState !== "visible") return;
    feed = subscribeEvents(port, setState, (frame) => {
      lastFrameAt = Date.now();
      device.classList.remove("idle");
      drawFrame(panel, frame);
      const now = Date.now();
      if (now - lastTint > 1000) {
        lastTint = now;
        const c = dominantColor(frame);
        if (c) document.documentElement.style.setProperty("--glow", c.join(", "));
      }
    }, (text) => { feedEl.textContent = "helper feed: " + text; });
  }

  function disconnectFeed() {
    if (feed) { feed.close(); feed = null; }
    lastFrameAt = 0;
    feedEl.textContent = "helper feed: paused (tab in background)";
  }

  // No live frame for 2 s → draw the clock ourselves on the same panel.
  function drawClockIfStale() {
    if (!state || !state.isBlocking || state.showScreen === false) return;
    if (Date.now() - lastFrameAt < 2000) return;
    device.classList.remove("idle");
    drawFrame(panel, clockFrame(state.endsAt ? formatRemaining(state.endsAt) : "∞"));
  }

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") { drawClockIfStale(); connectFeed(); refresh(); }
    else disconnectFeed();
  });
  window.addEventListener("pagehide", disconnectFeed);

  api.storage.local.get({ port: DEFAULT_PORT }).then((v) => { port = Number(v.port) || DEFAULT_PORT; connectFeed(); });

  // Fallback through the worker (also confirms rules are in place).
  function refresh() {
    api.runtime.sendMessage({ type: "getState" }).then(setState).catch(() => {});
  }
  api.runtime.onMessage.addListener((m) => { if (m && m.type === "stateUpdated") setState(m.state); });
  refresh();
  setInterval(() => { render(); drawClockIfStale(); }, 1000);
  setInterval(refresh, 10000);
})();
