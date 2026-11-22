import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "displayctl", Path(__file__).parent.parent / "displayctl.py")
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)

STOCK = '''-- Configure a specific monitor.
-- hl.monitor({ output = "DP-1", mode = "2560x1440@144", position = "0x0", scale = 1 })
local omarchy_monitor_scale = "auto"
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })

local omarchy_gdk_scale = 2
hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))'''
TARGET = {"name": "DP-1", "width": 1920, "height": 1080, "refreshRate": 165.0,
          "x": 0, "y": 0, "scale": 1.25, "transform": 1}
LIVE = [{"name": "DP-1", "width": 1920, "height": 1080, "refreshRate": 60.0, "x": 0, "y": 0,
         "scale": 1, "transform": 0, "availableModes": ["1920x1080@165.00Hz", "1920x1080@60.00Hz"]}]
RULE = 'hl.monitor({ output = "DP-1", mode = "1920x1080@165.00", position = "0x0", scale = 1.25, transform = 1 })'


class Rules(unittest.TestCase):
    def test_adds_after_catch_all_and_skips_comments(self):
        lines = d.update_rules(STOCK, [TARGET]).split("\n")
        self.assertEqual(lines[4], RULE)
        self.assertTrue(lines[1].startswith("-- hl.monitor"))
        self.assertTrue(lines[3].startswith('hl.monitor({ output = ""'))

    def test_second_save_updates_in_place(self):
        once = d.update_rules(STOCK, [TARGET])
        twice = d.update_rules(once, [{**TARGET, "x": 1080}])
        self.assertEqual(twice.count('output = "DP-1", mode'), 2)  # comment + rule
        self.assertIn('position = "1080x0"', twice)

    def test_keeps_extra_fields_and_comment(self):
        text = 'hl.monitor({ output = "DP-1", mode = "preferred", vrr = 1 }) -- gaming'
        result = d.update_rules(text, [TARGET])
        self.assertIn("vrr = 1", result)
        self.assertTrue(result.endswith("-- gaming"))

    def test_refuses_multiline_rule(self):
        with self.assertRaises(ValueError):
            d.update_rules('hl.monitor({\n  output = "DP-1",\n})', [TARGET])

    def test_gdk_scale(self):
        self.assertIn("omarchy_gdk_scale = 1\n", d.update_rules(STOCK, [TARGET], 1))
        self.assertEqual(d.gdk_scale_for([TARGET, {**TARGET, "scale": 2}]), 1)


class Validate(unittest.TestCase):
    def test_accepts_offered_mode(self):
        self.assertEqual(d.validate(TARGET, LIVE)["refreshRate"], 165.0)

    def test_rejects_unknown_rate(self):
        with self.assertRaises(ValueError):
            d.validate({**TARGET, "refreshRate": 240}, LIVE)

    def test_rejects_lua_injection_in_name(self):
        with self.assertRaises(ValueError):
            d.validate({**TARGET, "name": 'DP-1" }) os.execute("x") --'}, LIVE)

    def test_rejects_bad_scale(self):
        for scale in (0, 9, float("nan")):
            with self.assertRaises(ValueError):
                d.validate({**TARGET, "scale": scale}, LIVE)


class Greeter(unittest.TestCase):
    LIVE = [
        {"name": "DP-1", "width": 1920, "height": 1080, "refreshRate": 165.003,
         "x": 0, "y": 120, "scale": 1.0, "transform": 0},
        {"name": "DP-3", "width": 1920, "height": 1200, "refreshRate": 59.95,
         "x": 1920, "y": 0, "scale": 1.0, "transform": 0},
        {"name": "HDMI-A-1", "width": 1, "height": 1, "refreshRate": 60,
         "x": 0, "y": 0, "scale": 1.0, "transform": 0, "disabled": True},
    ]

    def sync(self, targets=()):
        import os, tempfile
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "greeter-monitors"
            os.environ["DISPLAYCTL_GREETER_LAYOUT"] = str(path)
            try:
                d.sync_greeter(targets, self.LIVE)
                return path.read_text()
            finally:
                del os.environ["DISPLAYCTL_GREETER_LAYOUT"]

    def test_writes_live_layout_and_skips_disabled(self):
        self.assertEqual(self.sync(),
                         "DP-1 1920x1080@165.00 0 120 1 0\n"
                         "DP-3 1920x1200@59.95 1920 0 1 0\n")

    def test_rotation_from_targets_wins(self):
        rotated = {**self.LIVE[1], "transform": 1, "x": 1920, "y": 0}
        self.assertIn("DP-3 1920x1200@59.95 1920 0 1 1\n", self.sync([rotated]))

    def test_drops_names_that_could_break_the_line(self):
        live = [{**self.LIVE[0], "name": "DP-1 0x0@60 0 0 1 0\nX"}]
        self.LIVE, saved = live, self.LIVE
        try:
            self.assertEqual(self.sync(), "\n")
        finally:
            self.LIVE = saved

    def test_skips_when_not_installed(self):
        import os
        os.environ["DISPLAYCTL_GREETER_LAYOUT"] = "/nonexistent-dir/greeter-monitors"
        try:
            d.sync_greeter([], self.LIVE)  # no error, nothing written
        finally:
            del os.environ["DISPLAYCTL_GREETER_LAYOUT"]


if __name__ == "__main__":
    unittest.main()
