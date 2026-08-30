#!/bin/zsh
set -euo pipefail

APP="$HOME/Applications/Kokoro Reader.app"
DATA="$HOME/Library/Application Support/Kokoro Reader"
STAMP="$(date +%Y%m%d-%H%M%S)"
TRASH="$HOME/.Trash/Kokoro Reader uninstall $STAMP"

echo "This moves the app, model, and local runtime to the Trash."
read "?Continue? [y/N] " answer
if [[ "$answer" != [yY] ]]; then
  echo "Cancelled."
  exit 0
fi

pkill -TERM -x KokoroReader 2>/dev/null || true
mkdir -p "$TRASH"
[[ ! -e "$APP" ]] || mv "$APP" "$TRASH/"
[[ ! -e "$DATA" ]] || mv "$DATA" "$TRASH/"
tccutil reset Accessibility com.local.kokoro-reader 2>/dev/null || true

echo "Kokoro Reader was moved to: $TRASH"
