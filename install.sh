#!/bin/sh
# One-line installer for SysWatch:
#   curl -fsSL https://github.com/rishavkr08/SysWatch/releases/latest/download/install.sh | sh
# Downloads the latest release, checks its SHA-256, installs it to /Applications and opens it.
# Files fetched with curl are not quarantined, so macOS opens the app without the
# "cannot verify the developer" prompt that a browser download of an un-notarized app gets.
set -e
BASE="${SYSWATCH_BASE:-https://github.com/rishavkr08/SysWatch/releases/latest/download}"

[ "$(uname -s)" = Darwin ] || { echo "SysWatch is a macOS app."; exit 1; }
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || { echo "SysWatch needs macOS 14 or later (this Mac has $(sw_vers -productVersion))."; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading SysWatch…"
curl -fL --progress-bar "$BASE/SysWatch.zip" -o "$tmp/SysWatch.zip"
curl -fsSL "$BASE/SHA256SUMS" -o "$tmp/SHA256SUMS"
expected=$(awk '$2 == "SysWatch.zip" { print $1 }' "$tmp/SHA256SUMS")
actual=$(shasum -a 256 "$tmp/SysWatch.zip" | awk '{ print $1 }')
[ -n "$expected" ] && [ "$expected" = "$actual" ] || { echo "Checksum mismatch, not installing. Expected $expected, got $actual."; exit 1; }

ditto -x -k "$tmp/SysWatch.zip" "$tmp"
codesign --verify --strict "$tmp/SysWatch.app" || { echo "The downloaded app's signature is invalid, not installing."; exit 1; }

DEST=/Applications
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

if pkill -x SysWatch 2>/dev/null; then
  i=0; while pgrep -x SysWatch >/dev/null && [ $i -lt 20 ]; do sleep 0.25; i=$((i + 1)); done   # opening before it exits fails with -600
fi
rm -rf "$DEST/SysWatch.app"
ditto "$tmp/SysWatch.app" "$DEST/SysWatch.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/SysWatch.app" 2>/dev/null || true
open "$DEST/SysWatch.app" 2>/dev/null || { sleep 1; open "$DEST/SysWatch.app"; }

echo "Installed $DEST/SysWatch.app. Click Allow when macOS asks about notifications."
