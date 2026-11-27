# Display panel for Omarchy

An Omarchy shell bar panel, based on the stock `omarchy.monitor`, for setting up
each monitor:

- Drag-and-drop monitor arrangement
- Orientation (horizontal, upside down, or vertical either way round)
- Refresh rate, from the modes the monitor offers, with a 15-second automatic
  revert unless confirmed
- Brightness per monitor over DDC/CI
- Scale per monitor
- Text size for the whole desktop

Settings persist as one-line rules in `~/.config/hypr/monitors.lua`, one per
monitor. Rules name each monitor by its description (make, model and serial),
such as `desc:BNQ BenQ EX240N ETT3R00580SL0`, not by its connector: connector
names like `DP-1` can move to another monitor after a reboot or a replug. An
older rule by connector name is folded into the description rule the next time
you change that monitor. Twin monitors that report no serial stay named by
connector, since their descriptions can't tell them apart.

## Screenshots

<img src="screenshots/panel.png" alt="The display panel" width="640">

## Requirements

- Omarchy 4.5 or later, on Hyprland with its Lua config
- Python 3, used by `displayctl.py`
- For brightness on external monitors, DDC/CI turned on in the monitor's menu.
  Omarchy's `omarchy-brightness-display` does the work, so there's nothing extra
  to install.

## Install

```bash
omarchy plugin add https://github.com/coricogit/corico.monitor --enable
omarchy plugin disable omarchy.monitor
omarchy restart shell
```

This panel replaces the stock `omarchy.monitor` panel, so keep the stock one
disabled while this one is on. The panel opens from its bar icon or with
`SUPER+CTRL+D`.

The panel only changes `~/.config/hypr/monitors.lua` when you change a setting
in it. Refresh rate changes revert after 15 seconds unless you confirm them.

## Login screen

The lock screen follows the panel on its own, since it runs inside your
Hyprland session. The login screen (SDDM) starts its own Hyprland and ignores
`monitors.lua`, so a rotated monitor shows the login screen sideways. To make it
follow the panel too (rotation, position, refresh rate and scale):

```bash
~/.config/omarchy/plugins/corico.monitor/greeter/install.sh
```

It asks for your password once. It adds `/etc/sddm/corico-hyprland.lua`, which
loads Omarchy's greeter config and then your layout, and points SDDM at it in
`/etc/sddm.conf.d/20-corico-monitor.conf`. From then on, every change you keep
in the panel is also written to `/var/lib/corico-monitor/greeter-monitors`. The
login screen reads that file as plain data (`NAME WxH@RATE X Y SCALE
TRANSFORM` per line) and ignores any line that doesn't match. Undo it with
`greeter/install.sh --uninstall`.

## Remove

```bash
omarchy plugin remove corico.monitor
omarchy plugin enable omarchy.monitor
omarchy restart shell
```

Your monitor rules stay in `~/.config/hypr/monitors.lua`.

## Tests

```bash
node --test tests/
python3 tests/test_displayctl.py
```

## License

MIT, the same license as Omarchy, which this panel is based on. See [LICENSE](LICENSE).
