#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/app/Kokoro Reader.app"
CONTENTS="$APP/Contents"

cd "$ROOT"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
xcrun clang \
  -fobjc-arc \
  -fmodules-cache-path="$ROOT/.build/clang-cache" \
  -mmacosx-version-min=14.0 \
  -framework Cocoa \
  -framework ApplicationServices \
  -framework AVFoundation \
  -framework ServiceManagement \
  "$ROOT/Sources/KokoroReader/main.m" \
  -o "$CONTENTS/MacOS/KokoroReader"
cp "$ROOT/python/engine.py" "$CONTENTS/Resources/engine.py"

cp "$ROOT/support/Info.plist.template" "$CONTENTS/Info.plist"
codesign --force --deep --sign - "$APP"

echo "$APP"
