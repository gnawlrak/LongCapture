# LongCapture

A focused macOS 14+ native scrolling screenshot app, written in Swift.

The app captures a fixed vertical screen region, lets the user scroll manually, stitches confirmed content up or down, then shows a system-like thumbnail that saves a PNG by default or opens a read-only preview.

## Development

Open `LongCapture.xcodeproj`, select the `LongCapture` scheme, and build with Command-B.

Tests run with `xcodebuild test -project LongCapture.xcodeproj -scheme LongCapture -destination 'platform=macOS'`.

The implementation reuses only compatible concepts from ScrollSnap, an MIT-licensed Swift project. See `THIRD_PARTY_NOTICES.md` for attribution.
