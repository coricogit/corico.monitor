import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// A portrait wallpaper for every vertical monitor. Omarchy's background crops
// one landscape image onto each screen, which leaves a narrow slice on a
// rotated monitor; when the theme has portrait images in
// ~/.config/omarchy/backgrounds/<theme>/vertical/, this draws one there
// instead: the image named like the current background if there is one, or
// else the first one. Clicks go through to Omarchy's background underneath.
Scope {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME") || ""
  property string imagePath: ""

  // Omarchy doesn't tell plugins when the background or theme changes, so
  // look again every few seconds: a readlink and a one-level directory listing.
  Timer {
    interval: 3000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!resolveProc.running) resolveProc.running = true
  }

  Process {
    id: resolveProc
    command: [
      "bash", "-c",
      'theme=$(cat "$1/.local/state/omarchy/current/theme.name" 2>/dev/null) || exit 0; ' +
      'dir="$1/.config/omarchy/backgrounds/$theme/vertical"; [[ -n $theme && -d $dir ]] || exit 0; ' +
      'current=$(basename "$(readlink -f "$1/.local/state/omarchy/current/background")"); current=${current%.*}; ' +
      'mapfile -t images < <(find "$dir" -maxdepth 1 -type f \\( -iname "*.jpg" -o -iname "*.jpeg" ' +
      '-o -iname "*.png" -o -iname "*.webp" \\) | sort); ' +
      'for image in "${images[@]}"; do name=$(basename "$image"); ' +
      '[[ ${name%.*} == "$current" ]] && { echo "$image"; exit 0; }; done; ' +
      '[[ ${#images[@]} -gt 0 ]] && echo "${images[0]}"',
      "resolve", root.home
    ]
    stdout: StdioCollector {
      onStreamFinished: {
        var path = String(text || "").trim()
        if (path.length > 4096 || path.indexOf("\n") >= 0) path = ""
        if (path !== root.imagePath) root.imagePath = path
      }
    }
  }

  Variants {
    model: root.imagePath !== "" ? Quickshell.screens : []

    PanelWindow {
      id: window
      required property var modelData

      screen: modelData
      // A rotated monitor reports its size already turned.
      visible: modelData.height > modelData.width
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"

      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "corico-vertical-background"
      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      // Take no input, so clicks reach Omarchy's background below.
      mask: Region {}

      Image {
        anchors.fill: parent
        source: root.imagePath !== "" ? "file://" + root.imagePath : ""
        fillMode: Image.PreserveAspectCrop
        sourceSize.width: Math.ceil(window.width * window.modelData.devicePixelRatio)
        sourceSize.height: Math.ceil(window.height * window.modelData.devicePixelRatio)
        asynchronous: true
        cache: false
        smooth: true
      }
    }
  }
}
