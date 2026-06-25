#!/usr/bin/env bash
set -euo pipefail
chmod +x scripts/run_sadtalker_cpu.sh
timeout 18000 bash scripts/run_sadtalker_cpu.sh \
  "$RUNNER_TEMP/fintimes-anchor.png" \
  "$RUNNER_TEMP/fintimes-anchor-audio.wav" \
  "$RUNNER_TEMP/fintimes-avatar-results"
RESULT="$(find "$RUNNER_TEMP/fintimes-avatar-results" -maxdepth 1 -type f -name '*.mp4' | sort | tail -n 1)"
test -n "$RESULT"
test -s "$RESULT"
cp "$RESULT" "$RUNNER_TEMP/fintimes-presenter.mp4"
