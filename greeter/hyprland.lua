-- Hyprland config for the SDDM greeter (login screen) with the monitor layout
-- from the corico.monitor panel: rotation, position, mode and scale.
--
-- Installed as /etc/sddm/corico-hyprland.lua by greeter/install.sh. It loads
-- Omarchy's own greeter config first, so Omarchy updates still reach it, then
-- adds one hl.monitor rule per line of the layout file the panel writes.
--
-- The layout file is data, never code: each line is
--   NAME WIDTHxHEIGHT@RATE X Y SCALE TRANSFORM
-- and anything that doesn't match exactly is ignored. A missing or broken file
-- leaves the stock greeter as it was.

dofile("/usr/share/sddm/hyprland.lua")

local LAYOUT = "/var/lib/corico-monitor/greeter-monitors"
local MAX_LINES = 16

local function apply_layout()
  local file = io.open(LAYOUT, "r")
  if not file then
    return
  end
  local count = 0
  for line in file:lines() do
    count = count + 1
    if count > MAX_LINES then
      break
    end
    local name, width, height, rate, x, y, scale, transform = line:match(
      "^([%w%._%-]+) (%d+)x(%d+)@(%d+%.?%d*) (%-?%d+) (%-?%d+) (%d+%.?%d*) ([0-7])$")
    local s = tonumber(scale)
    if name and #name <= 64 and s and s >= 0.25 and s <= 4 then
      hl.monitor({
        output = name,
        mode = width .. "x" .. height .. "@" .. rate,
        position = x .. "x" .. y,
        scale = s,
        transform = tonumber(transform),
      })
    end
  end
  file:close()
end

-- Never let a bad layout file take the login screen down.
pcall(apply_layout)
