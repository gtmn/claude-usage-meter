#!/bin/bash
# Builds build/UsageMeter.app (ad-hoc signed, this Mac only).
# Usage: ./build.sh [--install]   (--install copies it to ~/Applications and launches it)
set -euo pipefail
cd "$(dirname "$0")"

APP=build/UsageMeter.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"

# The macOS 27 SDK makes @State a macro whose plugin only Xcode has; Homebrew builds with the
# Command Line Tools. Use @ViewState (see Views.swift) instead.
if grep -nE '@State[[:space:]]' Sources/*.swift ../*.swift; then
    echo "error: use @ViewState instead of @State (builds without Xcode)" >&2
    exit 1
fi

swiftc -O -swift-version 5 -parse-as-library \
    -target "$(uname -m)-apple-macos14.0" \
    -o "$APP/Contents/MacOS/UsageMeter" \
    ../UsageReader.swift ../History.swift ../ClaudeCodeLogs.swift ../LoginNudge.swift Sources/*.swift

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
