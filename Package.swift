// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Lifetitles",
    platforms: [
        // macOS is set lower than iOS so `swift test` runs on a Mac that has not
        // moved to macOS 26 yet. Raise it when the core needs a macOS 26-only API.
        .macOS(.v15),
        .iOS(.v26),
        .visionOS(.v26),
    ],
    products: [
        .library(name: "LifetitlesCore", targets: ["LifetitlesCore"]),
        .library(name: "LifetitlesApple", targets: ["LifetitlesApple"]),
    ],
    targets: [
        // Platform-independent pipeline. No Apple-only frameworks beyond optional signposts.
        .target(name: "LifetitlesCore"),

        // Microphone, Apple speech recognition, Apple translation and the app engine.
        // Swift 5 language mode for now: these files call Apple frameworks whose concurrency
        // annotations differ between SDK versions, and they could not be built while this
        // was written. Move to Swift 6 once the package builds clean on a Mac.
        .target(
            name: "LifetitlesApple",
            dependencies: ["LifetitlesCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        .testTarget(
            name: "LifetitlesCoreTests",
            dependencies: ["LifetitlesCore"]
        ),
        .testTarget(
            name: "LifetitlesAppleTests",
            dependencies: ["LifetitlesApple", "LifetitlesCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
