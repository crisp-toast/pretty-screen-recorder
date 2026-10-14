#!/bin/bash
# Package dist/Pretty Studio.app as a drag-to-Applications disk image:
#   dist/Pretty-Studio-<version>.dmg
# Uses dmgbuild (writes the Finder layout directly — no Finder scripting, works headless) from a
# virtualenv on Master Storage. For other Macs, sign with a Developer ID and notarize:
#   PRETTY_SIGN_ID="Developer ID Application: …" PRETTY_NOTARY_PROFILE=<notarytool profile> scripts/make-dmg.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/dist/Pretty Studio.app"
[ -d "$APP" ] || { echo "build first: scripts/build.sh" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUT="$ROOT/dist/Pretty-Studio-$VERSION.dmg"

VENV="${PRETTY_DMG_VENV:-/Volumes/Master Storage/Dev.noindex/pretty-studio/dmg-venv}"
if [ ! -x "$VENV/bin/dmgbuild" ]; then
  echo "→ installing dmgbuild into $VENV" >&2
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --disable-pip-version-check dmgbuild
fi

if [ -n "${PRETTY_SIGN_ID:-}" ]; then
  echo "→ signing with $PRETTY_SIGN_ID" >&2
  codesign --force --options runtime --timestamp --sign "$PRETTY_SIGN_ID" "$APP/Contents/MacOS/pretty"
  codesign --force --options runtime --timestamp --sign "$PRETTY_SIGN_ID" "$APP"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swift scripts/make-dmg-background.swift "$TMP" >/dev/null
tiffutil -cathidpicheck "$TMP/background.png" "$TMP/background@2x.png" -out "$TMP/background.tiff" >/dev/null 2>&1

echo "→ building $OUT" >&2
rm -f "$OUT"
"$VENV/bin/dmgbuild" -s scripts/dmg-settings.py -D app="$APP" -D background="$TMP/background.tiff" \
  -D icon="$ROOT/Resources/AppIcon.icns" "Pretty Studio" "$OUT" >&2

if [ -n "${PRETTY_SIGN_ID:-}" ]; then
  codesign --force --timestamp --sign "$PRETTY_SIGN_ID" "$OUT"
  if [ -n "${PRETTY_NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$OUT" --keychain-profile "$PRETTY_NOTARY_PROFILE" --wait >&2
    xcrun stapler staple "$OUT" >&2
  fi
fi
SIZE="$(du -h "$OUT" | cut -f1)"
echo "{\"ok\": true, \"dmg\": \"$OUT\", \"version\": \"$VERSION\", \"size\": \"$SIZE\", \"signed\": \"${PRETTY_SIGN_ID:-ad-hoc}\"}"
