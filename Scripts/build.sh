#!/bin/bash
# Builds Murmur (Release). With --install, replaces /Applications/Murmur.app and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v xcodegen >/dev/null; then
    xcodegen generate --quiet
fi

xcodebuild -project Murmur.xcodeproj -scheme Murmur -configuration Release \
    -derivedDataPath build/DerivedData build | grep -E "error:|warning:|BUILD" || true

APP="build/DerivedData/Build/Products/Release/Murmur.app"
[[ -d "$APP" ]] || { echo "Build failed"; exit 1; }
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Murmur 2>/dev/null || true
    sleep 0.5
    rm -rf /Applications/Murmur.app
    cp -R "$APP" /Applications/
    open /Applications/Murmur.app
    echo "Installed and launched /Applications/Murmur.app"
fi
