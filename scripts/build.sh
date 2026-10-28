#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
xcodebuild -project "$ROOT/LongCapture.xcodeproj" -scheme LongCapture \
  -configuration Release -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$ROOT/build/DerivedData" \
  CONFIGURATION_BUILD_DIR="$ROOT/build/Release" ONLY_ACTIVE_ARCH=YES "$@" build
"$ROOT/scripts/verify-signing.sh" "$ROOT/build/Release/LongCapture.app"
swift "$ROOT/scripts/test-app-icon.swift" "$ROOT/build/Release/LongCapture.app"
printf '\nApp: %s/build/Release/LongCapture.app\n' "$ROOT"
