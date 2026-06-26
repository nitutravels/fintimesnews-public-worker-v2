#!/usr/bin/env bash
set -euo pipefail

# Build a restrained split-screen newsroom shot. The presenter is scaled with
# aspect-ratio preservation and padding, never cropped or enlarged to fill the
# panel. A foreground desk and lower-third keep the composition professional
# and visually read as a long studio shot rather than a face close-up.
ffmpeg -y \
  -loop 1 -i private/output/anchor_studio.png \
  -i "$RUNNER_TEMP/fintimes-presenter.mp4" \
  -filter_complex "[0:v]scale=1280:720,setsar=1[studio];[1:v]scale=430:420:force_original_aspect_ratio=decrease,pad=500:440:(ow-iw)/2:(oh-ih)/2:color=0x031a36,setsar=1[presenter];[studio][presenter]overlay=95:145:shortest=1[base];[base]drawbox=x=48:y=500:w=604:h=112:color=0x061d3c@0.97:t=fill,drawbox=x=48:y=500:w=604:h=4:color=0x36deee@1:t=fill,drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf:text='FINTIMES NEWS':fontcolor=white:fontsize=24:x=75:y=530,drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:text='AI NEWS PRESENTER':fontcolor=0x36deee:fontsize=17:x=75:y=566,format=yuv420p[v]" \
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
