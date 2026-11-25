#!/bin/bash
# Construit « Renommage Audio.app » et le zip téléchargeable.
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="dist/Renommage Audio.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/RenommageAudio" "$APP/Contents/MacOS/RenommageAudio"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Signature ad hoc : nécessaire pour que macOS accepte l'exécutable sur Apple Silicon.
codesign --force --deep --sign - "$APP"

cd dist
ditto -c -k --sequesterRsrc --keepParent "Renommage Audio.app" "Renommage-Audio-macOS.zip"
echo "Terminé : dist/Renommage-Audio-macOS.zip"
