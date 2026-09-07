const test = require("node:test");
const assert = require("node:assert/strict");
global.DEFAULT_PORT = 48321;
const { decodeFrame, dominantColor, clockFrame } = require("../../extension/led.js");

test("clockFrame draws white LEDs centred on the 72x16 grid", () => {
  const f = clockFrame("20:47");
  assert.equal(f.rgb.length, 72 * 16 * 3);
  let lit = 0, minX = 72, maxX = -1;
  for (let i = 0; i < f.rgb.length; i += 3) if (f.rgb[i]) { lit++; const x = (i / 3) % 72; minX = Math.min(minX, x); maxX = Math.max(maxX, x); }
  assert.ok(lit > 100, "some pixels lit");
  assert.ok(minX > 4 && maxX < 68, "text centred with margins");
  assert.equal(clockFrame("").rgb.reduce((a, b) => a + b, 0), 0);
});

test("dominantColor prefers saturated pixels over white", () => {
  const rgb = new Uint8Array([255, 255, 255, 220, 40, 40, 0, 0, 0]);
  assert.deepEqual(dominantColor({ w: 3, h: 1, rgb }), [220, 40, 40]);
  assert.equal(dominantColor({ w: 1, h: 1, rgb: new Uint8Array([0, 0, 0]) }), null);
});

test("decodeFrame turns base64 RGB into bytes", () => {
  const f = decodeFrame({ w: 2, h: 1, rgb: Buffer.from([255, 0, 0, 0, 0, 255]).toString("base64") });
  assert.equal(f.w, 2);
  assert.equal(f.h, 1);
  assert.deepEqual(Array.from(f.rgb), [255, 0, 0, 0, 0, 255]);
});
