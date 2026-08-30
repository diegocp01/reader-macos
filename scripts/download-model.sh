#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_ROOT="${KOKORO_READER_HOME:-$HOME/Library/Application Support/Kokoro Reader}"
HF="$INSTALL_ROOT/.venv/bin/hf"
MODEL_DIR="$INSTALL_ROOT/models/Kokoro-82M-bf16"
REVISION="a71e4d38b236d968966a2002c4c895dbd12b1c3c"

if [[ ! -x "$HF" ]]; then
  echo "The local runtime is missing. Run scripts/setup-runtime.sh first."
  exit 1
fi

mkdir -p "$MODEL_DIR"
"$HF" download mlx-community/Kokoro-82M-bf16 \
  --revision "$REVISION" \
  --local-dir "$MODEL_DIR" \
  --include config.json \
  --include kokoro-v1_0.safetensors \
  --include voices/af_heart.safetensors

cd "$MODEL_DIR"
shasum -a 256 -c "$ROOT/support/model-checksums.sha256"
echo "Verified Kokoro MLX model at $MODEL_DIR."
