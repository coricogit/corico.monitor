#!/bin/bash
# Rotates the boot screens (the disk unlock prompt and Plymouth's splash) to
# match how each monitor is turned in your session. It reads the orientation
# from Hyprland and writes it as a kernel parameter per connector:
#   video=<connector>:panel_orientation=<normal|upside_down|left_side_up|right_side_up>
#
#   greeter/boot-rotation.sh              write the parameters and rebuild the boot image
#   greeter/boot-rotation.sh --uninstall  remove them again
#
# Run it from your session again after you rotate a monitor in the panel. The
# kernel only knows connectors, not monitor models, so if you swap cables the
# rotation stays with the port. The kernel honours the parameter only where the
# GPU driver exposes a panel orientation, so it may do nothing on some setups.
set -euo pipefail

DROP_IN=/etc/limine-entry-tool.d/corico-monitor-rotation.conf

rebuild() {
  if command -v limine-mkinitcpio >/dev/null; then
    sudo limine-mkinitcpio
  else
    echo "limine-mkinitcpio not found: rebuild your boot image to apply it." >&2
  fi
}

if [[ ${1:-} == "--uninstall" ]]; then
  sudo rm -f "$DROP_IN"
  rebuild
  echo "Boot screens back to their default orientation."
  exit 0
fi

# Hyprland transform -> panel orientation. Flipped variants (4-7) have no
# kernel equivalent, so they're left alone.
params="$(hyprctl monitors -j | python3 -I -c '
import json, re, sys
names = {0: "normal", 1: "right_side_up", 2: "upside_down", 3: "left_side_up"}
for m in json.load(sys.stdin):
    if m.get("disabled") or m["transform"] not in names or not re.match(r"^[A-Za-z0-9-]+$", m["name"]):
        continue
    print("video=%s:panel_orientation=%s" % (m["name"], names[m["transform"]]))
' | paste -sd' ')"

if [[ -z $params ]]; then
  echo "No monitors found to rotate." >&2
  exit 1
fi

echo "Kernel parameters: $params"
printf 'KERNEL_CMDLINE[default]+=" %s"\n' "$params" | sudo tee "$DROP_IN" >/dev/null
sudo chmod 644 "$DROP_IN"
rebuild
echo "Done. Reboot to see the boot screens rotated."
