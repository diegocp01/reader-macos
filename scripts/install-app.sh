#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/.build/app/Kokoro Reader.app"
DESTINATION="$HOME/Applications/Kokoro Reader.app"

if [[ ! -d "$SOURCE" ]]; then
  "$ROOT/scripts/build.sh"
fi

mkdir -p "$HOME/Applications"
ditto "$SOURCE" "$DESTINATION"
codesign --verify --deep --strict --verbose=2 "$DESTINATION"
open "$DESTINATION"

echo "$DESTINATION"
