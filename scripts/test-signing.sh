#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/Release/LongCapture.app}"
"$ROOT/scripts/verify-signing.sh" "$APP"

DETAILS="$(codesign -d --verbose=4 -r- "$APP" 2>&1)"
REQUIREMENT="$(printf '%s\n' "$DETAILS" | sed -n 's/^designated => //p')"
AUTHORITY="$(printf '%s\n' "$DETAILS" | sed -n 's/^Authority=//p' | head -n 1)"
BEFORE_HASH="$(printf '%s\n' "$DETAILS" | sed -n 's/^CDHash=//p')"
if [ -z "$REQUIREMENT" ] || [ -z "$AUTHORITY" ] || [ -z "$BEFORE_HASH" ]; then
  printf 'Unable to read signing identity.\n' >&2
  exit 1
fi

TEMP_ROOT="$(mktemp -d "$ROOT/build/signing-regression.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT
COPY="$TEMP_ROOT/LongCapture.app"
ditto "$APP" "$COPY"
/usr/libexec/PlistBuddy -c "Add :LongCaptureSigningRegression string $(uuidgen)" "$COPY/Contents/Info.plist"
codesign --force --sign "$AUTHORITY" -o runtime --timestamp=none "$COPY"
"$ROOT/scripts/verify-signing.sh" "$COPY"

AFTER="$(codesign -d --verbose=4 -r- "$COPY" 2>&1)"
AFTER_REQUIREMENT="$(printf '%s\n' "$AFTER" | sed -n 's/^designated => //p')"
AFTER_HASH="$(printf '%s\n' "$AFTER" | sed -n 's/^CDHash=//p')"
if [ "$BEFORE_HASH" = "$AFTER_HASH" ] || [ "$REQUIREMENT" != "$AFTER_REQUIREMENT" ]; then
  printf 'Signing regression: updated code must change its hash but retain its designated requirement.\n' >&2
  exit 1
fi
codesign --verify --strict -R "=$REQUIREMENT" "$COPY"
printf 'Changed build keeps the original certificate-based identity. No TCC records were changed.\n'
