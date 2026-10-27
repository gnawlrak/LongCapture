# Development Log

## 2026-10-27 - Slice 1: capture boundary

Contract: a single-display AppKit selection becomes a display-local top-left, Retina-pixel-aligned ScreenCaptureKit crop. Complete BGRA frames must own their bytes after the pixel buffer is unlocked. No Accessibility, Input Monitoring, microphone or network request is made.

- Baseline Xcode build exposed invalid stitching draft, actor-unsafe stream callbacks, an unretained app delegate, and missing test module/testability settings. These were not treated as passing work.
- Capture-specific tests pin negative-origin display geometry, pixel dimensions, cross-screen/small rejection and BGRA copy ownership. The native stream adapter excludes the app/cursor/audio, filters complete samples and runs on its own queue.
- `swift test` with the capture-only package: 3 tests, 0 failures. Log: `build/capture-slice-tests.log`.
- A real permission prompt or live scroll stream has not yet been accepted. Only screen-recording is explicitly requested; system Desktop folder access may still be prompted on save.
- Next slice decision: continue with reliable stitching and recovery, without enabling auto-scroll or adding other product features.
