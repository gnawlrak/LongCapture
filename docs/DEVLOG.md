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

## 2026-10-27 - Slice 3: native app and retained results

Contract: menu/hotkey -> adjustable single-display selection -> click-through capture border and Done/Cancel panel -> captured-display thumbnail. A 5-second untouched result saves a lossless PNG; hover pauses, click opens a read-only native preview, normal close saves once, and explicit acknowledged discard never saves. Save failure preserves the only active result and permits directory change/retry.

- Native AppKit selection/toolbar/thumbnail/scroll-and-zoom preview and SwiftUI folder/hotkey settings are wired into the shared Xcode scheme. App delegate and status item are retained correctly. Carbon registration failures retain the menu entry.
- Result model tests preceded implementation. Added atomic no-replace PNG publication/cleanup, clock injection, actual preview close/discard actions, exact-hover-deadline regression, declined-discard protection and settings-state refresh.
- Full Xcode suite: 41 tests, 0 failures. The earlier BGRA assertion incorrectly compared sRGB numbers after conversion into the display-dependent deviceRGB space; it was replaced by exact owned BGRA bytes, sRGB profile and normalized core RGBA pixel tests, not a looser tolerance.
- Release optimized build and strict ad-hoc signature verification pass. The Release process launches without a normal window; actual capture acceptance remains listed as unverified in `docs/ACCEPTANCE.md`.
- Local-only test fixtures and build/test scripts are included. No push, cloud, history, automatic scrolling, editor, notarization or update code was added.
- Stop decision: implementation/build/test delivery is ready; do not invent a passing Safari/TextEdit/WeChat or multi-display acceptance result without the actual permission and user-approved content.

## 2026-10-27 - Slice 4: explicit screen-recording permission

Contract: menu/settings expose permission status, an explicit request, a system privacy-pane link and a refresh action. Starting a capture requests permission before selection; denial leaves the app idle and offers settings guidance. Returning to the app refreshes access. Launch/refresh do not prompt, and an approval response cannot unlock capture unless current-process preflight succeeds.

- Added eight injected tests first. The red run failed because `ScreenCapturePermission` did not exist; after implementation all eight pass. Coverage includes granted/no-repeat, denial, relaunch-required access, external grants/revocation, reentrant prompts and settings-open failure.
- The observable permission adapter owns the only explicit privacy request. The stream adapter retains a defensive preflight without triggering a second request after selection. No Accessibility, Input Monitoring, microphone or system-permission changes were added.
- Settings preserve native controls and show the permission section first. Light/dark offscreen AppKit rendering confirms the controls fit; this is not a live TCC prompt test.
- `swift test`: 36 tests, 0 failures. `./scripts/test.sh`: 49 tests, 0 failures. Logs: `build/permission-tests-red.log`, `build/permission-tests-green.log`, `build/permission-swift-tests.log`, `build/permission-xcode-tests.log`.
- Release build (`build/permission-release-build.log`) and strict signature verification pass. The previous Release app exited through its normal termination delegate; the new process runs with no normal startup window. System grant/deny interaction and real scrolling acceptance remain explicitly unverified.
- Jev classification fell back to `keep_current` / `no_key`; deterministic tests, compiler and diff checks were used directly. Stop decision: permission-entry slice is complete; leave actual system authorization to the user.

## 2026-10-28 - Slice 5: stable application identity for screen permission

Contract: a normal rebuild under the same certificate must not change the app's designated identity. Debug/test-host and Release must not appear as the same application to TCC. Permission guidance must name and show the running bundle rather than merely trusting a same-named system toggle.

- Reproduced in the running old Debug process: preflight false and ScreenCaptureKit content enumeration rejected with -3801, including after relaunch. No screen pixels were collected. The protected TCC database was unavailable; the exact historical grant record is not claimed as inspected.
- Both previous builds had the same bundle ID/display name but different ad-hoc CDHash requirements. The new regression checker first rejected the old Release, then passed after using the already-installed Apple Development certificate. No certificate, keychain trust setting or TCC record was created/reset.
- Split the Debug ID/display name from Release, added running-app identity/path to permission settings, and updated refusal guidance for stale entries. UI remained native; light/dark offscreen rendering checked at the new size.
- Added build-time strict identity verification and a disposable-copy regression: modifying/re-signing content changes the hash while preserving the designated requirement. An initial test command supplied `codesign -R` without the literal `=` prefix; the test harness was corrected using the local man page, then passed. It never modifies or launches the shipped app copy.
- `./scripts/test.sh`: 49 tests, 0 failures. `./scripts/build.sh`, Debug/Release identity verification, `./scripts/test-signing.sh`, shell syntax and diff checks pass. Previous app bundles were backed up before replacement; normal termination preserves active work instead of force-killing.
- The old hash-bound permission may require the user to remove/re-add the new certificate-signed app once. A real new grant and subsequent scrolling capture remain unverified; no check is weakened or permission force-enabled to conceal that boundary.
