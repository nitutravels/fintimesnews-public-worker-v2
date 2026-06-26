#!/usr/bin/env bash
set -euo pipefail

cp stories/2026-06-25-india-markets.json private/story.json
rm -rf private/output
mkdir -p private/output

# Patch only the temporary private checkout for compatibility with the
# FFmpeg version on the current GitHub runner. It requires leading zeroes
# in sub-second duration values such as 0.18 instead of .18.
python - <<'PY'
from pathlib import Path

path = Path("private/scripts/create_brand_package.py")
text = path.read_text(encoding="utf-8")
replacements = {
    "d=.18": "d=0.18",
    "d=.28": "d=0.28",
    "d=.35": "d=0.35",
}
for old, new in replacements.items():
    text = text.replace(old, new)
path.write_text(text, encoding="utf-8")
PY

pushd private >/dev/null
python scripts/azure_tts.py --story story.json --output output
python scripts/generate_video.py --story story.json --output output
python scripts/create_brand_package.py \
  --main-video output/fintimes_neural_voice_test_16x9.mp4 \
  --output output
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
