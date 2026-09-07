(function () {
  const api = typeof browser !== "undefined" ? browser : chrome;
  const original = new URLSearchParams(location.search).get("u") || "";
  let host = "";
  try { host = new URL(original).hostname; } catch (_) {}
  document.getElementById("host").textContent = host;

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
      document.getElementById("title").textContent = "Timer's done.";
      timeEl.textContent = "";
      subEl.textContent = original ? "Taking you back…" : "";
      if (original && !leaving) { leaving = true; setTimeout(() => location.replace(original), 800); }
      return;
    }
    // With the bar's own screen on show there is no second timer to disagree with it.
    const mirror = state.showScreen !== false;
    device.hidden = !mirror;
    timeEl.hidden = mirror;
    const rem = formatRemaining(state.endsAt);
    timeEl.textContent = rem || "∞";
    if (mirror) subEl.textContent = state.phase === "rest" ? "rest phase, still blocked" : "until the bar timer ends";
    else subEl.textContent = state.phase === "rest" ? "rest phase, still blocked" : (rem ? "left on the BUSY Bar" : "no time limit on the bar");
  }

  function setState(s) { state = s; render(); }

  // Live feed from the helper: instant state changes and the bar's own screen.
  api.storage.local.get({ port: DEFAULT_PORT }).then((v) => {
    let lastTint = 0;
    subscribeEvents(v.port, setState, (frame) => {
      device.classList.remove("idle");
      drawFrame(panel, frame);
      const now = Date.now();
      if (now - lastTint > 1000) {
        lastTint = now;
        const c = dominantColor(frame);
        if (c) document.documentElement.style.setProperty("--glow", c.join(", "));
      }
    });
  });

  // Fallback through the worker (also confirms rules are in place).
  function refresh() {
    api.runtime.sendMessage({ type: "getState" }).then(setState).catch(() => {});
  }
  api.runtime.onMessage.addListener((m) => { if (m && m.type === "stateUpdated") setState(m.state); });
  refresh();
  setInterval(render, 1000);
  setInterval(refresh, 10000);
})();
