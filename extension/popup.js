(function () {
  const api = typeof browser !== "undefined" ? browser : chrome;
  const dot = document.getElementById("dot"), line = document.getElementById("line");
  const detail = document.getElementById("detail");
  const panel = document.getElementById("panel");
  const device = document.getElementById("device");
  const timeEl = document.getElementById("time");
  let state = null;
  let feed = null;
  let lastFrameAt = 0;
  let currentPort = DEFAULT_PORT;
  let siteHost = "";
  const siteBox = document.getElementById("site"), siteHostEl = document.getElementById("siteHost");
  const siteBtn = document.getElementById("siteBtn"), siteBadge = document.getElementById("siteBadge");

  // Current tab's host → "Block this site while busy" / "Blocked · remove".
  api.tabs.query({ active: true, currentWindow: true }).then((tabs) => {
    const url = tabs && tabs[0] && tabs[0].url;
    if (!url || !/^https?:/.test(url)) return;
    siteHost = new URL(url).hostname.replace(/^www\./, "");
    siteHostEl.textContent = siteHost;
    siteBox.hidden = false;
    const icon = document.getElementById("siteIcon");
    icon.onload = () => { icon.hidden = false; };
    icon.src = "http://127.0.0.1:" + currentPort + "/favicon?host=" + encodeURIComponent(siteHost);
    renderSite();
  }).catch(() => {});

  function listed() {
    if (!state || !siteHost) return null;
    return (state.domains || []).find((d) => shouldBlock("https://" + siteHost + "/", { isBlocking: true, domains: [d] })) || null;
  }

  // A blocked site only shows a badge: removing it is done in the helper's
  // Settings on purpose, so a two-click unblock isn't available mid-session.
  function renderSite() {
    if (!siteHost) return;
    const entry = listed();
    siteBadge.hidden = !entry;
    siteBtn.hidden = !!entry;
    siteBtn.disabled = !state;
  }

  // Helper down: offer to start it. Safari can ask the app extension's native
  // side (we live inside BusyBlock.app); other browsers open busyblock://open,
  // which macOS routes to the app after a one-time "open BusyBlock?" prompt.
  const IS_SAFARI = api.runtime.getURL("").startsWith("safari-web-extension://");
  const launchBtn = document.getElementById("launchApp");
  launchBtn.addEventListener("click", () => {
    launchBtn.disabled = true;
    const done = () => setTimeout(() => { launchBtn.disabled = false; refresh(); }, 2500);
    if (IS_SAFARI && api.runtime.sendNativeMessage) {
      api.runtime.sendNativeMessage("application.id", { type: "launch" }).then(done, done);
    } else {
      api.tabs.create({ url: "busyblock://open" }).then(done, done);
    }
  });

  document.getElementById("openApp").addEventListener("click", () => {
    fetch("http://127.0.0.1:" + currentPort + "/open", { method: "POST" })
      .then(() => { window.close(); })
      .catch(() => { document.getElementById("openHint").textContent = "BusyBlock isn't running — open it from Applications."; });
  });

  siteBtn.addEventListener("click", () => {
    if (listed()) return;
    const body = { add: siteHost };
    siteBtn.disabled = true;
    fetch("http://127.0.0.1:" + currentPort + "/domains", {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body)
    }).then((r) => r.json()).then((s) => { state = s; render(); })
      .catch(() => {})
      .finally(() => { siteBtn.disabled = false; renderSite(); });
  });

  function barWhere(s) {
    if (!s.host) return "";
    const via = { usb: "USB", mdns: "mDNS", bonjour: "Bonjour" }[s.via];
    return " · bar at " + s.host + (via ? " (" + via + ")" : "");
  }

  function render() {
    if (!state) return;
    renderSite();
    launchBtn.hidden = !state.helperDown;
    document.getElementById("openApp").hidden = !!state.helperDown;
    if (state.isBlocking && state.showScreen !== false && Date.now() - lastFrameAt > 2000) {
      device.classList.remove("idle");
      drawFrame(panel, clockFrame(state.endsAt ? formatRemaining(state.endsAt) : "∞"));
    }
    const mirror = state.showScreen !== false;
    device.hidden = !mirror;
    timeEl.hidden = mirror || !state.isBlocking;
    timeEl.textContent = formatRemaining(state.endsAt) || "∞";
    dot.className = "dot " + (state.isBlocking ? "on" : state.barConnected ? "idle" : "");
    if (state.helperDown && state.isBlocking) {
      dot.className = "dot on";
      const rem = formatRemaining(state.endsAt);
      line.textContent = "Blocking" + (rem ? " · " + rem + " left" : "");
      detail.textContent = "BusyBlock app isn't answering; holding the session it last reported.";
    } else if (!state.barConnected) {
      line.textContent = state.helperDown ? "Helper not running" : "Bar unreachable";
      detail.textContent = "Start BusyBlock in the menu bar and connect the bar.";
    } else if (state.isBlocking) {
      const rem = formatRemaining(state.endsAt);
      line.textContent = mirror ? "Blocking" : "Blocking" + (rem ? " · " + rem + " left" : "");
      detail.textContent = (state.phase === "rest" ? "Rest phase (blocking enabled for rest)" : "Work phase") + barWhere(state);
    } else {
      line.textContent = state.paused ? "Paused" : state.phase === "rest" ? "Rest phase" : "Idle";
      detail.textContent = "Blocking starts with the bar timer." + barWhere(state);
    }
  }

  function openFeed(port) {
    if (feed) feed.close();
    feed = subscribeEvents(port, (s) => { state = s; render(); }, (frame) => { lastFrameAt = Date.now(); device.classList.remove("idle"); drawFrame(panel, frame); });
  }
  // Default port immediately; storage.local {port} is an optional override (no UI).
  openFeed(currentPort);
  api.storage.local.get({ port: DEFAULT_PORT }).then((v) => {
    const p = Number(v.port) || DEFAULT_PORT;
    if (p !== currentPort) { currentPort = p; openFeed(p); }
  }).catch(() => {});

  function refresh() {
    api.runtime.sendMessage({ type: "getState" }).then((s) => { state = s; render(); }).catch(() => {});
  }
  api.runtime.onMessage.addListener((m) => { if (m && m.type === "stateUpdated") { state = m.state; render(); } });
  refresh();
  setInterval(render, 1000);
})();
