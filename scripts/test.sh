#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
xcodebuild -project "$ROOT/LongCapture.xcodeproj" -scheme LongCapture \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$ROOT/build/DerivedData" test "$@"
