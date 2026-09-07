// Draws the bar's 72×16 frame the way the official web mirror does: rounded
// LED squares, dark pixels left transparent so the device's black glass shows
// through. Also subscribes to the helper's SSE stream. Shared by block page
// and popup.

function decodeFrame(msg) {
  const bin = atob(msg.rgb);
  const rgb = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) rgb[i] = bin.charCodeAt(i);
  return { w: msg.w, h: msg.h, rgb };
}

function roundedRect(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

function drawFrame(canvas, frame) {
  const ctx = canvas.getContext("2d");
  const { w, h, rgb } = frame;
  const cell = canvas.width / w;
  const size = cell * 0.85, inset = (cell - size) / 2, radius = size * 0.35;
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = (y * w + x) * 3;
      const R = rgb[i], G = rgb[i + 1], B = rgb[i + 2];
      if (R + G + B < 30) continue;
      ctx.fillStyle = "rgb(" + R + "," + G + "," + B + ")";
      roundedRect(ctx, x * cell + inset, y * cell + inset, size, size, radius);
      ctx.fill();
    }
  }
}

// Subscribes to http://127.0.0.1:<port>/events. onState(state) and
// onFrame(frame) fire as events arrive; the returned object has close().
function subscribeEvents(port, onState, onFrame) {
  let es = null, closed = false;
  try { es = new EventSource("http://127.0.0.1:" + (port || DEFAULT_PORT) + "/events"); } catch (_) { return { close() {} }; }
  es.addEventListener("state", (e) => { try { onState(JSON.parse(e.data)); } catch (_) {} });
  es.addEventListener("frame", (e) => { try { onFrame(decodeFrame(JSON.parse(e.data))); } catch (_) {} });
  es.onerror = () => { /* EventSource reconnects on its own (retry: 2000) */ };
  return { close() { closed = true; if (es) es.close(); } };
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = { decodeFrame };
}
