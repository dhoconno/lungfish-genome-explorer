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
            targets: ["LungfishCLIExecutable"]
        ),
        .library(name: "LungfishCLILibrary", targets: ["LungfishCLI"]),
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
        // Shared UI kernel extracted from LungfishApp
        .library(
            name: "LungfishKit",
            targets: ["LungfishKit"]
        ),
        // 12S amplicon results UI leaf module extracted from LungfishApp
        .library(
            name: "LungfishTwelveSUI",
            targets: ["LungfishTwelveSUI"]
        ),
        // Alignment results UI leaf module extracted from LungfishApp
        .library(
            name: "LungfishAlignmentUI",
            targets: ["LungfishAlignmentUI"]
        ),
        // Assembly results UI leaf module extracted from LungfishApp
        .library(
            name: "LungfishAssemblyUI",
            targets: ["LungfishAssemblyUI"]
        ),
        // NVD (Novel Virus Diagnostics) results UI leaf module extracted from LungfishApp
        .library(
            name: "LungfishNvdUI",
            targets: ["LungfishNvdUI"]
        ),
        // NAO-MGS metagenomics results UI leaf module extracted from LungfishApp
        .library(
            name: "LungfishNaoMgsUI",
            targets: ["LungfishNaoMgsUI"]
        ),
        // TaxTriage metagenomics results UI leaf module extracted from LungfishApp
        .library(
            name: "LungfishTaxTriageUI",
            targets: ["LungfishTaxTriageUI"]
        ),
        // EsViritu metagenomics results UI leaf module extracted from LungfishApp
        .library(
            name: "LungfishEsVirituUI",
            targets: ["LungfishEsVirituUI"]
        ),
        // MHC Genotype results UI leaf module extracted from LungfishApp
        .library(
            name: "LungfishGenotypeUI",
            targets: ["LungfishGenotypeUI"]
        ),
        // Phylogenetic tree viewer UI leaf module extracted from LungfishApp
        .library(
            name: "LungfishPhylogeneticsUI",
            targets: ["LungfishPhylogeneticsUI"]
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
        // Apple Containerization for running Linux containers on macOS 26+.
        // AppleContainerRuntime is pinned to the 0.24 API surface; newer
        // containerization releases require a deliberate runtime migration.
        .package(url: "https://github.com/apple/containerization.git", exact: "0.24.5"),
        // App-only updater framework. Keep this out of LungfishApp so lungfish-cli
        // does not inherit the graphical updater dependency.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
        // Test-only SwiftUI inspection harness (F3: replaces source-text greps of
        // production .swift files with behavioral view assertions). Only test
        // targets depend on this product; no non-test target imports ViewInspector.
        // Upstream macOS 26 SDK compatibility fix for iOS-only SwiftUI types.
        .package(
            url: "https://github.com/nalexn/ViewInspector",
            revision: "35650956fc0a809ae0492c3af727d9042692d268"
        ),
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
            path: "Sources/LungfishCore",
            exclude: ["AGENTS.md"]
        ),
        .testTarget(
            name: "LungfishCoreTests",
            dependencies: ["LungfishCore", "LungfishTestSupport"],
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
            path: "Sources/LungfishIO",
            exclude: ["AGENTS.md"],
            resources: [
                .copy("Resources/GenotypeWorkbook")
            ]
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
            exclude: ["AGENTS.md"],
            resources: [
                .copy("Resources/Containerization"),
                .copy("Resources/ManagedTools"),
                .copy("Resources/Tools"),
                .copy("Resources/Databases"),
                .copy("Resources/AIHaplotyping"),
                .copy("Resources/MCMHaplotyping"),
                .copy("Resources/Recipes"),
                .copy("Resources/ONTGenotyping"),
                .copy("Resources/PrimerDesignAdapters"),
                .copy("Resources/PrimerOrdering"),
                .copy("Resources/DemoProjects")
            ]
        ),
        .testTarget(
            name: "LungfishWorkflowTests",
            dependencies: [
                "LungfishIO",
                "LungfishWorkflow",
                "LungfishTestSupport",
            ],
            path: "Tests/LungfishWorkflowTests",
            resources: [
                .copy("Resources")
            ]
        ),

        // MARK: - LungfishKit (shared UI kernel)
        .target(
            name: "LungfishKit",
            dependencies: [
                "LungfishCore",
                "LungfishIO",
                "LungfishWorkflow",
            ],
            path: "Sources/LungfishKit",
            exclude: ["AGENTS.md"]
        ),
        .testTarget(
            name: "LungfishKitTests",
            dependencies: ["LungfishKit", "LungfishCore", "LungfishTestSupport", "LungfishKitTestSupport"],
            path: "Tests/LungfishKitTests"
        ),
        // Test doubles for LungfishKit types. Kept apart from
        // LungfishTestSupport so that library stays free of Kit.
        .target(
            name: "LungfishKitTestSupport",
            dependencies: [
                "LungfishKit",
                "LungfishTestSupport",
            ],
            path: "Tests/Support/LungfishKitTestSupport"
        ),

        // MARK: - LungfishTwelveSUI (12S amplicon results UI leaf)
        .target(
            name: "LungfishTwelveSUI",
            dependencies: [
                "LungfishCore",
                "LungfishIO",
                "LungfishWorkflow",
                "LungfishKit",
            ],
            path: "Sources/LungfishTwelveSUI",
            exclude: ["AGENTS.md"]
        ),
        .testTarget(
            name: "LungfishTwelveSUITests",
            dependencies: ["LungfishTwelveSUI", "LungfishKit", "LungfishTestSupport"],
            path: "Tests/LungfishTwelveSUITests"
        ),

        // MARK: - LungfishAlignmentUI (Alignment results UI leaf)
        .target(
            name: "LungfishAlignmentUI",
            dependencies: [
                "LungfishCore",
                "LungfishIO",
                "LungfishWorkflow",
                "LungfishKit",
            ],
            path: "Sources/LungfishAlignmentUI",
            exclude: ["AGENTS.md"]
        ),
        .testTarget(
            name: "LungfishAlignmentUITests",
            dependencies: ["LungfishAlignmentUI", "LungfishKit"],
            path: "Tests/LungfishAlignmentUITests"
        ),

        // MARK: - LungfishAssemblyUI (Assembly results UI leaf)
        .target(
            name: "LungfishAssemblyUI",
            dependencies: [
                "LungfishCore",
                "LungfishIO",
                "LungfishWorkflow",
                "LungfishKit",
            ],
            path: "Sources/LungfishAssemblyUI",
            exclude: ["AGENTS.md"]
        ),
        .testTarget(
            name: "LungfishAssemblyUITests",
            dependencies: ["LungfishAssemblyUI", "LungfishKit"],
            path: "Tests/LungfishAssemblyUITests"
        ),

        // MARK: - LungfishNvdUI (NVD results UI leaf)
        .target(
            name: "LungfishNvdUI",
            dependencies: [
                "LungfishCore",
                "LungfishIO",
                "LungfishWorkflow",
                "LungfishKit",
            ],
            path: "Sources/LungfishNvdUI",
            exclude: ["AGENTS.md"]
        ),
        .testTarget(
            name: "LungfishNvdUITests",
            dependencies: ["LungfishNvdUI", "LungfishKit", "LungfishTestSupport"],
            path: "Tests/LungfishNvdUITests"
        ),

        // MARK: - LungfishNaoMgsUI (NAO-MGS metagenomics results UI leaf)
        .target(
            name: "LungfishNaoMgsUI",
            dependencies: [
                "LungfishCore",
                "LungfishIO",
                "LungfishWorkflow",
                "LungfishKit",
            ],
            path: "Sources/LungfishNaoMgsUI",
            exclude: ["AGENTS.md"]
        ),
        .testTarget(
            name: "LungfishNaoMgsUITests",
            dependencies: ["LungfishNaoMgsUI", "LungfishKit", "LungfishTestSupport"],
            path: "Tests/LungfishNaoMgsUITests"
        ),

        // MARK: - LungfishTaxTriageUI (TaxTriage metagenomics results UI leaf)
        .target(
            name: "LungfishTaxTriageUI",
            dependencies: [
                "LungfishCore",
                "LungfishIO",
                "LungfishWorkflow",
                "LungfishKit",
            ],
            path: "Sources/LungfishTaxTriageUI",
            exclude: ["AGENTS.md"]
        ),
        .testTarget(
            name: "LungfishTaxTriageUITests",
            dependencies: ["LungfishTaxTriageUI", "LungfishKit", "LungfishTestSupport"],
            path: "Tests/LungfishTaxTriageUITests"
        ),

        // MARK: - LungfishEsVirituUI (EsViritu metagenomics results UI leaf)
        .target(
            name: "LungfishEsVirituUI",
            dependencies: [
                "LungfishCore",
                "LungfishIO",
                "LungfishWorkflow",
                "LungfishKit",
            ],
            path: "Sources/LungfishEsVirituUI",
            exclude: ["AGENTS.md"]
        ),
        .testTarget(
            name: "LungfishEsVirituUITests",
            dependencies: ["LungfishEsVirituUI", "LungfishKit", "LungfishTestSupport"],
            path: "Tests/LungfishEsVirituUITests"
        ),

        // MARK: - LungfishGenotypeUI (MHC Genotype results UI leaf)
        .target(
            name: "LungfishGenotypeUI",
            dependencies: [
                "LungfishCore",
                "LungfishIO",
                "LungfishWorkflow",
                "LungfishKit",
            ],
            path: "Sources/LungfishGenotypeUI",
            exclude: ["AGENTS.md"]
        ),
        .testTarget(
            name: "LungfishGenotypeUITests",
            dependencies: ["LungfishGenotypeUI", "LungfishKit", "LungfishTestSupport", .product(name: "ViewInspector", package: "ViewInspector")],
            path: "Tests/LungfishGenotypeUITests"
        ),

        // MARK: - LungfishPhylogeneticsUI (Phylogenetic tree viewer UI leaf)
        .target(
            name: "LungfishPhylogeneticsUI",
            dependencies: [
                "LungfishCore",
                "LungfishIO",
                "LungfishWorkflow",
                "LungfishKit",
            ],
            path: "Sources/LungfishPhylogeneticsUI",
            exclude: ["AGENTS.md"]
        ),
        .testTarget(
            name: "LungfishPhylogeneticsUITests",
            dependencies: ["LungfishPhylogeneticsUI", "LungfishKit", "LungfishIO", "LungfishWorkflow", "LungfishTestSupport"],
            path: "Tests/LungfishPhylogeneticsUITests"
        ),

        // MARK: - LungfishApp
        .target(
            name: "LungfishApp",
            dependencies: [
                "LungfishCore",
                "LungfishIO",
                "LungfishWorkflow",
                "LungfishKit",
                "LungfishTwelveSUI",
                "LungfishAlignmentUI",
                "LungfishAssemblyUI",
                "LungfishNvdUI",
                "LungfishNaoMgsUI",
                "LungfishTaxTriageUI",
                "LungfishEsVirituUI",
                "LungfishGenotypeUI",
                "LungfishPhylogeneticsUI",
            ],
            path: "Sources/LungfishApp",
            exclude: ["AGENTS.md"],
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
            dependencies: ["LungfishApp", "LungfishKit", "LungfishCLI", "LungfishNvdUI", "LungfishNaoMgsUI", "LungfishTaxTriageUI", "LungfishEsVirituUI", "LungfishGenotypeUI", "LungfishPhylogeneticsUI", "LungfishTestSupport", "LungfishKitTestSupport", .product(name: "ViewInspector", package: "ViewInspector")],
            path: "Tests/LungfishAppTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "LungfishAppViewTests",
            dependencies: ["LungfishApp", "LungfishKit", "LungfishCLI", "LungfishNvdUI", "LungfishNaoMgsUI", "LungfishTaxTriageUI", "LungfishEsVirituUI", "LungfishGenotypeUI", "LungfishPhylogeneticsUI", "LungfishTestSupport", "LungfishKitTestSupport", .product(name: "ViewInspector", package: "ViewInspector")],
            path: "Tests/LungfishAppViewTests"
        ),
        .testTarget(
            name: "LungfishAppWorkflowTests",
            dependencies: ["LungfishApp", "LungfishWorkflow", "LungfishKitTestSupport"],
            path: "Tests/LungfishAppWorkflowTests"
        ),

        // MARK: - Lungfish (Executable)
        .executableTarget(
            name: "Lungfish",
            dependencies: [
                "LungfishApp",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Lungfish",
            exclude: ["AGENTS.md"],
            resources: [
                .copy("AppIcon.icns"),
            ]
        ),

        // MARK: - LungfishCLI (Command-Line Interface)
        .target(
            name: "LungfishCLI",
            dependencies: [
                "LungfishCore",
                "LungfishIO",
                "LungfishWorkflow",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/LungfishCLI",
            exclude: ["AGENTS.md"]
        ),
        .executableTarget(
            name: "LungfishCLIExecutable",
            dependencies: ["LungfishCLI"],
            path: "Sources/LungfishCLIExecutable",
            exclude: ["AGENTS.md"]
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
