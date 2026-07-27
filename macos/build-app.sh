#!/bin/bash
# Builds WorktreeManager.app (release) next to this script.
# Needs only Xcode Command Line Tools — no Xcode.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="WorktreeManager.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/WorktreeManager "$APP/Contents/MacOS/WorktreeManager"
cp Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature so macOS runs it without complaint on this machine.
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "Built $PWD/$APP"
echo "Run it with:  open \"$PWD/$APP\""
