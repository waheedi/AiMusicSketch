// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AIMusicSketchpad",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "AIMusicSketchpad", targets: ["AIMusicSketchpad"])
    ],
    targets: [
        .executableTarget(
            name: "AIMusicSketchpad",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
