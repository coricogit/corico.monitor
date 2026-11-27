#!/usr/bin/env python3
"""Backend for the display panel: reads monitors, applies them live through
Hyprland, and persists them as one-line rules in ~/.config/hypr/monitors.lua.

Those rules use the format omarchy-hyprland-monitor-scaling edits in place, so
the stock scale shortcuts keep working alongside this panel.

Rules name a monitor by its description (make, model and serial) rather than
its connector: connector names like DP-1 can move between monitors across
boots or replugs, which would hand one monitor's rotation and mode to another.

A refresh-rate change can leave a monitor black, so it is applied as a trial:
it stays out of monitors.lua until kept, and a detached process restores the
previous settings when the deadline passes, even if the shell has died.
"""
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

TRIAL_SECONDS = 15
NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")
MODE_RE = re.compile(r"^(\d+)x(\d+)@([\d.]+)Hz$")
RULE_RE = re.compile(r"^hl\.monitor\(\{(.*)\}\)\s*(--.*)?$")
# Descriptions go inside a Lua string, so refuse anything that could end it.
DESC_RE = re.compile(r'^[^"\\\x00-\x1f\x7f]{1,128}$')
FIELD_RE = re.compile(r'(\w+)\s*=\s*("[^"]*"|[^,\s}]+)')
GDK_RE = re.compile(r"^local omarchy_gdk_scale = .*$", re.M)


def monitors_lua():
    return Path(os.environ.get("DISPLAYCTL_MONITORS_LUA",
                               Path.home() / ".config/hypr/monitors.lua"))


def greeter_config():
    return Path(os.environ.get("DISPLAYCTL_GREETER_CONFIG", "/etc/sddm/corico-hyprland.lua"))


def greeter_reads_descriptions():
    try:
        return "corico-monitor-layout: 2" in greeter_config().read_text()
    except OSError:
        return False


def greeter_layout():
    return Path(os.environ.get("DISPLAYCTL_GREETER_LAYOUT",
                               "/var/lib/corico-monitor/greeter-monitors"))


def trial_path():
    return Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "corico-monitor-trial.json"


def hyprctl(*args):
    return subprocess.run(["hyprctl", *args], capture_output=True, text=True,
                          timeout=10, check=True).stdout


def live_monitors():
    return json.loads(hyprctl("monitors", "all", "-j"))


def load_trial():
    try:
        return json.loads(trial_path().read_text())
    except (OSError, ValueError):
        return None


def snapshot(monitor):
    return {key: monitor[key] for key in
            ("name", "description", "width", "height", "refreshRate", "x", "y", "scale",
             "transform") if key in monitor}


def description_of(monitor):
    """The monitor's description if it's safe and specific enough to name it by."""
    desc = str(monitor.get("description") or "").strip()
    return desc if DESC_RE.match(desc) else ""


def unique_description(monitor, live):
    """The description to name a monitor by, or "" to fall back to its connector.

    Twin monitors without serials share a description, which can't tell them
    apart, so those stay named by connector.
    """
    desc = description_of(monitor)
    if desc and sum(description_of(m) == desc for m in live) > 1:
        return ""
    return desc


def validate(request, live):
    """Turn a panel request into a target, rejecting anything Hyprland doesn't offer."""
    name = str(request.get("name", ""))
    monitor = next((m for m in live if m["name"] == name), None)
    if not NAME_RE.match(name) or monitor is None:
        raise ValueError(f"unknown monitor: {name!r}")

    width, height = int(request["width"]), int(request["height"])
    rate = float(request["refreshRate"])
    current = (width == monitor["width"] and height == monitor["height"]
               and abs(rate - monitor["refreshRate"]) < 0.01)
    offered = any(
        (match := MODE_RE.match(mode))
        and int(match[1]) == width and int(match[2]) == height
        and abs(float(match[3]) - rate) < 0.01
        for mode in monitor.get("availableModes", []))
    if not current and not offered:
        raise ValueError(f"{name} does not offer {width}x{height}@{rate}")

    scale = float(request["scale"])
    transform = int(request["transform"])
    if not (math.isfinite(scale) and 0.25 <= scale <= 4) or not 0 <= transform <= 7:
        raise ValueError(f"bad scale or transform for {name}")

    return {"name": name, "description": unique_description(monitor, live),
            "width": width, "height": height, "refreshRate": rate,
            "x": int(request["x"]), "y": int(request["y"]),
            "scale": scale, "transform": transform}


def output_of(target):
    desc = description_of(target)
    return f"desc:{desc}" if desc else target["name"]


def rule_fields(target):
    return {
        "output": f'"{output_of(target)}"',
        "mode": f'"{target["width"]}x{target["height"]}@{target["refreshRate"]:.2f}"',
        "position": f'"{target["x"]}x{target["y"]}"',
        "scale": f'{target["scale"]:g}',
        "transform": str(target["transform"]),
    }


def render_rule(fields):
    return "hl.monitor({ " + ", ".join(f"{k} = {v}" for k, v in fields.items()) + " })"


def differs(target, live):
    monitor = next((m for m in live if m["name"] == target["name"]), None)
    return (monitor is None
            or monitor.get("disabled")
            or target["width"] != monitor["width"]
            or target["height"] != monitor["height"]
            or abs(target["refreshRate"] - monitor["refreshRate"]) >= 0.01
            or target["x"] != monitor["x"]
            or target["y"] != monitor["y"]
            or abs(target["scale"] - monitor["scale"]) >= 0.001
            or target["transform"] != monitor["transform"])


def apply_live(targets, live):
    # Only touch what changed: a rule for an unchanged monitor can still blink it.
    rules = [render_rule(rule_fields(t)) for t in targets if differs(t, live)]
    if not rules:
        return
    output = hyprctl("eval", "\n".join(rules)).strip()
    if output != "ok":
        raise RuntimeError(output or "hyprctl eval failed")


def update_rules(text, targets, gdk_scale=None):
    """Return monitors.lua with a rule per target, keeping any extra fields it had."""
    lines = text.split("\n")
    for target in targets:
        fields = rule_fields(target)
        # A rule by connector name is the one Hyprland applies to this monitor
        # right now, so it is folded into the rule by description.
        outputs = {target["name"]}
        if description_of(target):
            outputs.add("desc:" + description_of(target))
        pattern = re.compile(r'output\s*=\s*"(' + "|".join(map(re.escape, outputs)) + ')"')
        naming = [i for i, line in enumerate(lines)
                  if not line.lstrip().startswith("--") and pattern.search(line)]
        if naming:
            merged, comment = {}, ""
            for index in naming:
                match = RULE_RE.match(lines[index])
                if not match:
                    raise ValueError(f"monitors.lua: can't edit the rule for {target['name']}")
                merged.update(FIELD_RE.findall(match[1]))
                if match[2]:
                    comment = f"  {match[2]}"
            # Two rules for one monitor would leave which one wins up to
            # Hyprland, so keep a single rule where the last one was.
            lines[naming[-1]] = render_rule({**merged, **fields}) + comment
            for index in reversed(naming[:-1]):
                del lines[index]
            continue

        rules = [i for i, line in enumerate(lines) if line.startswith("hl.monitor(")]
        at = rules[-1] + 1 if rules else len(lines)
        lines.insert(at, render_rule(fields))

    result = "\n".join(lines)
    if gdk_scale is not None:
        result = GDK_RE.sub(f"local omarchy_gdk_scale = {gdk_scale}", result)
    return result


def gdk_scale_for(targets):
    # Same rule as omarchy-hyprland-monitor-scaling: GDK_SCALE is session-wide
    # and whole-numbered, so it follows the lowest monitor scale.
    return max(1, math.floor(min(t["scale"] for t in targets) + 0.5))


def persist(targets, previous):
    path = Path(os.path.realpath(monitors_lua()))
    before = {m["name"]: m["scale"] for m in previous}
    scale_changed = any(abs(before.get(t["name"], t["scale"]) - t["scale"]) >= 0.001
                        for t in targets)
    text = path.read_text()
    updated = update_rules(text, targets, gdk_scale_for(targets) if scale_changed else None)
    if updated == text:
        return
    # Hyprland reloads on every write, so swap the whole file in at once.
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".")
    with os.fdopen(fd, "w") as handle:
        handle.write(updated)
    os.chmod(temp, path.stat().st_mode & 0o777)
    os.replace(temp, path)


def greeter_line(monitor, desc=""):
    """One line of the login screen layout: NAME WxH@RATE X Y SCALE TRANSFORM [DESC]."""
    return (f'{monitor["name"]} {int(monitor["width"])}x{int(monitor["height"])}'
            f'@{float(monitor["refreshRate"]):.2f} {int(monitor["x"])} {int(monitor["y"])}'
            f' {float(monitor["scale"]):g} {int(monitor["transform"]) & 7}'
            + (f" {desc}" if desc else ""))


def sync_greeter(targets=(), live=None):
    """Mirror the session layout to the login screen, if greeter/install.sh ran.

    The greeter's Hyprland (greeter/hyprland.lua) reads this file as data, so a
    rotated monitor is rotated on the login screen too.
    """
    path = greeter_layout()
    if not path.parent.is_dir() or not os.access(path.parent, os.W_OK):
        return
    if live is None:
        live = live_monitors()
    chosen = {t["name"]: t for t in targets}
    with_desc = greeter_reads_descriptions()
    lines = []
    for monitor in live:
        if monitor.get("disabled"):
            continue
        merged = {**snapshot(monitor), **chosen.get(monitor["name"], {})}
        if NAME_RE.match(merged["name"]):
            desc = unique_description(monitor, live) if with_desc else ""
            lines.append(greeter_line(merged, desc))
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".")
    with os.fdopen(fd, "w") as handle:
        handle.write("\n".join(lines) + "\n")
    os.chmod(temp, 0o644)
    os.replace(temp, path)


def cmd_sync_greeter():
    sync_greeter()


def cmd_state():
    trial = load_trial()
    monitors = []
    for monitor in live_monitors():
        monitors.append({
            **snapshot(monitor),
            "model": monitor.get("model", ""),
            "focused": bool(monitor.get("focused")),
            "enabled": not monitor.get("disabled"),
            "availableModes": monitor.get("availableModes", []),
        })
    print(json.dumps({"monitors": monitors,
                      "trialDeadline": trial["deadline"] if trial else 0}))


def read_brightness(name):
    try:
        result = subprocess.run(["omarchy-brightness-display", "--monitor", name],
                                capture_output=True, text=True, timeout=8)
        return int(result.stdout.split()[0])
    except (subprocess.SubprocessError, OSError, ValueError, IndexError):
        return None


def cmd_brightness():
    names = [m["name"] for m in live_monitors() if not m.get("disabled")]
    with ThreadPoolExecutor(max_workers=max(1, len(names))) as pool:
        print(json.dumps(dict(zip(names, pool.map(read_brightness, names)))))


def cmd_apply(raw):
    payload = json.loads(raw)
    live = live_monitors()
    targets = [validate(request, live) for request in payload["monitors"]]
    if not targets:
        raise ValueError("no monitors to apply")

    if not payload.get("trial"):
        apply_live(targets, live)
        persist(targets, live)
        sync_greeter(targets, live)
        return

    if load_trial():
        raise RuntimeError("a refresh-rate change is already waiting for confirmation")
    token = uuid.uuid4().hex
    previous = [{**snapshot(m), "description": unique_description(m, live)}
                for m in live if not m.get("disabled")]
    trial_path().write_text(json.dumps({
        "token": token,
        "deadline": time.time() + TRIAL_SECONDS,
        "previous": previous,
        "targets": targets,
        "notice": str(payload.get("notice", ""))[:200],
    }))
    subprocess.Popen([sys.executable, __file__, "rollback", token],
                     start_new_session=True, stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        apply_live(targets, live)
    except Exception:
        trial_path().unlink(missing_ok=True)
        raise


def cmd_keep():
    trial = load_trial()
    if trial:
        trial_path().unlink(missing_ok=True)
        persist(trial["targets"], trial["previous"])
        sync_greeter(trial["targets"])


def restore(trial):
    trial_path().unlink(missing_ok=True)
    apply_live(trial["previous"], live_monitors())


def cmd_revert():
    trial = load_trial()
    if trial:
        restore(trial)


def cmd_rollback(token):
    trial = load_trial()
    if not trial or trial["token"] != token:
        return
    time.sleep(max(0, trial["deadline"] - time.time()))
    trial = load_trial()
    if trial and trial["token"] == token:
        restore(trial)
        if trial.get("notice"):
            subprocess.run(["omarchy-notification-send", trial["notice"]], check=False)


COMMANDS = {"state": cmd_state, "brightness": cmd_brightness, "apply": cmd_apply,
            "keep": cmd_keep, "revert": cmd_revert, "rollback": cmd_rollback,
            "sync-greeter": cmd_sync_greeter}

if __name__ == "__main__":
    try:
        COMMANDS[sys.argv[1]](*sys.argv[2:])
    except Exception as error:  # Shown in the panel, so keep it one line.
        print(str(error).splitlines()[0] if str(error) else repr(error), file=sys.stderr)
        sys.exit(1)
