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

# Google sign-in (optional): the desktop OAuth client lives in signing/google-oauth.json
# (git-ignored). Without it the app builds fine; "Connect Google" just reports it's unavailable.
OAUTH=signing/google-oauth.json
if [ -f "$OAUTH" ]; then
  read -r GID GSECRET < <(python3 -c 'import json,sys; c=list(json.load(open(sys.argv[1])).values())[0]; print(c["client_id"], c["client_secret"])' "$OAUTH")
  /usr/libexec/PlistBuddy -c "Add :GoogleClientID string $GID" -c "Add :GoogleClientSecret string $GSECRET" "$APP/Contents/Info.plist"
else
  echo "note: $OAUTH not found — building without Google Docs sign-in"
fi
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
