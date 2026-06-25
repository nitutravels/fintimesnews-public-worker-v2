#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?source image path required}"
AUDIO="${2:?audio path required}"
RESULT_DIR="${3:-avatar-results}"

IMAGE="$(realpath "$IMAGE")"
AUDIO="$(realpath "$AUDIO")"
RESULT_DIR="$(realpath -m "$RESULT_DIR")"

CACHE_ROOT="$HOME/.cache/fintimes-sadtalker-v1"
REPO="$CACHE_ROOT/SadTalker"
VENV="$CACHE_ROOT/venv"
MARKER="$CACHE_ROOT/install-complete-v1"

mkdir -p "$CACHE_ROOT" "$RESULT_DIR"

if [[ ! -d "$REPO/.git" ]]; then
  rm -rf "$REPO"
  git clone --depth 1 https://github.com/OpenTalker/SadTalker.git "$REPO"
fi

if [[ ! -x "$VENV/bin/python" ]]; then
  python -m venv "$VENV"
fi

if [[ ! -f "$MARKER" ]]; then
  "$VENV/bin/python" -m pip install --upgrade "pip<25" "setuptools<70" wheel
  "$VENV/bin/pip" install \
    torch==1.12.1+cpu \
    torchvision==0.13.1+cpu \
    torchaudio==0.12.1 \
    --extra-index-url https://download.pytorch.org/whl/cpu

  grep -vE '^[[:space:]]*(gradio|TTS)([=<> ]|$)' "$REPO/requirements.txt" \
    | sed 's/^numba[[:space:]]*$/numba==0.56.4/' \
    > "$CACHE_ROOT/requirements-cpu.txt"

  "$VENV/bin/pip" install -r "$CACHE_ROOT/requirements-cpu.txt"
  touch "$MARKER"
fi

cd "$REPO"

if [[ ! -s checkpoints/SadTalker_V0.0.2_256.safetensors ]]; then
  rm -rf checkpoints gfpgan/weights
  bash scripts/download_models.sh
fi

rm -rf "$RESULT_DIR"
mkdir -p "$RESULT_DIR"

export OMP_NUM_THREADS="${OMP_NUM_THREADS:-2}"
export MKL_NUM_THREADS="${MKL_NUM_THREADS:-2}"

"$VENV/bin/python" inference.py \
  --cpu \
  --driven_audio "$AUDIO" \
  --source_image "$IMAGE" \
  --result_dir "$RESULT_DIR" \
  --still \
  --preprocess crop \
  --size 256 \
  --batch_size 1 \
  --expression_scale 0.9

RESULT="$(find "$RESULT_DIR" -maxdepth 1 -type f -name '*.mp4' | sort | tail -n 1)"
test -n "$RESULT"
test -s "$RESULT"
printf '%s\n' "$RESULT"
