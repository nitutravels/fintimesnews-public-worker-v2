#!/usr/bin/env bash
set -euo pipefail

rm -rf private/output
mkdir -p private/output

pushd private >/dev/null
python scripts/build_daily_story.py --edition midday --history archive/history.json
python scripts/azure_tts.py --story story.json --output output
python scripts/generate_video.py --story story.json --output output
python scripts/create_brand_package.py \
  --main-video output/fintimes_neural_voice_test_16x9.mp4 \
  --output output
python scripts/seo_metadata.py
popd >/dev/null

python scripts/create_dynamic_studio_assets.py \
  --story private/story.json \
  --studio private/output/dynamic_midday_studio.png \
  --foreground private/output/dynamic_midday_foreground.png \
  --thumbnail private/output/thumbnail_16x9.jpg \
  --edition-label "Midday Market Explainer"

test -s private/output/dynamic_midday_studio.png
test -s private/output/dynamic_midday_foreground.png
test -s private/output/thumbnail_16x9.jpg

base64 --decode private/assets/anchor/fintimes_anchor_512.png.b64 \
  > "$RUNNER_TEMP/fintimes-anchor.png"
file "$RUNNER_TEMP/fintimes-anchor.png" | grep -q 'PNG image data'

# Approved intro plus disclaimer occupy the first seven seconds. Use the next
# eighteen seconds for the newsroom presenter segment.
ffmpeg -y \
  -ss 7.0 \
  -i private/output/fintimes_final_16x9.mp4 \
  -t 18.0 -vn -ac 1 -ar 16000 -c:a pcm_s16le \
  "$RUNNER_TEMP/fintimes-anchor-audio.wav"
