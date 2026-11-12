#!/bin/bash
# Builds and runs the scenario checks (wording, projections, error messages).
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O -target "$(uname -m)-apple-macos14.0" -o tests/outlook UsageReader.swift History.swift tests/outlook-src/main.swift
swiftc -O -target "$(uname -m)-apple-macos14.0" -o tests/errors UsageReader.swift LoginNudge.swift tests/errors-src/main.swift
swiftc -O -target "$(uname -m)-apple-macos14.0" -o tests/history UsageReader.swift History.swift ClaudeCodeLogs.swift tests/history-src/main.swift
# Date >= / <= can compile to Foundation symbols macOS lacks (see Date.isAtOrAfter in UsageReader.swift).
if nm -u tests/outlook tests/errors tests/history | grep -qE 'DateV2(ge|le)oiy'; then
    echo "error: a test binary uses Date >= or <=; use isAtOrAfter / isAtOrBefore" >&2
    exit 1
fi
./tests/outlook
echo
./tests/errors
echo
./tests/history
