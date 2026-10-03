// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AIMusicSketchpad",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "AIMusicSketchpad", targets: ["AIMusicSketchpad"])
    ],
    targets: [
        .target(name: "SketchSynthDSP", publicHeadersPath: "include"),
        .executableTarget(
            name: "AIMusicSketchpad",
            dependencies: ["SketchSynthDSP"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ],
    cxxLanguageStandard: .cxx17
)
