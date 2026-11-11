#!/bin/bash
# Builds build/UsageMeter.app (ad-hoc signed, this Mac only).
# Usage: ./build.sh [--install]   (--install copies it to ~/Applications and launches it)
set -euo pipefail
cd "$(dirname "$0")"

APP=build/UsageMeter.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"

swiftc -O -swift-version 5 -parse-as-library \
    -target "$(uname -m)-apple-macos14.0" \
    -o "$APP/Contents/MacOS/UsageMeter" \
    ../UsageReader.swift ../History.swift ../ClaudeCodeLogs.swift Sources/*.swift

# Date >= / <= can compile to Foundation symbols macOS lacks (see Date.isAtOrAfter in UsageReader.swift).
if nm -u "$APP/Contents/MacOS/UsageMeter" | grep -qE 'DateV2(ge|le)oiy'; then
    echo "error: the binary uses Date >= or <=; use isAtOrAfter / isAtOrBefore" >&2
    exit 1
fi

codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    mkdir -p "$HOME/Applications"
    pkill -x UsageMeter 2>/dev/null || true
    rm -rf "$HOME/Applications/UsageMeter.app"
    cp -R "$APP" "$HOME/Applications/"
    open "$HOME/Applications/UsageMeter.app"
    echo "Installed and launched ~/Applications/UsageMeter.app"
fi
