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
sleep 1

LOGIN_STATUS="$("$DESTINATION/Contents/MacOS/KokoroReader" --launch-at-login-status 2>/dev/null || true)"
if [[ "$LOGIN_STATUS" == "enabled" ]]; then
  echo "Launch at Login: enabled"
else
  echo "Launch at Login: $LOGIN_STATUS"
  echo "If approval is required, enable Kokoro Reader in System Settings > General > Login Items."
fi

echo "$DESTINATION"
