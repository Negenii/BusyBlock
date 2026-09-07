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

  function barWhere(s) {
    if (!s.host) return "";
    const via = { usb: "USB", mdns: "mDNS", bonjour: "Bonjour" }[s.via];
    return " · bar at " + s.host + (via ? " (" + via + ")" : "");
  }

  function render() {
    if (!state) return;
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
  api.storage.local.get({ port: DEFAULT_PORT }).then((v) => { portInput.value = v.port; openFeed(v.port); });
  document.getElementById("save").addEventListener("click", () => {
    const p = Number(portInput.value) || DEFAULT_PORT;
    api.storage.local.set({ port: p }).then(() => { openFeed(p); setTimeout(refresh, 300); });
  });

  function refresh() {
    api.runtime.sendMessage({ type: "getState" }).then((s) => { state = s; render(); }).catch(() => {});
  }
  api.runtime.onMessage.addListener((m) => { if (m && m.type === "stateUpdated") { state = m.state; render(); } });
  refresh();
  setInterval(render, 1000);
})();
