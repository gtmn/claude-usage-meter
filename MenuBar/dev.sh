#!/bin/bash
# Runs a dev build in place of the installed copy, then puts the installed one back.
# Usage: ./dev.sh [--rebuild]   (quit the app from its popup, or press Ctrl-C, to end)
#
# Stops the Homebrew service (if it's running) and quits any other copy, so only one copy
# records history and checks the login. Builds build/UsageMeter.app, stamped with
# `git describe` (e.g. 0.1.7-2-gabc1234-dirty), and runs it in this terminal, so its log
# lines show here. When it ends, the service is started again if it was running before.
# Dev builds are unoptimised (-Onone, about 10 s instead of 30), and skipped when nothing that goes
# into the build changed since the last one (`./dev.sh --rebuild` builds anyway).
# Both copies use the same history and settings, so you carry on with your real data.
set -euo pipefail
cd "$(dirname "$0")"

SERVICE=gtmn/tap/claude-usage-meter
LABEL=sh.brew.claude-usage-meter

was_running=false
if command -v brew >/dev/null && launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    was_running=true
fi

restore() {
    if $was_running; then
        echo "Starting the Homebrew copy again…"
        brew services start "$SERVICE" >/dev/null && echo "Homebrew copy running."
    fi
}

VERSION="$(git describe --tags --dirty 2>/dev/null | sed 's/^v//')"
# Everything that goes into the build: the sources, the build script, Info.plist and the version.
STAMP_FILE=build/.dev-stamp
stamp="$( { echo "$VERSION"; cat build.sh Info.plist Sources/*.swift ../UsageReader.swift ../History.swift \
    ../ClaudeCodeLogs.swift ../LoginNudge.swift ../UpdateCheck.swift; } | shasum | cut -d' ' -f1)"
if [ "${1:-}" != "--rebuild" ] && [ -x build/UsageMeter.app/Contents/MacOS/UsageMeter ] \
    && [ "$(cat "$STAMP_FILE" 2>/dev/null)" = "$stamp" ]; then
    echo "Nothing changed since the last dev build; running it again."
else
    USAGE_METER_VERSION="$VERSION" USAGE_METER_OPT=-Onone ./build.sh
    echo "$stamp" > "$STAMP_FILE"
fi

if $was_running; then
    echo "Stopping the Homebrew copy…"
    brew services stop "$SERVICE" >/dev/null
fi
trap restore EXIT
pkill -x UsageMeter 2>/dev/null && sleep 1 || true

echo "Running the dev build. Quit it from its popup (or Ctrl-C) to end."
"$PWD/build/UsageMeter.app/Contents/MacOS/UsageMeter" || true
