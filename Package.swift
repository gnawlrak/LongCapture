// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LongCaptureCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "LongCaptureCore", targets: ["LongCapture"])],
    targets: [
        .target(name: "LongCapture", path: "LongCapture/Source",
                exclude: ["App", "Core", "UI"], sources: ["Capture"]),
        .testTarget(name: "LongCaptureTests", dependencies: ["LongCapture"], path: "LongCapture/Tests",
                    exclude: ["LongCaptureImageTests.swift", "StitchingTests.swift", "SessionControllerTests.swift", "ResultFlowTests.swift"],
                    sources: ["CaptureGeometryTests.swift"])
    ]
)
