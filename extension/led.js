// Draws a 72×16 RGB888 frame from the bar as an LED panel on a canvas, and
// keeps it fed from the helper's SSE stream. Shared by the block page and popup.

function decodeFrame(msg) {
  const bin = atob(msg.rgb);
  const rgb = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) rgb[i] = bin.charCodeAt(i);
  return { w: msg.w, h: msg.h, rgb };
}

function drawFrame(canvas, frame) {
  const ctx = canvas.getContext("2d");
  const { w, h, rgb } = frame;
  const cell = canvas.width / w;
  const r = cell * 0.36;
  ctx.fillStyle = "#0b0b0b";
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = (y * w + x) * 3;
      const R = rgb[i], G = rgb[i + 1], B = rgb[i + 2];
      const cx = x * cell + cell / 2, cy = y * cell + cell / 2;
      if (R + G + B === 0) {
        ctx.fillStyle = "#151515";
      } else {
        ctx.fillStyle = "rgb(" + R + "," + G + "," + B + ")";
        ctx.shadowColor = ctx.fillStyle;
        ctx.shadowBlur = cell * 0.9;
      }
      ctx.beginPath();
      ctx.arc(cx, cy, r, 0, Math.PI * 2);
      ctx.fill();
      ctx.shadowBlur = 0;
    }
  }
}

// Subscribes to http://127.0.0.1:<port>/events. onState(state) and
// onFrame(frame) fire as events arrive; the returned object has close().
function subscribeEvents(port, onState, onFrame) {
  let es = null, closed = false;
  function open() {
    if (closed) return;
    try { es = new EventSource("http://127.0.0.1:" + (port || DEFAULT_PORT) + "/events"); } catch (_) { return; }
    es.addEventListener("state", (e) => { try { onState(JSON.parse(e.data)); } catch (_) {} });
    es.addEventListener("frame", (e) => { try { onFrame(decodeFrame(JSON.parse(e.data))); } catch (_) {} });
    es.onerror = () => { /* EventSource reconnects on its own (retry: 2000) */ };
  }
  open();
  return { close() { closed = true; if (es) es.close(); } };
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = { decodeFrame };
}
