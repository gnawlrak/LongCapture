#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT/build/GlassUI"
mkdir -p "$OUTPUT"
SOURCES=("$ROOT"/LongCapture/Source/UI/*.swift)
xcrun swiftc -parse-as-library \
  "${SOURCES[@]}" \
  "$ROOT/LongCapture/Source/App/HotKey.swift" \
  "$ROOT/LongCapture/Source/App/LoginItemSettings.swift" \
  "$ROOT/LongCapture/Source/Capture/ScreenCapturePermission.swift" \
  "$ROOT/LongCapture/Source/Core/Stitching.swift" \
  "$ROOT/LongCapture/Source/Core/CaptureDocument.swift" \
  "$ROOT/LongCapture/Source/Core/ResultLifecycle.swift" \
  "$ROOT/scripts/render-ui.swift" -o "$OUTPUT/render-ui"
"$OUTPUT/render-ui" "$OUTPUT" "$@"
