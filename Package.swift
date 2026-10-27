// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LongCaptureCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "LongCaptureCore", targets: ["LongCapture"])],
    targets: [
        .target(name: "LongCapture", path: "LongCapture/Source",
                exclude: ["App", "Core/ResultLifecycle.swift", "Core/ResultStore.swift", "UI"],
                sources: ["Capture", "Core/Stitching.swift", "Core/StitchingController.swift", "Core/SessionCoordinator.swift"]),
        .testTarget(name: "LongCaptureTests", dependencies: ["LongCapture"], path: "LongCapture/Tests",
                    exclude: ["ResultFlowTests.swift"],
                    sources: ["CaptureGeometryTests.swift", "LongCaptureImageTests.swift", "StitchingTests.swift", "SessionControllerTests.swift"])
    ]
)
