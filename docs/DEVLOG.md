# Development Log

## 2026-10-27 - Slice 1: capture boundary

Contract: a single-display AppKit selection becomes a display-local top-left, Retina-pixel-aligned ScreenCaptureKit crop. Complete BGRA frames must own their bytes after the pixel buffer is unlocked. No Accessibility, Input Monitoring, microphone or network request is made.

- Baseline Xcode build exposed invalid stitching draft, actor-unsafe stream callbacks, an unretained app delegate, and missing test module/testability settings. These were not treated as passing work.
- Capture-specific tests pin negative-origin display geometry, pixel dimensions, cross-screen/small rejection and BGRA copy ownership. The native stream adapter excludes the app/cursor/audio, filters complete samples and runs on its own queue.
- `swift test` with the capture-only package: 3 tests, 0 failures. Log: `build/capture-slice-tests.log`.
- A real permission prompt or live scroll stream has not yet been accepted. Only screen-recording is explicitly requested; system Desktop folder access may still be prompted on save.
- Next slice decision: continue with reliable stitching and recovery, without enabling auto-scroll or adding other product features.

## 2026-10-27 - Slice 2: confirmed stitching and recovery

Contract: first reliable movement locks the growing side; the viewport anchor moves independently of the exported interval. Reverse visits never erase/duplicate content, 1–3px movements accumulate, rejected matches keep the anchor, and Finish drains the single pending tail before one final composition.

- Test-first fixtures include numbered CoreText documents and deterministic patterns. A real-Vision text test exposed false whitespace ambiguity; alternative-offset validation now samples ink/edges rather than mostly-white margins. Tests verify actual pixel arrays, not just dimensions.
- Added three-region Vision proposals, overlap/texture/ambiguity validation, copied new strips, exact 64M/50K bounds, recoverable mismatch and incomplete export.
- Added queue/source injection tests: single-slot backpressure, tail drain, cancelled late frames, permission failure, safe interruption and startup-failure-after-finish race. The last race was found in review and fixed with state plus generation guards.
- `swift test` with capture/core/session: 28 tests, 0 failures. Log: `build/stitching-slice-tests.log`.
- Completely periodic frames remain intrinsically ambiguous; no guessed movement is committed. Real Safari/TextEdit/WeChat capture is not claimed by these tests.
- Next slice decision: finish native result UI, lossless no-overwrite saving and Release app integration, with no editor/history/cloud scope expansion.
