#!/usr/bin/env bash
set -euo pipefail

pushd private >/dev/null
python ../scripts/finalize_market_metadata.py \
  --metadata output/youtube_metadata.json \
  --story story.json \
  --video output/fintimes_market_2026_06_25_ai_anchor.mp4 \
  --thumbnail output/thumbnail_16x9.jpg
python scripts/youtube_upload.py
popd >/dev/null
