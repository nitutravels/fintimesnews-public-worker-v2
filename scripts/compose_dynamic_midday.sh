#!/usr/bin/env bash
set -euo pipefail

ffmpeg -y \
  -loop 1 -i private/output/dynamic_midday_studio.png \
  -i "$RUNNER_TEMP/fintimes-presenter.mp4" \
  -loop 1 -i private/output/dynamic_midday_foreground.png \
  -filter_complex "[0:v]scale=1280:720,setsar=1,format=rgba[studio];[1:v]scale=350:390:force_original_aspect_ratio=decrease,pad=420:420:(ow-iw)/2:(oh-ih)/2:color=0x06172e,setsar=1,format=rgba[presenter];[studio][presenter]overlay=103:112:shortest=1[base];[2:v]scale=1280:720,setsar=1,format=rgba[desk];[base][desk]overlay=0:0:shortest=1,format=yuv420p[v]" \
  -map "[v]" -map 1:a:0 -shortest \
  -c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p -r 30 \
  -c:a aac -b:a 192k -ar 48000 -ac 2 \
  -movflags +faststart \
  "$RUNNER_TEMP/fintimes-midday-presenter-scene.mp4"

ffmpeg -y \
  -i private/output/fintimes_final_16x9.mp4 \
  -i "$RUNNER_TEMP/fintimes-midday-presenter-scene.mp4" \
  -filter_complex "[1:v]setpts=PTS-STARTPTS+7/TB[studio];[0:v][studio]overlay=0:0:eof_action=pass:repeatlast=0,format=yuv420p[v]" \
  -map "[v]" -map 0:a:0 \
  -c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p -r 30 \
  -c:a copy -movflags +faststart \
  private/output/fintimes_midday_2026_06_26_ai_anchor.mp4

ffprobe -v error -show_entries format=duration,size \
  -of default=noprint_wrappers=1 \
  private/output/fintimes_midday_2026_06_26_ai_anchor.mp4
