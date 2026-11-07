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


if __name__ == "__main__":
    unittest.main()
