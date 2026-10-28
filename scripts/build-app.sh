#!/bin/bash
# Baut MailPilot.app (ohne Xcode) und signiert sie ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/MailPilot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MailPilot "$APP/Contents/MacOS/MailPilot"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier de.thorin.mailpilot "$APP"

echo "Fertig: $(pwd)/$APP"
