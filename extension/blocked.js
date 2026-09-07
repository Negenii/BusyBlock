(function () {
  const api = typeof browser !== "undefined" ? browser : chrome;
  const original = new URLSearchParams(location.search).get("u") || "";
  let host = "";
  try { host = new URL(original).hostname; } catch (_) {}
  document.getElementById("host").textContent = host;

  let state = null;
  const timeEl = document.getElementById("time");
  const subEl = document.getElementById("sub");
  const card = document.getElementById("card");

  function render() {
    if (!state) return;
    if (!state.isBlocking) {
      card.classList.add("done");
      document.getElementById("title").textContent = "Timer's done.";
      timeEl.textContent = "";
      subEl.textContent = original ? "Taking you back…" : "";
      if (original) setTimeout(() => location.replace(original), 800);
      return;
    }
    const rem = formatRemaining(state.endsAt);
    timeEl.textContent = rem || "∞";
    subEl.textContent = state.phase === "rest" ? "rest phase, still blocked" : (rem ? "left on the BUSY Bar" : "no time limit on the bar");
  }

  function refresh() {
    api.runtime.sendMessage({ type: "getState" }).then((s) => { state = s; render(); }).catch(() => {});
  }
  api.runtime.onMessage.addListener((m) => { if (m && m.type === "stateUpdated") { state = m.state; render(); } });
  refresh();
  setInterval(render, 1000);
  setInterval(refresh, 5000);
})();
