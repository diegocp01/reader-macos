#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UV="$ROOT/.tools/uv"
INSTALL_ROOT="${KOKORO_READER_HOME:-$HOME/Library/Application Support/Kokoro Reader}"

if [[ ! -x "$UV" ]]; then
  echo "uv is missing. Run scripts/install-uv.sh first."
  exit 1
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Kokoro Reader requires an Apple Silicon Mac (M1 or newer)."
  exit 1
fi

mkdir -p "$INSTALL_ROOT"
if [[ ! -x "$INSTALL_ROOT/.venv/bin/python3" ]]; then
  UV_CACHE_DIR="$INSTALL_ROOT/.uv-cache" \
    UV_PYTHON_INSTALL_DIR="$INSTALL_ROOT/.python" \
    "$UV" venv --python 3.12.14 "$INSTALL_ROOT/.venv"
fi
UV_CACHE_DIR="$INSTALL_ROOT/.uv-cache" \
  UV_PYTHON_INSTALL_DIR="$INSTALL_ROOT/.python" \
  "$UV" pip sync \
  --python "$INSTALL_ROOT/.venv/bin/python3" \
  "$ROOT/requirements.txt"

echo "Local Kokoro runtime is ready at $INSTALL_ROOT."
