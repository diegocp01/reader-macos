#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/.tools"
INSTALLER="$ROOT/.tools/uv-installer.sh"
UV="$ROOT/.tools/uv"
VERSION="0.12.7"

if [[ -x "$UV" && "$("$UV" --version)" == "uv $VERSION" ]]; then
  echo "uv $VERSION is already installed."
  exit 0
fi

curl -LsSf "https://astral.sh/uv/$VERSION/install.sh" -o "$INSTALLER"
UV_INSTALL_DIR="$ROOT/.tools" UV_NO_MODIFY_PATH=1 sh "$INSTALLER"

echo "uv $VERSION installed at $UV"
