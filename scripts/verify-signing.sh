#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/Release/LongCapture.app}"
EXPECTED_ID="${2:-com.gnawlrak.LongCapture}"

codesign --verify --deep --strict "$APP"
IDENTITY="$(codesign -dvv -r- "$APP" 2>&1)"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
if [ "$BUNDLE_ID" != "$EXPECTED_ID" ]; then
  printf 'Wrong application identity: expected %s, found %s\n' "$EXPECTED_ID" "$BUNDLE_ID" >&2
  exit 1
fi
case "$IDENTITY" in
  *Signature=adhoc*|*TeamIdentifier=not\ set*|*'designated => cdhash '*)
    printf 'Unstable ad-hoc identity: screen-recording permission may stop matching after a build.\n' >&2
    exit 1
    ;;
esac
if [[ "$IDENTITY" != *'TeamIdentifier='* || "$IDENTITY" != *'anchor apple'* ]]; then
  printf 'Expected an Apple development identity with a stable designated requirement.\n' >&2
  exit 1
fi
printf 'Stable signing verified: %s\n' "$BUNDLE_ID"
