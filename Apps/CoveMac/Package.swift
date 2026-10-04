// swift-tools-version:6.0
//
// The Cove macOS app. Kept separate from the root package so the shared
// libraries stay buildable on Linux, while macOS-only dependencies (Sparkle,
// KeyboardShortcuts) live here.
//
// Build:   swift build -c release --package-path Apps/CoveMac
// Bundle:  scripts/bundle-app.sh   (produces dist/Cove.app)
//
// The root package is referenced by path; SwiftPM names a path dependency
// after its directory, so the repository folder must be named `cove`.

import PackageDescription

let package = Package(
    name: "CoveMac",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Cove",
            dependencies: [
                .product(name: "CoveCore", package: "cove"),
                .product(name: "CoveUI", package: "cove"),
                .product(name: "CoveSystem", package: "cove"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/Cove",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
