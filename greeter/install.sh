#!/bin/bash
# Makes the login screen (SDDM) use the same monitor layout as your session:
# rotation, position, refresh rate and scale set in the corico.monitor panel.
# The lock screen already follows it, since it runs inside your Hyprland.
#
#   greeter/install.sh              install (asks for your password once)
#   greeter/install.sh --uninstall  go back to Omarchy's stock login screen
set -euo pipefail

DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
if [[ -n ${PKEXEC_UID:-} ]]; then
  USER_NAME="$(id -un "$PKEXEC_UID")"
else
  USER_NAME="${SUDO_USER:-$(id -un)}"
fi
STATE=/var/lib/corico-monitor
LUA=/etc/sddm/corico-hyprland.lua
CONF=/etc/sddm.conf.d/20-corico-monitor.conf
SUDO=sudo
[[ $EUID -eq 0 ]] && SUDO=

if [[ ${1:-} == "--uninstall" ]]; then
  $SUDO rm -f "$CONF" "$LUA"
  $SUDO rm -rf "$STATE"
  echo "Login screen back to Omarchy's default."
  exit 0
fi

$SUDO install -d -m 755 -o "$USER_NAME" -g "$USER_NAME" "$STATE"
$SUDO install -D -m 644 "$DIR/hyprland.lua" "$LUA"
printf '[Wayland]\nCompositorCommand=start-hyprland -- --config %s\n' "$LUA" \
  | $SUDO tee "$CONF" >/dev/null
$SUDO chmod 644 "$CONF"

# Write the current layout now, so the next login screen already uses it.
# Run as root (pkexec), there's no Hyprland session to read: the panel writes
# it on its next change, or run: displayctl.py sync-greeter
if [[ $EUID -ne 0 ]]; then
  python3 "$DIR/../displayctl.py" sync-greeter || true
fi
echo "Done. The login screen now follows the display panel."
