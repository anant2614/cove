// swift-tools-version:6.0
//
// Cove — the shared library workspace.
//
// Every module that does not depend on AppKit builds and tests on macOS and
// Linux, so the conversation engine, providers, store and tools can be
// exercised in CI without a Mac. The macOS app (Apps/CoveMac) is a separate
// package that depends on this one and adds the macOS-only dependencies
// (Sparkle, KeyboardShortcuts).

import PackageDescription

let strictSwift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]
// UI-facing modules use Swift 5 mode so AppKit/SwiftUI main-actor isolation
// can be adopted incrementally without blocking builds.
let uiSwift: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Cove",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CoveModels", targets: ["CoveModels"]),
        .library(name: "CoveProviders", targets: ["CoveProviders"]),
        .library(name: "CoveStore", targets: ["CoveStore"]),
        .library(name: "CoveTools", targets: ["CoveTools"]),
        .library(name: "CoveCore", targets: ["CoveCore"]),
        .library(name: "CoveUI", targets: ["CoveUI"]),
        .library(name: "CoveSystem", targets: ["CoveSystem"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-crypto", "3.0.0"..<"4.0.0"),
    ],
    targets: [
        // Shared value types: messages, content parts, tool specs, provider config.
        .target(
            name: "CoveModels",
            path: "Packages/CoveModels/Sources/CoveModels",
            swiftSettings: strictSwift6
        ),
        // LLMProvider protocol, HTTP/SSE plumbing, provider adapters, local discovery.
        .target(
            name: "CoveProviders",
            dependencies: ["CoveModels"],
            path: "Packages/CoveProviders/Sources/CoveProviders",
            swiftSettings: strictSwift6
        ),
        // SQLite (GRDB) database, migrations, repositories, FTS5, attachments, secrets.
        .target(
            name: "CoveStore",
            dependencies: [
                "CoveModels",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ],
            path: "Packages/CoveStore/Sources/CoveStore",
            swiftSettings: strictSwift6
        ),
        // Tool protocol, registry, approval gate, built-in tools.
        .target(
            name: "CoveTools",
            dependencies: ["CoveModels", "CoveProviders"],
            path: "Packages/CoveTools/Sources/CoveTools",
            swiftSettings: strictSwift6
        ),
        // Conversation engine, context builder, prompt templates, model catalog.
        .target(
            name: "CoveCore",
            dependencies: ["CoveModels", "CoveProviders", "CoveStore", "CoveTools"],
            path: "Packages/CoveCore/Sources/CoveCore",
            swiftSettings: strictSwift6
        ),
        // Shared UI: Markdown parsing/highlighting (portable) + SwiftUI views (Apple only).
        .target(
            name: "CoveUI",
            dependencies: ["CoveCore"],
            path: "Packages/CoveUI/Sources/CoveUI",
            swiftSettings: uiSwift
        ),
        // macOS system integration: panels, screenshot, dictation, permissions.
        .target(
            name: "CoveSystem",
            dependencies: ["CoveCore"],
            path: "Packages/CoveSystem/Sources/CoveSystem",
            swiftSettings: uiSwift
        ),

        .testTarget(
            name: "CoveModelsTests",
            dependencies: ["CoveModels"],
            path: "Packages/CoveModels/Tests/CoveModelsTests"
        ),
        .testTarget(
            name: "CoveProvidersTests",
            dependencies: ["CoveProviders"],
            path: "Packages/CoveProviders/Tests/CoveProvidersTests"
        ),
        .testTarget(
            name: "CoveStoreTests",
            dependencies: ["CoveStore"],
            path: "Packages/CoveStore/Tests/CoveStoreTests"
        ),
        .testTarget(
            name: "CoveToolsTests",
            dependencies: ["CoveTools"],
            path: "Packages/CoveTools/Tests/CoveToolsTests"
        ),
        .testTarget(
            name: "CoveCoreTests",
            dependencies: ["CoveCore"],
            path: "Packages/CoveCore/Tests/CoveCoreTests"
        ),
        .testTarget(
            name: "CoveUITests",
            dependencies: ["CoveUI"],
            path: "Packages/CoveUI/Tests/CoveUITests"
        ),
    ]
)
