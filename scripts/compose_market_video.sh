#!/usr/bin/env bash
set -euo pipefail

ffmpeg -y \
  -loop 1 -i private/output/anchor_studio.png \
  -i "$RUNNER_TEMP/fintimes-presenter.mp4" \
  -filter_complex "[1:v]scale=570:570:force_original_aspect_ratio=increase,crop=570:570[presenter];[0:v][presenter]overlay=45:145:shortest=1,format=yuv420p[v]" \
  -map "[v]" -map 1:a:0 -t 6.0 \
  -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -r 30 \
  -c:a aac -b:a 192k -ar 48000 -ac 2 \
  "$RUNNER_TEMP/fintimes-presenter-scene.mp4"

ffmpeg -y \
  -i private/output/fintimes_final_16x9.mp4 \
  -i "$RUNNER_TEMP/fintimes-presenter-scene.mp4" \
  -filter_complex "[1:v]setpts=PTS-STARTPTS+7/TB[studio];[0:v][studio]overlay=0:0:eof_action=pass:repeatlast=0,format=yuv420p[v]" \
  -map "[v]" -map 0:a:0 \
  -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -r 30 \
  -c:a copy -movflags +faststart \
  private/output/fintimes_market_2026_06_25_ai_anchor.mp4

ffprobe -v error -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 \
  private/output/fintimes_market_2026_06_25_ai_anchor.mp4
