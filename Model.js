function clampBrightness(value) {
  var n = Number(value)
  if (!isFinite(n)) return 1
  return Math.max(1, Math.min(100, Math.round(n)))
}

function normalizeScale(scale) {
  var n = parseFloat(String(scale || ""))
  if (!isFinite(n)) return ""
  return String(Math.round(n * 100) / 100)
}

function gcd(a, b) {
  while (b) {
    var remainder = a % b
    a = b
    b = remainder
  }
  return a
}

function cleanScale(scale, width, height) {
  var requested = Number(scale)
  var modeWidth = Number(width)
  var modeHeight = Number(height)
  if (!isFinite(requested) || !isFinite(modeWidth) || !isFinite(modeHeight)
      || requested <= 0 || modeWidth <= 0 || modeHeight <= 0) return ""

  var divisor = gcd(Math.round(modeWidth * 120), Math.round(modeHeight * 120))
  var scaleUnits = Math.round(requested * 120)
  if (scaleUnits > divisor) scaleUnits = divisor
  while (divisor % scaleUnits !== 0) scaleUnits++
  return normalizeScale(scaleUnits / 120)
}

function matchingScaleIndex(scales, currentScale, width, height) {
  var current = Number(currentScale)
  if (!Array.isArray(scales) || !isFinite(current)) return -1

  var bestIndex = -1
  var bestDistance = Infinity
  var normalizedCurrent = normalizeScale(current)
  for (var i = 0; i < scales.length; i++) {
    if (cleanScale(scales[i], width, height) !== normalizedCurrent) continue

    var distance = Math.abs(Number(scales[i]) - current)
    if (distance < bestDistance) {
      bestIndex = i
      bestDistance = distance
    }
  }
  return bestIndex
}

function availableScales(scales, width, height) {
  if (!Array.isArray(scales) || Number(width) <= 0 || Number(height) <= 0) return scales || []

  var byEffectiveScale = {}
  for (var i = 0; i < scales.length; i++) {
    var requested = Number(scales[i])
    var effective = Number(cleanScale(requested, width, height))

    if (!isFinite(requested) || !isFinite(effective)) continue

    var key = normalizeScale(effective)
    var existing = byEffectiveScale[key]
    if (!existing || Math.abs(requested - effective) < existing.distance) {
      byEffectiveScale[key] = {
        value: String(scales[i]),
        index: i,
        distance: Math.abs(requested - effective)
      }
    }
  }

  return Object.keys(byEffectiveScale)
    .map(function(key) { return byEffectiveScale[key] })
    .sort(function(a, b) { return a.index - b.index })
    .map(function(candidate) { return candidate.value })
}

// Screen-sized distances, in logical pixels, for placing a dragged monitor.
var SHARED_EDGE = 200   // Least shared edge, so the pointer can always cross.
var ALIGN_SNAP = 80     // How close an edge or centre must be to line up.

function isRotated(transform) {
  return Number(transform) % 2 === 1
}

function logicalRect(display) {
  var scale = Number(display.scale) > 0 ? Number(display.scale) : 1
  var w = Math.round(display.width / scale)
  var h = Math.round(display.height / scale)
  return {
    x: display.x,
    y: display.y,
    w: isRotated(display.transform) ? h : w,
    h: isRotated(display.transform) ? w : h
  }
}

function boundsOf(rects) {
  if (!rects.length) return { x: 0, y: 0, w: 0, h: 0 }
  var left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity
  for (var i = 0; i < rects.length; i++) {
    left = Math.min(left, rects[i].x)
    top = Math.min(top, rects[i].y)
    right = Math.max(right, rects[i].x + rects[i].w)
    bottom = Math.max(bottom, rects[i].y + rects[i].h)
  }
  return { x: left, y: top, w: right - left, h: bottom - top }
}

function overlaps(a, b) {
  return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}

// Where along a neighbour's side the rect sits: keep the requested spot while
// enough edge is shared, lining up with the neighbour's ends or centre if near.
function alongSide(value, ownSize, start, size) {
  var shared = Math.min(SHARED_EDGE, ownSize, size)
  var placed = Math.max(start - ownSize + shared, Math.min(start + size - shared, value))
  var stops = [start, start + size - ownSize, start + (size - ownSize) / 2]
  var best = placed
  var bestDistance = ALIGN_SNAP
  for (var i = 0; i < stops.length; i++) {
    var distance = Math.abs(stops[i] - value)
    if (distance < bestDistance) {
      best = stops[i]
      bestDistance = distance
    }
  }
  return Math.round(best)
}

// The nearest spot touching another monitor without covering any of them. A
// gap would strand the pointer and an overlap would hide part of a screen.
function snapPosition(rect, others) {
  var best = { x: rect.x, y: rect.y }
  var bestDistance = Infinity

  function consider(x, y) {
    var candidate = { x: x, y: y, w: rect.w, h: rect.h }
    for (var i = 0; i < others.length; i++)
      if (overlaps(candidate, others[i])) return
    var distance = Math.hypot(x - rect.x, y - rect.y)
    if (distance < bestDistance) {
      best = { x: x, y: y }
      bestDistance = distance
    }
  }

  for (var i = 0; i < others.length; i++) {
    var other = others[i]
    var alongY = alongSide(rect.y, rect.h, other.y, other.h)
    var alongX = alongSide(rect.x, rect.w, other.x, other.w)
    consider(other.x - rect.w, alongY)
    consider(other.x + other.w, alongY)
    consider(alongX, other.y - rect.h)
    consider(alongX, other.y + other.h)
  }
  return best
}

function enabledDisplays(displays) {
  return displays.filter(function(display) { return display.enabled })
}

// Copies of the enabled monitors with `name` placed next to the others, and
// the whole layout shifted so it starts at 0x0.
function placeMonitor(displays, name, changes) {
  var list = enabledDisplays(displays).map(function(display) {
    return Object.assign({}, display, display.name === name ? changes : {})
  })
  var others = list.filter(function(d) { return d.name !== name }).map(logicalRect)
  list.forEach(function(display) {
    if (display.name !== name) return
    var spot = snapPosition(logicalRect(display), others)
    display.x = spot.x
    display.y = spot.y
  })

  var bounds = boundsOf(list.map(logicalRect))
  list.forEach(function(display) {
    display.x -= bounds.x
    display.y -= bounds.y
  })
  return list
}

function sameLayout(a, b) {
  return a.length === b.length && a.every(function(display, i) {
    return display.name === b[i].name && display.x === b[i].x && display.y === b[i].y
  })
}

// Refresh rates of the monitor's current resolution, fastest first.
function refreshRates(display) {
  var seen = {}
  var modes = display && display.availableModes ? display.availableModes : []
  for (var i = 0; i < modes.length; i++) {
    var match = /^(\d+)x(\d+)@([\d.]+)Hz$/.exec(String(modes[i]))
    if (match && Number(match[1]) === display.width && Number(match[2]) === display.height)
      seen[match[3]] = true
  }
  return Object.keys(seen)
    .sort(function(a, b) { return Number(b) - Number(a) })
    .map(function(rate) { return String(Math.round(Number(rate) * 100) / 100) })
}

function parseDisplays(raw) {
  var displays = []
  try {
    displays = raw ? JSON.parse(String(raw)) : []
  } catch (e) {
    displays = []
  }
  if (!Array.isArray(displays)) displays = []

  var count = 0
  for (var i = 0; i < displays.length; i++) {
    if (displays[i] && displays[i].enabled) count++
  }

  return {
    displays: displays,
    enabledDisplayCount: count
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    clampBrightness: clampBrightness,
    normalizeScale: normalizeScale,
    cleanScale: cleanScale,
    matchingScaleIndex: matchingScaleIndex,
    availableScales: availableScales,
    logicalRect: logicalRect,
    boundsOf: boundsOf,
    overlaps: overlaps,
    snapPosition: snapPosition,
    enabledDisplays: enabledDisplays,
    placeMonitor: placeMonitor,
    sameLayout: sameLayout,
    refreshRates: refreshRates,
    parseDisplays: parseDisplays
  }
}
