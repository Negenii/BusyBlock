(function () {
  const api = typeof browser !== "undefined" ? browser : chrome;
  const dot = document.getElementById("dot"), line = document.getElementById("line");
  const detail = document.getElementById("detail"), list = document.getElementById("domains");
  const portInput = document.getElementById("port");
  const panel = document.getElementById("panel");
  const device = document.getElementById("device");
  const timeEl = document.getElementById("time");
  let state = null;
  let feed = null;
  let currentPort = DEFAULT_PORT;
  let siteHost = "";
  const siteBox = document.getElementById("site"), siteHostEl = document.getElementById("siteHost"), siteBtn = document.getElementById("siteBtn");

  // Current tab's host → "Block this site while busy" / "Blocked · remove".
  api.tabs.query({ active: true, currentWindow: true }).then((tabs) => {
    const url = tabs && tabs[0] && tabs[0].url;
    if (!url || !/^https?:/.test(url)) return;
    siteHost = new URL(url).hostname.replace(/^www\./, "");
    siteHostEl.textContent = siteHost;
    siteBox.hidden = false;
    renderSite();
  }).catch(() => {});

  function listed() {
    if (!state || !siteHost) return null;
    return (state.domains || []).find((d) => shouldBlock("https://" + siteHost + "/", { isBlocking: true, domains: [d] })) || null;
  }

  function renderSite() {
    if (!siteHost) return;
    const entry = listed();
    siteBtn.className = entry ? "on" : "";
    siteBtn.textContent = entry ? "Blocked · remove" : "Block while busy";
    siteBtn.disabled = !state || state.phase === "offline" && !state.barConnected && !(state.domains || []).length;
  }

  siteBtn.addEventListener("click", () => {
    const entry = listed();
    const body = entry ? { remove: entry } : { add: siteHost };
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
    const mirror = state.showScreen !== false;
    device.hidden = !mirror;
    timeEl.hidden = mirror || !state.isBlocking;
    timeEl.textContent = formatRemaining(state.endsAt) || "∞";
    dot.className = "dot " + (state.isBlocking ? "on" : state.barConnected ? "idle" : "");
    if (!state.barConnected) {
      line.textContent = state.phase === "offline" && !state.domains.length ? "Helper not running" : "Bar unreachable";
      detail.textContent = "Start BusyBlock in the menu bar and connect the bar.";
    } else if (state.isBlocking) {
      const rem = formatRemaining(state.endsAt);
      line.textContent = mirror ? "Blocking" : "Blocking" + (rem ? " · " + rem + " left" : "");
      detail.textContent = (state.phase === "rest" ? "Rest phase (blocking enabled for rest)" : "Work phase") + barWhere(state);
    } else {
      line.textContent = state.paused ? "Paused" : state.phase === "rest" ? "Rest phase" : "Idle";
      detail.textContent = "Blocking starts with the bar timer." + barWhere(state);
    }
    list.innerHTML = "";
    for (const d of state.domains || []) {
      const li = document.createElement("li");
      li.textContent = d;
      list.appendChild(li);
    }
  }

  function openFeed(port) {
    if (feed) feed.close();
    feed = subscribeEvents(port, (s) => { state = s; render(); }, (frame) => { device.classList.remove("idle"); drawFrame(panel, frame); });
  }
  api.storage.local.get({ port: DEFAULT_PORT }).then((v) => { currentPort = Number(v.port) || DEFAULT_PORT; portInput.value = currentPort; openFeed(currentPort); });
  document.getElementById("save").addEventListener("click", () => {
    const p = Number(portInput.value) || DEFAULT_PORT;
    currentPort = p;
    api.storage.local.set({ port: p }).then(() => { openFeed(p); setTimeout(refresh, 300); });
  });

  function refresh() {
    api.runtime.sendMessage({ type: "getState" }).then((s) => { state = s; render(); }).catch(() => {});
  }
  api.runtime.onMessage.addListener((m) => { if (m && m.type === "stateUpdated") { state = m.state; render(); } });
  refresh();
  setInterval(render, 1000);
})();
