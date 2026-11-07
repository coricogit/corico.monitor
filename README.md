# Display panel for Omarchy

An Omarchy shell bar panel, based on the stock `omarchy.monitor`, for setting up
each monitor:

- Drag-and-drop monitor arrangement
- Orientation (horizontal or vertical, either way round)
- Refresh rate, from the modes the monitor offers, with a 15-second automatic
  revert unless confirmed
- Brightness per monitor over DDC/CI
- Scale per monitor
- Text size for the whole desktop

Settings persist as one-line rules in `~/.config/hypr/monitors.lua`.

## Screenshots

<img src="screenshots/panel.png" alt="The display panel" width="320">

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
