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

// 5×7 pixel digits, drawn as LEDs while no live frame is available (tab was
// in the background, feed reconnecting). Same grid as the bar: 72×16.
const LED_FONT = {
  "0": ["01110","10001","10011","10101","11001","10001","01110"],
  "1": ["00100","01100","00100","00100","00100","00100","01110"],
  "2": ["01110","10001","00001","00010","00100","01000","11111"],
  "3": ["11111","00010","00100","00010","00001","10001","01110"],
  "4": ["00010","00110","01010","10010","11111","00010","00010"],
  "5": ["11111","10000","11110","00001","00001","10001","01110"],
  "6": ["00110","01000","10000","11110","10001","10001","01110"],
  "7": ["11111","00001","00010","00100","01000","01000","01000"],
  "8": ["01110","10001","10001","01110","10001","10001","01110"],
  "9": ["01110","10001","10001","01111","00001","00010","01100"],
  ":": ["00000","00100","00100","00000","00100","00100","00000"],
  "∞": ["00000","00000","01010","10101","10101","01010","00000"],
  "-": ["00000","00000","00000","11111","00000","00000","00000"],
};

// Builds a 72×16 RGB frame with `text` centred in white LEDs (digits doubled to 10×14).
function clockFrame(text, w, h) {
  w = w || 72; h = h || 16;
  const rgb = new Uint8Array(w * h * 3);
  const glyphs = Array.from(text).map((c) => LED_FONT[c] || LED_FONT["-"]);
  // Double size when it fits, single when it doesn't: H:MM:SS is seven glyphs
  // and would run off the end of the panel at double.
  const span = (k) => glyphs.length * 5 * k + (glyphs.length - 1) * k;
  const scale = span(2) <= w ? 2 : 1, gap = scale;
  const width = span(scale);
  let x0 = Math.max(0, Math.floor((w - width) / 2));
  const y0 = Math.floor((h - 7 * scale) / 2);
  for (const g of glyphs) {
    for (let r = 0; r < 7; r++) for (let c = 0; c < 5; c++) {
      if (g[r][c] !== "1") continue;
      for (let dy = 0; dy < scale; dy++) for (let dx = 0; dx < scale; dx++) {
        const x = x0 + c * scale + dx, y = y0 + r * scale + dy;
        if (x < 0 || x >= w || y < 0 || y >= h) continue;
        const i = (y * w + x) * 3;
        rgb[i] = rgb[i + 1] = rgb[i + 2] = 255;
      }
    }
    x0 += 5 * scale + gap;
  }
  return { w, h, rgb };
}

// The panel's dominant lit colour, for tinting the page. Most saturated
// pixel wins, so white digits don't wash the red out.
function dominantColor(frame) {
  const { rgb } = frame;
  let best = null, bestScore = 0;
  for (let i = 0; i < rgb.length; i += 3) {
    const r = rgb[i], g = rgb[i + 1], b = rgb[i + 2];
    const max = Math.max(r, g, b), min = Math.min(r, g, b);
    if (max < 40) continue;
    const score = (max - min) * max;
    if (score > bestScore) { bestScore = score; best = [r, g, b]; }
  }
  return best;
}

// Subscribes to http://127.0.0.1:<port>/events. onState(state) and
// onFrame(frame) fire as events arrive; the returned object has close().
function subscribeEvents(port, onState, onFrame, onStatus) {
  let es = null, closed = false, frames = 0, errors = 0;
  const report = (text) => { if (onStatus) onStatus(text); };
  try { es = new EventSource("http://127.0.0.1:" + (port || DEFAULT_PORT) + "/events"); } catch (e) { report("no EventSource: " + e); return { close() {} }; }
  report("connecting…");
  es.onopen = () => report("live");
  es.addEventListener("state", (e) => { try { onState(JSON.parse(e.data)); } catch (err) { errors++; report("bad state event: " + err); } });
  es.addEventListener("frame", (e) => {
    try { onFrame(decodeFrame(JSON.parse(e.data))); frames++; if (frames % 10 === 1) report("live · " + frames + " frames"); }
    catch (err) { errors++; report("frame error: " + err); }
  });
  es.onerror = () => { errors++; report("reconnecting (" + errors + ")… readyState=" + es.readyState); };
  return { close() { closed = true; if (es) es.close(); } };
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = { decodeFrame, dominantColor, clockFrame };
}
