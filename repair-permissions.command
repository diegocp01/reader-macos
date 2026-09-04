#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${KOKORO_READER_APPLICATIONS_DIR:-$HOME/Applications}/Kokoro Reader.app"

finish() {
  if [[ -t 0 ]]; then
    echo
    read "?Press Return to close this window."
  fi
}
trap finish EXIT

if [[ ! -d "$APP" ]]; then
  echo "Kokoro Reader is not installed at $APP. Run install.command first."
  exit 1
fi

echo "This clears only Kokoro Reader's selected-text permission."
echo "You will need to enable it again in System Settings. Your model and preferences are kept."
read "?Repair permission? [y/N] " answer
if [[ "$answer" != [yY] ]]; then
  echo "Cancelled."
  exit 0
fi

# Build a current helper so repairs also work with older installed versions
# that do not understand --quit-running. Do not replace the installed app.
"$ROOT/scripts/build.sh"
"$ROOT/.build/app/Kokoro Reader.app/Contents/MacOS/KokoroReader" --quit-running

if ! tccutil reset Accessibility com.local.kokoro-reader; then
  echo "Permission reset failed. Remove Kokoro Reader's entry in Privacy & Security, then add $APP again."
  exit 1
fi

open "$APP"
echo "Click the waveform, then Open Settings if prompted, to request access again."
echo "Enable Kokoro Reader in Privacy & Security → Accessibility (Device Control and Data Access on macOS 27)."
echo "Then select text and click the waveform. If needed, quit and reopen Kokoro Reader once after allowing access."
