#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

finish() {
  if [[ -t 0 ]]; then
    echo
    read "?Press Return to close this window."
  fi
}
trap finish EXIT

echo "Installing Kokoro Reader…"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "This version requires an Apple Silicon Mac (M1 or newer)."
  exit 1
fi

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if (( MACOS_MAJOR < 14 )); then
  echo "Kokoro Reader requires macOS 14 or newer."
  exit 1
fi

if ! xcrun --find clang >/dev/null 2>&1; then
  echo "Apple Command Line Tools are required."
  echo "Run: xcode-select --install"
  exit 1
fi

"$ROOT/scripts/install-uv.sh"
"$ROOT/scripts/setup-runtime.sh"
"$ROOT/scripts/download-model.sh"
"$ROOT/scripts/install-app.sh"

echo
echo "Kokoro Reader is installed and running."
echo "Allow it in System Settings → Privacy & Security → Accessibility (Device Control and Data Access on macOS 27)."
