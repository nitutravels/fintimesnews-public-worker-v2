#!/usr/bin/env bash
set -euo pipefail

cp stories/2026-06-25-india-markets.json private/story.json
rm -rf private/output
mkdir -p private/output

pushd private >/dev/null
python scripts/azure_tts.py --story story.json --output output
python scripts/generate_video.py --story story.json --output output
popd >/dev/null

# The approved Fintimes intro, disclaimer, outro and original music are owned by
# the private production repository. Do not replace them with the public safe
# fallback package unless an operator explicitly requests a fallback render.
python private/scripts/create_brand_package.py \
  --main-video private/output/fintimes_neural_voice_test_16x9.mp4 \
  --output private/output

pushd private >/dev/null
python scripts/seo_metadata.py
popd >/dev/null

python scripts/create_market_assets.py \
  --story private/story.json \
  --studio private/output/anchor_studio.png \
  --thumbnail private/output/thumbnail_16x9.jpg

base64 --decode private/assets/anchor/fintimes_anchor_512.png.b64 \
  > "$RUNNER_TEMP/fintimes-anchor.png"
file "$RUNNER_TEMP/fintimes-anchor.png" | grep -q 'PNG image data'

ffmpeg -y \
  -ss 7.0 \
  -i private/output/fintimes_final_16x9.mp4 \
  -t 6.0 -vn -ac 1 -ar 16000 -c:a pcm_s16le \
  "$RUNNER_TEMP/fintimes-anchor-audio.wav"
