#!/bin/bash
# Builds dist/Meeting Transcriber.app and dist/MeetingTranscriber.dmg from source.
# Usage: scripts/package.sh            (run from anywhere)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Meeting Transcriber.app"
swift build -c release

rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MeetingRecorder "$APP/Contents/MacOS/MeetingRecorder"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/MeetingRecorder.icns "$APP/Contents/Resources/MeetingRecorder.icns"
# shortcut: ad-hoc signature, so macOS asks for permissions again after every new build;
# sign with a Developer ID (and notarize) to ship to other people without that.
codesign --force --sign - "$APP"

STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp DMG-README.txt "$STAGE/READ ME FIRST.txt"
hdiutil create -quiet -volname "Meeting Transcriber" -srcfolder "$STAGE" -ov -format UDZO dist/MeetingTranscriber.dmg
hdiutil verify -quiet dist/MeetingTranscriber.dmg
rm -rf "$STAGE"
echo "Built dist/MeetingTranscriber.dmg"
