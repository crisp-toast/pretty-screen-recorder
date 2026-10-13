#!/bin/bash
# Build Pretty Studio: release CLI + editor app bundle (dist/Pretty Studio.app) + web recorder deps.
# Everything stays inside the repo on Master Storage.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "→ swift build (release)" >&2
nice -n 10 swift build -c release 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" >&2 || true
[ -x .build/release/pretty ] && [ -x .build/release/PrettyStudio ] || { echo "build failed" >&2; exit 1; }

echo "→ app bundle" >&2
APP="$ROOT/dist/Pretty Studio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PrettyStudio "$APP/Contents/MacOS/PrettyStudio"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ ! -f Resources/AppIcon.icns ]; then
  TMP="$(mktemp -d)"
  swift scripts/make-icon.swift "$TMP/icon.png" >/dev/null
  mkdir -p "$TMP/AppIcon.iconset"
  for s in 16 32 64 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2)); sips -z $d $d "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
  cp "$TMP/icon.png" Resources/AppIcon.png
  rm -rf "$TMP"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Ad-hoc signature: no keychain prompt on a headless Mac.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
touch "$APP"

echo "→ web recorder deps" >&2
if [ ! -d web-recorder/node_modules/playwright-core ]; then
  (cd web-recorder && npm install --no-audit --no-fund >/dev/null)
fi

echo "{\"ok\": true, \"cli\": \"$ROOT/.build/release/pretty\", \"app\": \"$APP\"}"
