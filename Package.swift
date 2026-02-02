// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LungfishGenomeBrowser",
    platforms: [
        .macOS(.v14)  // macOS 14 Sonoma minimum
    ],
    products: [
        // The main application executable
        .executable(
            name: "Lungfish",
            targets: ["Lungfish"]
        ),
        // Core library for sequence data models and services
        .library(
            name: "LungfishCore",
            targets: ["LungfishCore"]
        ),
        // File format parsing and I/O
        .library(
            name: "LungfishIO",
            targets: ["LungfishIO"]
        ),
        // UI rendering and track system
        .library(
            name: "LungfishUI",
            targets: ["LungfishUI"]
        ),
        // Plugin system
        .library(
            name: "LungfishPlugin",
            targets: ["LungfishPlugin"]
        ),
        // Workflow integration (Nextflow/Snakemake)
        .library(
            name: "LungfishWorkflow",
            targets: ["LungfishWorkflow"]
        ),
        // macOS Application UI components
        .library(
            name: "LungfishApp",
            targets: ["LungfishApp"]
        ),
    ],
    dependencies: [
        // Swift Argument Parser for CLI tools
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // Swift Collections for efficient data structures
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        // Swift Algorithms for sequence algorithms
        .package(url: "https://github.com/apple/swift-algorithms.git", from: "1.2.0"),
        // Swift System for low-level file operations
        .package(url: "https://github.com/apple/swift-system.git", from: "1.3.0"),
        // Swift Async Algorithms for async sequence processing
        .package(url: "https://github.com/apple/swift-async-algorithms.git", from: "1.0.0"),
    ],
    targets: [
        // MARK: - LungfishCore
        .target(
            name: "LungfishCore",
            dependencies: [
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "Algorithms", package: "swift-algorithms"),
            ],
            path: "Sources/LungfishCore"
        ),
        .testTarget(
            name: "LungfishCoreTests",
            dependencies: ["LungfishCore"],
            path: "Tests/LungfishCoreTests"
        ),

        // MARK: - LungfishIO
        .target(
            name: "LungfishIO",
            dependencies: [
                "LungfishCore",
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            ],
            path: "Sources/LungfishIO"
        ),
        .testTarget(
            name: "LungfishIOTests",
            dependencies: ["LungfishIO"],
            path: "Tests/LungfishIOTests",
            resources: [
                .copy("Resources")
            ]
        ),

        // MARK: - LungfishUI
        .target(
            name: "LungfishUI",
            dependencies: [
                "LungfishCore",
                "LungfishIO",
            ],
            path: "Sources/LungfishUI"
        ),
        .testTarget(
            name: "LungfishUITests",
            dependencies: ["LungfishUI"],
            path: "Tests/LungfishUITests"
        ),

        // MARK: - LungfishPlugin
        .target(
            name: "LungfishPlugin",
            dependencies: [
                "LungfishCore",
            ],
            path: "Sources/LungfishPlugin"
        ),
        .testTarget(
            name: "LungfishPluginTests",
            dependencies: ["LungfishPlugin"],
            path: "Tests/LungfishPluginTests"
        ),

        // MARK: - LungfishWorkflow
        .target(
            name: "LungfishWorkflow",
            dependencies: [
                "LungfishCore",
                "LungfishIO",
            ],
            path: "Sources/LungfishWorkflow"
        ),
        .testTarget(
            name: "LungfishWorkflowTests",
            dependencies: ["LungfishWorkflow"],
            path: "Tests/LungfishWorkflowTests"
        ),

        // MARK: - LungfishApp
        .target(
            name: "LungfishApp",
            dependencies: [
                "LungfishCore",
                "LungfishIO",
                "LungfishUI",
                "LungfishWorkflow",
            ],
            path: "Sources/LungfishApp"
        ),

        // MARK: - Lungfish (Executable)
        .executableTarget(
            name: "Lungfish",
            dependencies: [
                "LungfishApp",
            ],
            path: "Sources/Lungfish"
        ),
    ]
)
