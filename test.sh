#!/bin/bash
# Builds and runs the scenario checks (wording, projections, error messages).
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O -o tests/outlook UsageReader.swift tests/outlook-src/main.swift
swiftc -O -o tests/errors UsageReader.swift tests/errors-src/main.swift
./tests/outlook
echo
./tests/errors
