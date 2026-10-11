// swift-tools-version: 6.0

import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let nativeFrameworks = ProcessInfo.processInfo.environment["PIXELNOW_NATIVE_FRAMEWORKS"] ?? packageRoot + "/build"

let package = Package(
    name: "PixelNOW",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "PixelNOW", targets: ["PixelNOW"])
    ],
    targets: [
        .target(
            name: "PixelNOW",
            path: ".",
            exclude: [
                "AGENTS.md",
                "LICENSE",
                "README.md",
                "PixelNOWApp.swift",
                "PixelNOW.xcodeproj",
                "Resources",
                "View",
                "ViewModel",
                "WebRTC.framework",
                "GFN/Native",
                "build",
                "scripts",
                "tools",
                "vendor"
            ],
            sources: [
                "Model",
                "App",
                "GFN"
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(["-F", nativeFrameworks])
            ],
            linkerSettings: [
                .unsafeFlags(["-F", nativeFrameworks, "-framework", "NVSTNative", "-Xlinker", "-rpath", "-Xlinker", nativeFrameworks])
            ]
        )
    ]
)
