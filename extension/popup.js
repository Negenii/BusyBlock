(function () {
  const api = typeof browser !== "undefined" ? browser : chrome;
  const dot = document.getElementById("dot"), line = document.getElementById("line");
  const detail = document.getElementById("detail"), list = document.getElementById("domains");
  const portInput = document.getElementById("port");
  let state = null;

  function render() {
    if (!state) return;
    dot.className = "dot " + (state.isBlocking ? "on" : state.barConnected ? "idle" : "");
    if (!state.barConnected) {
      line.textContent = state.phase === "offline" && !state.domains.length ? "Helper not running" : "Bar unreachable";
      detail.textContent = "Start BusyBlock in the menu bar and connect the bar.";
    } else if (state.isBlocking) {
      const rem = formatRemaining(state.endsAt);
      line.textContent = "Blocking" + (rem ? " · " + rem + " left" : "");
      detail.textContent = state.phase === "rest" ? "Rest phase (blocking enabled for rest)" : "Work phase";
    } else {
      line.textContent = state.paused ? "Paused" : state.phase === "rest" ? "Rest phase" : "Idle";
      detail.textContent = "Blocking starts with the bar timer.";
    }
    list.innerHTML = "";
    for (const d of state.domains || []) {
      const li = document.createElement("li");
      li.textContent = d;
      list.appendChild(li);
    }
  }

  api.storage.local.get({ port: DEFAULT_PORT }).then((v) => { portInput.value = v.port; });
  document.getElementById("save").addEventListener("click", () => {
    const p = Number(portInput.value) || DEFAULT_PORT;
    api.storage.local.set({ port: p }).then(() => setTimeout(refresh, 300));
  });

  function refresh() {
    api.runtime.sendMessage({ type: "getState" }).then((s) => { state = s; render(); }).catch(() => {});
  }
  api.runtime.onMessage.addListener((m) => { if (m && m.type === "stateUpdated") { state = m.state; render(); } });
  refresh();
  setInterval(render, 1000);
})();
