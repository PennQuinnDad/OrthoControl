// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OrthoControl",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "OrthoControl",
            path: "Sources/OrthoControl"
        ),
    ]
)
