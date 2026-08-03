// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VideoToGIF",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "VideoToGIF"),
        .testTarget(name: "VideoToGIFTests", dependencies: ["VideoToGIF"]),
    ]
)
