(function () {
  const api = typeof browser !== "undefined" ? browser : chrome;
  const original = new URLSearchParams(location.search).get("u") || "";
  let host = "";
  try { host = new URL(original).hostname.replace(/^www\./, ""); } catch (_) {}
  const hostEl = document.getElementById("host"), favEl = document.getElementById("favicon");
  hostEl.textContent = host || "this site";
  document.getElementById("site").title = host;
  // The site's icon stands in for its name. The helper serves it (own cache,
  // site first, then the optional DuckDuckGo fallback); name if it has none.
  function loadFavicon(port) {
    if (!host) return;
    favEl.onload = () => { favEl.hidden = false; hostEl.hidden = true; };
    favEl.onerror = () => { favEl.hidden = true; hostEl.hidden = false; };
    favEl.src = "http://127.0.0.1:" + (port || DEFAULT_PORT) + "/favicon?host=" + encodeURIComponent(host);
  }

  let state = null;
  let leaving = false;
  const timeEl = document.getElementById("time");
  const subEl = document.getElementById("sub");
  const card = document.getElementById("card");
  const panel = document.getElementById("panel");
  const device = document.getElementById("device");

  const setText = (el, text) => { if (el.textContent !== text) el.textContent = text; };

  function render() {
    if (!state) return;
    if (!state.isBlocking) {
      card.classList.add("done");
      setText(timeEl, "");
      subEl.hidden = false;
      setText(subEl, original ? "Timer's done, taking you back…" : "Timer's done.");
      if (original && !leaving) { leaving = true; setTimeout(() => location.replace(original), 800); }
      return;
    }
    // With the bar's own screen on show there is no second timer to disagree with it.
    const mirror = state.showScreen !== false;
    device.hidden = !mirror;
    timeEl.hidden = mirror;
    const rem = formatRemaining(state.endsAt);
    setText(timeEl, rem || "∞");
    subEl.hidden = true;
  }

  function setState(s) { state = s; render(); }

  // Live feed from the helper, only while this tab is on screen: browsers cap
  // connections per host (~6), so background tabs must not hold one. Until a
  // frame arrives, the panel shows the countdown in LEDs drawn here.
  let feed = null, port = DEFAULT_PORT, lastFrameAt = 0, lastTint = 0;

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
    });
  }

  function disconnectFeed() {
    if (feed) { feed.close(); feed = null; }
    lastFrameAt = 0;
  }

  // No live frame for 2 s → draw the clock ourselves on the same panel.
  function drawClockIfStale() {
    if (!state || !state.isBlocking || state.showScreen === false) return;
    if (Date.now() - lastFrameAt < 2000) return;
    device.classList.remove("idle");
    drawFrame(panel, clockFrame(state.endsAt ? formatRemaining(state.endsAt) : "∞"));
  }

  document.addEventListener("visibilitychange", () => {
    document.documentElement.classList.toggle("hidden-tab", document.visibilityState !== "visible");
    if (document.visibilityState === "visible") { drawClockIfStale(); connectFeed(); refresh(); }
    else disconnectFeed();
  });
  window.addEventListener("pagehide", disconnectFeed);

  api.storage.local.get({ port: DEFAULT_PORT }).then((v) => { port = Number(v.port) || DEFAULT_PORT; loadFavicon(port); connectFeed(); });

  // Fallback through the worker (also confirms rules are in place).
  function refresh() {
    api.runtime.sendMessage({ type: "getState" }).then(setState).catch(() => {});
  }
  api.runtime.onMessage.addListener((m) => { if (m && m.type === "stateUpdated") setState(m.state); });
  // Background glow: three blobs drifting on slow sine paths, updated 8 times a
  // second from JS. A CSS animation would make the compositor redraw these big
  // layers at 60 fps and keep the GPU busy for a page that is mostly static.
  const blobs = Array.from(document.querySelectorAll(".blob"));
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
  function moveBlobs() {
    if (reduceMotion || document.visibilityState !== "visible") return;
    const t = Date.now() / 1000;
    const vw = innerWidth / 100, vh = innerHeight / 100;
    blobs[0].style.transform = "translate(" + (14 * vw * (1 + Math.sin(t / 13))) + "px, " + (9 * vh * (1 + Math.sin(t / 9))) + "px) scale(" + (1.1 + 0.15 * Math.sin(t / 11)) + ")";
    blobs[1].style.transform = "translate(" + (-13 * vw * (1 + Math.cos(t / 16))) + "px, " + (-11 * vh * (1 + Math.sin(t / 12))) + "px) scale(" + (1 + 0.1 * Math.cos(t / 10)) + ")";
    blobs[2].style.transform = "translate(" + (16 * vw * Math.sin(t / 11)) + "px, " + (14 * vh * Math.cos(t / 14)) + "px)";
  }
  moveBlobs();
  setInterval(moveBlobs, 125);

  refresh();
  setInterval(() => { render(); drawClockIfStale(); }, 1000);
  setInterval(refresh, 10000);
})();
