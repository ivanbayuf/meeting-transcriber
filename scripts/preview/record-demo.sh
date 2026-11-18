#!/bin/bash
# Records the real island (top-centre of the main display) while a made-up meeting
# plays through the speakers, for the README demo GIF. Follow the prompts.
# Output: $1 (default ~/Desktop/meeting-transcriber-demo.mov)
set -euo pipefail
OUT="${1:-$HOME/Desktop/meeting-transcriber-demo.mov}"
SECONDS_TOTAL=55

# Region: 760x320 points centred under the notch. Pass the display width in points
# as $2 if it isn't a 14" MacBook Pro (1512 pt).
W="${2:-1512}"
X=$(( (W - 760) / 2 ))

echo "Get ready: island visible, destination = Notion, Groq key verified."
for n in 3 2 1; do echo "  starting in ${n}..."; sleep 1; done
rm -f "$OUT" # screencapture refuses to overwrite an existing file
screencapture -v -k -x -V "$SECONDS_TOTAL" -R"$X,0,760,320" "$OUT" &
REC=$!
sleep 1

echo
echo "▶ NOW: click the MIC in the notch to start recording."
sleep 4
echo "  (the demo meeting is playing — let it run)"
say -v Samantha "Let's lock the Q3 beta launch. We ship to fifty design partners first."
say -v Daniel "Agreed. Onboarding is the risk, so I'll draft a guided first run by Tuesday."
say -v Samantha "Great. Launch date is Friday the twenty first."
echo
echo "▶ NOW: hover the red waveform and click STOP."
sleep 10
echo "▶ When 'Notes ready' shows: click 'Upload to Notion' (or wait if still summarising)."
wait "$REC"
echo
echo "Done → $OUT"
