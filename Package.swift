// swift-tools-version: 6.0

import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

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
                .unsafeFlags(["-F", packageRoot, "-Xcc", "-Wno-incomplete-umbrella"])
            ],
            linkerSettings: [
                .unsafeFlags(["-F", packageRoot, "-framework", "WebRTC", "-Xlinker", "-rpath", "-Xlinker", packageRoot])
            ]
        )
    ]
)
