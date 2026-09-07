const test = require("node:test");
const assert = require("node:assert/strict");
global.DEFAULT_PORT = 48321;
const { decodeFrame, dominantColor } = require("../../extension/led.js");

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
