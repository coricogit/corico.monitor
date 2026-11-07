#!/usr/bin/env python3
"""Backend for the display panel: reads monitors, applies them live through
Hyprland, and persists them as one-line rules in ~/.config/hypr/monitors.lua.

Those rules use the format omarchy-hyprland-monitor-scaling edits in place, so
the stock scale shortcuts keep working alongside this panel.

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
FIELD_RE = re.compile(r'(\w+)\s*=\s*("[^"]*"|[^,\s}]+)')
GDK_RE = re.compile(r"^local omarchy_gdk_scale = .*$", re.M)


def monitors_lua():
    return Path(os.environ.get("DISPLAYCTL_MONITORS_LUA",
                               Path.home() / ".config/hypr/monitors.lua"))


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
            ("name", "width", "height", "refreshRate", "x", "y", "scale", "transform")}


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

    return {"name": name, "width": width, "height": height, "refreshRate": rate,
            "x": int(request["x"]), "y": int(request["y"]),
            "scale": scale, "transform": transform}


def rule_fields(target):
    return {
        "output": f'"{target["name"]}"',
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
        naming = [i for i, line in enumerate(lines)
                  if not line.lstrip().startswith("--")
                  and re.search(r'output\s*=\s*"' + re.escape(target["name"]) + '"', line)]
        if naming:
            index = naming[-1]
            match = RULE_RE.match(lines[index])
            if not match:
                raise ValueError(f"monitors.lua: can't edit the rule for {target['name']}")
            merged = {**dict(FIELD_RE.findall(match[1])), **fields}
            comment = f"  {match[2]}" if match[2] else ""
            lines[index] = render_rule(merged) + comment
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
        return

    if load_trial():
        raise RuntimeError("a refresh-rate change is already waiting for confirmation")
    token = uuid.uuid4().hex
    previous = [snapshot(m) for m in live if not m.get("disabled")]
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
            "keep": cmd_keep, "revert": cmd_revert, "rollback": cmd_rollback}

if __name__ == "__main__":
    try:
        COMMANDS[sys.argv[1]](*sys.argv[2:])
    except Exception as error:  # Shown in the panel, so keep it one line.
        print(str(error).splitlines()[0] if str(error) else repr(error), file=sys.stderr)
        sys.exit(1)
