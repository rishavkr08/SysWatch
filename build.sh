#!/bin/sh
# Builds SysWatch.app next to this script. `./build.sh --install` also copies it to /Applications and launches it.
set -e
cd "$(dirname "$0")"
swift build -c release 2>&1 | tail -n 2
APP=SysWatch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SysWatch "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp AppIcon.icns "$APP/Contents/Resources/"   # regenerate with: swift tools/icon.swift icns A AppIcon.icns
codesign --force --sign - "$APP" 2>/dev/null   # ad-hoc signature: enough for notifications and login items
if [ "$1" = "--install" ]; then
  pkill -x SysWatch 2>/dev/null || true
  rm -rf /Applications/SysWatch.app
  cp -R "$APP" /Applications/
  touch /Applications/SysWatch.app   # make LaunchServices and Notification Center pick up the new icon
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/SysWatch.app
  open /Applications/SysWatch.app
  echo "Installed and launched /Applications/SysWatch.app"
else
  echo "Built ./$APP   (open it with: open $APP   or install with: ./build.sh --install)"
fi
