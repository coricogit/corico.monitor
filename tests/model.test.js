const test = require("node:test")
const assert = require("node:assert")
const M = require("../Model.js")

const benq = { name: "DP-1", enabled: true, width: 1920, height: 1080, x: 0, y: 0, scale: 1, transform: 0 }
const hp = { name: "DP-3", enabled: true, width: 1920, height: 1200, x: 1920, y: 0, scale: 1, transform: 0 }
const pair = [benq, hp]
const pos = (list, name) => { const d = list.find(m => m.name === name); return [d.x, d.y] }
const clear = list => { const r = list.map(M.logicalRect); assert.ok(!M.overlaps(r[0], r[1])) }

test("rotation and scale change the logical size", () => {
  assert.deepEqual(M.logicalRect({ ...hp, transform: 1 }), { x: 1920, y: 0, w: 1200, h: 1920 })
  assert.deepEqual(M.logicalRect({ ...benq, scale: 2 }), { x: 0, y: 0, w: 960, h: 540 })
})

test("dragging to the far side swaps the monitors and restarts at 0x0", () => {
  const list = M.placeMonitor(pair, "DP-3", { x: -1000, y: 0 })
  assert.deepEqual(pos(list, "DP-3"), [0, 0])
  assert.deepEqual(pos(list, "DP-1"), [1920, 0])
})

test("dragging above stacks without overlap", () => {
  const list = M.placeMonitor(pair, "DP-3", { x: 100, y: -900 })
  clear(list)
  assert.deepEqual(pos(list, "DP-3"), [100, 0])
  assert.deepEqual(pos(list, "DP-1"), [0, 1200])
})

test("a nearby edge or centre lines up", () => {
  assert.deepEqual(pos(M.placeMonitor(pair, "DP-3", { x: 1920, y: 40 }), "DP-3"), [1920, 0])
  assert.deepEqual(pos(M.placeMonitor(pair, "DP-3", { x: 1920, y: 400 }), "DP-1"), [0, 0])
})

test("a monitor dropped far away stays attached with a shared edge", () => {
  const list = M.placeMonitor(pair, "DP-3", { x: 9000, y: 5000 })
  const [a, b] = list.map(M.logicalRect)
  assert.equal(b.x, a.x + a.w)
  assert.ok(Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y) >= 200)
})

test("rotating a left monitor keeps its neighbour against it", () => {
  const list = M.placeMonitor(pair, "DP-1", { transform: 1 })
  assert.deepEqual(pos(list, "DP-1"), [0, 0])
  assert.deepEqual(pos(list, "DP-3"), [1080, 0])
  assert.equal(list.find(m => m.name === "DP-1").transform, 1)
})

test("scaling closes the gap it leaves", () => {
  assert.deepEqual(pos(M.placeMonitor(pair, "DP-1", { scale: 2 }), "DP-3"), [960, 0])
})

test("a lone monitor stays put, disabled ones are left out", () => {
  const list = M.placeMonitor([benq, { ...hp, enabled: false }], "DP-1", { transform: 1 })
  assert.equal(list.length, 1)
  assert.deepEqual(pos(list, "DP-1"), [0, 0])
})

test("three monitors never overlap after a drop", () => {
  const third = { name: "DP-5", enabled: true, width: 1920, height: 1080, x: 3840, y: 0, scale: 1, transform: 0 }
  const list = M.placeMonitor([benq, hp, third], "DP-5", { x: 1000, y: 100 }).map(M.logicalRect)
  for (let i = 0; i < 3; i++) for (let j = i + 1; j < 3; j++) assert.ok(!M.overlaps(list[i], list[j]))
})

test("sameLayout notices moves", () => {
  assert.ok(M.sameLayout(pair, pair.map(d => ({ ...d }))))
  assert.ok(!M.sameLayout(pair, [benq, { ...hp, x: 0 }]))
})

test("rates cover only the current resolution, fastest first", () => {
  const modes = ["1920x1080@60.00Hz", "1920x1080@165.00Hz", "1920x1080@119.88Hz", "1920x1080@60.00Hz", "1280x720@100.00Hz", "junk"]
  assert.deepEqual(M.refreshRates({ ...benq, availableModes: modes }), ["165", "119.88", "60"])
  assert.deepEqual(M.refreshRates(null), [])
})
