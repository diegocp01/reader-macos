#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/.build/app/Kokoro Reader.app"
APPLICATIONS_DIR="${KOKORO_READER_APPLICATIONS_DIR:-$HOME/Applications}"
DESTINATION="$APPLICATIONS_DIR/Kokoro Reader.app"

# Always build the current source; a previous checkout's helper may not
# understand --quit-running and must not be executed with that argument.
"$ROOT/scripts/build.sh"

# Synced folders may reattach metadata after the build has finished.
xattr -cr "$SOURCE"
codesign --verify --deep --strict --verbose=2 "$SOURCE"
"$SOURCE/Contents/MacOS/KokoroReader" --quit-running
mkdir -p "$APPLICATIONS_DIR"
ditto "$SOURCE" "$DESTINATION"
# Copying into a synced Applications folder can add signing-invalid metadata.
xattr -cr "$DESTINATION"
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
echo "If text access is still denied despite an enabled switch, run repair-permissions.command."
