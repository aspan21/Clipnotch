#!/bin/bash
# Captures the open notch panel into docs/images/<name>.png.
#
# The panel lives above the menu bar and closes as soon as the pointer leaves
# it, so there is no way to frame it from a script: hover the notch, hold
# still, and let the timer fire.
#
#   ./docs/capture.sh pomodoro     # then hover the notch until the shutter
set -euo pipefail
cd "$(dirname "$0")/.."

name="${1:-panel}"
delay="${2:-6}"
out="docs/images/${name}.png"
mkdir -p docs/images

# Panel rect in points, on whichever display has the cutout.
read -r x y w h < <(swift - <<'SWIFT'
import AppKit
let panel = CGSize(width: 660, height: 214)
let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
let frame = screen.frame
// screencapture measures from the top-left of the whole desktop.
let top = (NSScreen.screens.first?.frame.maxY ?? frame.maxY) - frame.maxY
print(Int(frame.midX - panel.width / 2), Int(top), Int(panel.width), Int(panel.height) + 8)
SWIFT
)

echo "Hover the notch and hold still — shutter in ${delay}s…"
screencapture -x -T "$delay" -R"${x},${y},${w},${h}" "$out"
echo "==> ${out}"
