# Architecture

## Boundaries

- `AppController`: menu-bar entry, one unresolved result, settings persistence, save serialization and interruption notifications. It never processes screen pixels on the main actor.
- `ScreenCapturePermission`: injectable preflight/request/settings adapters with observable current-process access and reentrant-request protection. Launch and refresh never prompt. Menu/settings expose explicit requests; capture requests access before selection, denial offers the system privacy pane, and app activation refreshes the status. The stream adapter defensively rechecks without prompting after selection.
- App identity: certificate-signed Release and Debug have distinct bundle IDs and display names. Settings display the running bundle's identity and path, rather than assuming a same-named privacy toggle authorizes every build. Build verification rejects hash-bound ad-hoc designated requirements.
- `SelectionOverlay`: one display, AppKit bottom-left global selection, local resize/move handles, Return/Escape. `CaptureGeometry` validates and pixel-aligns the rectangle, then converts to ScreenCaptureKit's display-local top-left coordinates.
- `ScreenCaptureController`: injectable `CaptureFrameSource`; ~15 fps ScreenCaptureKit stream, sRGB BGRA, own-application/cursor/audio exclusion. A nonisolated output adapter accepts only complete frames and copies locked pixel buffers before releasing surfaces.
- `FrameProcessingPipeline`: dedicated serial queue, one in-flight and at most one latest pending immutable image. Finish closes intake after source shutdown/barrier, drains the tail, then renders. Cancel drops pending frames. Main-actor session generation and state checks suppress late callbacks.
- `SessionCoordinator`: explicit idle/selecting/starting/capturing/finishing/result states, source and clock injection, startup/finish/cancel arbitration. An unresolved result cannot be replaced by another capture. Interruptions export confirmed pixels with a warning, not an invented match.
- `StitchingController`: synchronous queue-owned engine. A rejected frame never replaces the last reliable anchor. Exact duplicate frames are no-ops. Recovery can return to the anchor or another reliably overlapping view.
- `VisionOffsetEstimator`: three spatial Vision registrations propose document-space offset; overlap pixels, lane errors, texture and alternative-offset ambiguity independently gate commits. Textured edge samples prevent mostly-white margins from masquerading as matching repeated patterns.
- `StitchState`: signed current viewport origin, locked growth direction and independent exported upper/lower extents. Only new pixel rows are copied into strips. Reverse visits move the anchor but neither remove nor duplicate output. The final sRGB RGBA image is assembled once.
- `ResultLifecycle`: injected monotonic clock; thumbnail countdown, pause, preview, saving and resolved transitions. Failed saves require an explicit retry instead of endless auto-save attempts.
- `ResultStore`: ImageIO PNG encoding, same-directory private staging file, fsync, atomic no-replace rename, collision suffixes and deferred staging cleanup. Image ownership stays with the app until success or acknowledged discard.
- `ResultThumbnail` / `PreviewWindowController`: native nonactivating thumbnail and AppKit read-only scroll/zoom/copy/save/discard window. Close routes through one async save. Discard needs ownership acknowledgement so an external save cannot strand the preview.

## Invariants

1. Positive displacement is document-down; first nonzero reliable displacement fixes the growing side.
2. Reliable viewport position is not output length. Reversals never reduce the captured interval.
3. No unvalidated displacement may append pixels. Mismatch retains its anchor and marks an unfinished result incomplete.
4. Output height is `min(50_000, 64_000_000 / width)`. Cropped partial strips remain contiguous at the exact cap.
5. Screen sample buffers never escape their callback; images own copied bytes. Only the processing queue touches stitching state.
6. Ending includes the latest accepted pending complete frame. Cancelling invalidates the generation before awaiting source shutdown.
7. An active result outlives a failed save and blocks new capture. Save, close and discard are idempotent at the owning UI boundary.
8. No screenshot or document content is sent anywhere. There is no networking code or third-party runtime package.
9. A permission request's acknowledgement is not sufficient to unlock capture: current-process preflight must succeed. Only screen-recording access is explicitly requested, and no system permission is modified on the user's behalf.

## Build

The shared Xcode scheme contains an App target (macOS 14) and a hosted XCTest target. Tests skip production status-item/hotkey initialization. Debug uses the current architecture and the `.debug` bundle ID; `scripts/build.sh` produces an optimized, Apple Development-signed local app using the configured team. Test-only code and entitlements do not enter the Release app. `scripts/test-signing.sh` mutates and re-signs a disposable, never-launched copy to verify that the designated requirement stays stable across content changes; this does not prove an actual TCC grant.
