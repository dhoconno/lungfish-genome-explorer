// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LungfishGenomeBrowser",
    platforms: [
        .macOS(.v26)  // macOS 26 Tahoe minimum - required for Apple Containerization
    ],
    products: [
        // The main application executable
        .executable(
            name: "Lungfish",
            targets: ["Lungfish"]
        ),
        // Command-line interface for headless operation
        .executable(
            name: "lungfish-cli",
            targets: ["LungfishCLI"]
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
        // Pin transitive plugin providers to releases that are clean under Swift 6.2.
        .package(url: "https://github.com/grpc/grpc-swift.git", exact: "1.27.5"),
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.35.0"),
        // Apple Containerization for running Linux containers on macOS 26+
        // TODO: Re-test AppleContainerRuntime against containerization 0.30.x+
        // and relax this requirement only after the API migration is complete.
        .package(url: "https://github.com/apple/containerization.git", exact: "0.24.5"),
        // App-only updater framework. Keep this out of LungfishApp so lungfish-cli
        // does not inherit the graphical updater dependency.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.1"),
    ],
    targets: [
        .target(
            name: "LungfishTestSupport",
            dependencies: [
                "LungfishCore",
                "LungfishIO",
                "LungfishWorkflow",
            ],
            path: "Tests/Support/LungfishTestSupport"
        ),

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
            dependencies: ["LungfishIO", "LungfishTestSupport"],
            path: "Tests/LungfishIOTests",
            resources: [
                .copy("Resources")
            ]
        ),

        // MARK: - LungfishWorkflow
        .target(
            name: "LungfishWorkflow",
            dependencies: [
                "LungfishCore",
                "LungfishIO",
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
            ],
            path: "Sources/LungfishWorkflow",
            resources: [
                .copy("Resources/Containerization"),
                .copy("Resources/ManagedTools"),
                .copy("Resources/Tools"),
                .copy("Resources/Databases"),
                .copy("Resources/Recipes")
            ]
        ),
        .testTarget(
            name: "LungfishWorkflowTests",
            dependencies: ["LungfishWorkflow"],
            path: "Tests/LungfishWorkflowTests",
            resources: [
                .copy("Resources")
            ]
        ),

        // MARK: - LungfishApp
        .target(
            name: "LungfishApp",
            dependencies: [
                "LungfishCore",
                "LungfishIO",
                "LungfishWorkflow",
            ],
            path: "Sources/LungfishApp",
            resources: [
                .process("Resources/Assets.xcassets"),
                .copy("Resources/Help"),
                .copy("Resources/HelpBook/Lungfish.help"),
                .copy("Resources/Images"),
                .copy("Resources/PrimerSchemes"),
            ]
        ),
        .testTarget(
            name: "LungfishAppTests",
            dependencies: ["LungfishApp", "LungfishCLI"],
            path: "Tests/LungfishAppTests",
            resources: [
                .copy("Fixtures")
            ]
        ),

        // MARK: - Lungfish (Executable)
        .executableTarget(
            name: "Lungfish",
            dependencies: [
                "LungfishApp",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Lungfish",
            resources: [
                .copy("AppIcon.icns"),
            ]
        ),

        // MARK: - LungfishCLI (Command-Line Interface)
        .executableTarget(
            name: "LungfishCLI",
            dependencies: [
                "LungfishCore",
                "LungfishIO",
                "LungfishWorkflow",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/LungfishCLI"
        ),
        .testTarget(
            name: "LungfishCLITests",
            dependencies: ["LungfishCLI", "LungfishIO", "LungfishTestSupport"],
            path: "Tests/LungfishCLITests"
        ),

        // MARK: - Integration Tests
        .testTarget(
            name: "LungfishIntegrationTests",
            dependencies: [
                "LungfishCore",
                "LungfishIO",
                "LungfishWorkflow",
                "LungfishCLI",
                "LungfishApp",
                "LungfishTestSupport",
            ],
            path: "Tests/LungfishIntegrationTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
