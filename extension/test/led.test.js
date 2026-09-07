const test = require("node:test");
const assert = require("node:assert/strict");
global.DEFAULT_PORT = 48321;
const { decodeFrame } = require("../led.js");

test("decodeFrame turns base64 RGB into bytes", () => {
  const f = decodeFrame({ w: 2, h: 1, rgb: Buffer.from([255, 0, 0, 0, 0, 255]).toString("base64") });
  assert.equal(f.w, 2);
  assert.equal(f.h, 1);
  assert.deepEqual(Array.from(f.rgb), [255, 0, 0, 0, 0, 255]);
});
