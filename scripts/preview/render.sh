#!/bin/bash
# Regenerates the README preview images. Needs Google Chrome (headless screenshot).
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 scripts/preview/make_preview.py
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
  --window-size=2232,816 --screenshot="$PWD/docs/preview/steps.png" "file://$PWD/docs/preview/steps.html" 2>/dev/null
rm docs/preview/steps.html
echo "Built docs/preview/journey.svg and docs/preview/steps.png"
