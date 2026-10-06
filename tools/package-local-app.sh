#!/bin/sh
# Personal macOS installation: real ad-hoc signatures, no invented Apple Team ID.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
derived=${KABAN_LOCAL_DERIVED_DATA:-/tmp/kaban-local-app}
xcodebuild -project "$root/Kaban.xcodeproj" -scheme Kaban \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- \
  ENABLE_HARDENED_RUNTIME=YES build
app="$derived/Build/Products/Release/Kaban.app"
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/codesign --verify --strict "$app/Contents/MacOS/KabanDaemon"
/usr/bin/plutil -lint "$app/Contents/Library/LaunchAgents/app.kaban.agent.plist"
printf 'Personal app: %s\n' "$app"
