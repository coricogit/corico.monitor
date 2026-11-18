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


LANDSCAPE = {**TARGET, "name": "DP-3", "x": 1080, "transform": 0}
WORKSPACE_RULE = ('hl.workspace_rule({ workspace = "m[DP-1]", '
                  'layout_opts = { orientation = "top", direction = "down" } })')


class Orientation(unittest.TestCase):
    def test_vertical_monitor_gets_a_workspace_rule(self):
        block = d.orientation_block([TARGET, LANDSCAPE], {})
        self.assertEqual(block, [d.BLOCK_START, WORKSPACE_RULE, d.BLOCK_END])

    def test_nothing_to_adapt_means_no_block(self):
        self.assertEqual(d.orientation_block([LANDSCAPE], {}), [])
        flipped = {**LANDSCAPE, "transform": 2}
        self.assertEqual(d.orientation_block([flipped], {}), [])

    def test_bound_inputs_follow_their_monitor(self):
        flipped = {**LANDSCAPE, "transform": 2}
        block = d.orientation_block([TARGET, flipped], {"tablet": "DP-1", "touchdevice": "DP-3"})
        self.assertIn("hl.config({ input = { tablet = { transform = 1 } } })", block)
        self.assertIn("hl.config({ input = { touchdevice = { transform = 2 } } })", block)

    def test_input_on_upright_or_missing_monitor_is_left_alone(self):
        block = d.orientation_block([TARGET, LANDSCAPE], {"tablet": "DP-3", "touchdevice": "HDMI-A-1"})
        self.assertEqual(block, [d.BLOCK_START, WORKSPACE_RULE, d.BLOCK_END])

    def test_block_goes_after_the_monitor_rules(self):
        text = d.update_rules(STOCK, [TARGET])
        lines = d.update_orientation_block(text, d.orientation_block([TARGET], {})).split("\n")
        at = lines.index(d.BLOCK_START)
        self.assertEqual(lines[at - 1], RULE)
        self.assertEqual(lines[at + 1], WORKSPACE_RULE)

    def test_block_is_replaced_in_place_and_removed(self):
        text = d.update_rules(STOCK, [TARGET])
        once = d.update_orientation_block(text, d.orientation_block([TARGET], {}))
        twice = d.update_orientation_block(once, d.orientation_block([TARGET], {}))
        self.assertEqual(once, twice)
        self.assertEqual(d.update_orientation_block(once, []), text)

    def test_new_monitor_rule_lands_before_the_block(self):
        text = d.update_orientation_block(d.update_rules(STOCK, [TARGET]),
                                          d.orientation_block([TARGET], {}))
        lines = d.update_rules(text, [LANDSCAPE]).split("\n")
        self.assertLess(next(i for i, l in enumerate(lines) if 'output = "DP-3"' in l),
                        lines.index(d.BLOCK_START))

    def test_persist_writes_the_block(self):
        import os
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "monitors.lua"
            path.write_text(STOCK)
            os.environ["DISPLAYCTL_MONITORS_LUA"] = str(path)
            try:
                d.persist([TARGET], [TARGET], inputs={})
                self.assertIn(WORKSPACE_RULE, path.read_text())
                d.persist([{**TARGET, "transform": 0}], [TARGET], inputs={})
                self.assertNotIn(d.BLOCK_START, path.read_text())
                self.assertIn("omarchy_gdk_scale = 2", path.read_text())
            finally:
                del os.environ["DISPLAYCTL_MONITORS_LUA"]


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
