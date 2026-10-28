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
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Das CTW-Logo wird nicht versioniert; vorhanden lokal → einbinden, sonst zeigt die App einen Schriftzug.
[ -f Resources/ctw-logo.png ] && cp Resources/ctw-logo.png "$APP/Contents/Resources/"
codesign --force --sign - --identifier de.thorin.mailpilot "$APP"

echo "Fertig: $(pwd)/$APP"
