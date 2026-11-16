#!/bin/bash
# Builds the release files into dist/: the app and the claude-usage command, each one binary for
# Apple silicon and Intel Macs, zipped, with checksums and the release notes.
# Usage: .github/package.sh 0.1.9   (the release workflow passes the tag's version)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: .github/package.sh <version>}"
ARCHS="arm64 x86_64"

rm -rf dist
mkdir dist

USAGE_METER_ARCHS="$ARCHS" USAGE_METER_VERSION="$VERSION" MenuBar/build.sh
# ditto keeps the app's signature and bundle structure intact in the zip.
ditto -c -k --keepParent MenuBar/build/UsageMeter.app "dist/UsageMeter-$VERSION.zip"

slices=()
for arch in $ARCHS; do
    swiftc -O -target "$arch-apple-macos14.0" -o "dist/claude-usage-$arch" UsageReader.swift main.swift
    slices+=("dist/claude-usage-$arch")
done
lipo -create "${slices[@]}" -output dist/claude-usage
rm "${slices[@]}"
codesign --force --sign - dist/claude-usage
ditto -c -k dist/claude-usage "dist/claude-usage-$VERSION.zip"
rm dist/claude-usage

(cd dist && shasum -a 256 ./*.zip | sed 's#  \./#  #' > SHA256SUMS.txt)

# Release notes: how to install, and the commits since the previous tag.
ref="v$VERSION"
git rev-parse -q --verify "$ref" >/dev/null || ref=HEAD
previous="$(git describe --tags --abbrev=0 "$ref^" 2>/dev/null || true)"
{
    echo "## Install"
    echo
    echo "**Homebrew** (recommended: it builds on your Mac, so macOS doesn't block it, and \`brew upgrade\` updates it):"
    echo
    echo '```bash'
    echo "brew install gtmn/tap/claude-usage-meter"
    echo '```'
    echo
    echo "**Download:** unzip \`UsageMeter-$VERSION.zip\` and move \`UsageMeter.app\` to Applications."
    echo "It's ad-hoc signed, not notarized, so macOS blocks the first open: open it once, then click"
    echo "**Open Anyway** in System Settings → Privacy & Security. Or remove the quarantine in Terminal:"
    echo
    echo '```bash'
    echo "xattr -dr com.apple.quarantine /Applications/UsageMeter.app"
    echo '```'
    echo
    echo "\`claude-usage-$VERSION.zip\` holds the command-line reader. macOS 14 or later, Apple silicon or Intel."
    echo
    if [ -n "$previous" ]; then
        echo "## Changes since $previous"
        echo
        git log --no-merges --format='- %s' "$previous..$ref"
    fi
} > dist/NOTES.md

echo "Packaged into dist/:"
ls -1 dist
