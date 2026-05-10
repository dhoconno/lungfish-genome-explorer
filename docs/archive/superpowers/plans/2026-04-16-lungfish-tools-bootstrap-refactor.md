# Lungfish Tools Bootstrap Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace bundled BBTools and the bundled JRE with micromamba-managed installs in `~/.lungfish`, surface required setup as a single `Lungfish Tools` pack on the welcome screen, hide inactive packs everywhere, and clean bundled BBTools/JRE out of release packaging.

**Architecture:** Keep the existing one-environment-per-tool model in `CondaManager`, but extend the current `PluginPack` registry so it can represent both the required `Lungfish Tools` pack and optional packs with explicit `isActive` and per-tool health checks. Add a pack-status service shared by workflow, app, and CLI code, then switch BBTools and workflow-engine lookup to deterministic `~/.lungfish/conda/envs/<tool>/bin/...` paths before removing bundled BBTools/JRE resources and their release-script assumptions.

**Tech Stack:** Swift 6.2, SwiftUI/AppKit, Foundation `Process`/`FileManager`, existing `CondaManager`, existing `NativeToolRunner`, Swift Argument Parser, XCTest, Swift Testing, shell release scripts.

---

## File Map

- Create: `Sources/LungfishWorkflow/Conda/PluginPack.swift`
  Responsibility: move `PluginPack` / `PostInstallHook` out of `CondaManager.swift`, add `PluginPackKind`, `PackToolRequirement`, active-pack metadata, required-pack metadata, and filtered registry accessors.
- Create: `Sources/LungfishWorkflow/Conda/PluginPackStatusService.swift`
  Responsibility: shared health-check/install service for required and optional packs, including per-tool diagnostics for `Lungfish Tools`.
- Create: `Sources/LungfishWorkflow/Conda/CoreToolLocator.swift`
  Responsibility: deterministic `~/.lungfish/conda/envs/<tool>` path helpers and shared BBTools environment construction.
- Modify: `Sources/LungfishWorkflow/Conda/CondaManager.swift`
  Responsibility: remove moved registry types, add environment-path helpers, add reinstall support, keep micromamba bootstrap as-is.
- Modify: `Sources/LungfishCLI/Commands/CondaCommand.swift`
  Responsibility: source visible packs from the shared registry, allow `lungfish-tools` installs, hide inactive packs.
- Modify: `Sources/LungfishApp/Views/PluginManager/PluginManagerViewModel.swift`
  Responsibility: read pack status from the shared service, separate required setup from optional packs, support focusing a pack card.
- Modify: `Sources/LungfishApp/Views/PluginManager/PluginManagerView.swift`
  Responsibility: render a `Required Setup` section and an `Optional Tools` section using shared pack-status data.
- Modify: `Sources/LungfishApp/Views/PluginManager/PluginManagerWindowController.swift`
  Responsibility: support opening the Packs tab focused on a specific pack from the welcome screen.
- Modify: `Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift`
  Responsibility: remove `Open Files`, add plain-language setup card, gate launch/recent-project actions on `Lungfish Tools`, keep the welcome window HIG-aligned.
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
  Responsibility: remove welcome-screen open-files wiring and route optional-pack clicks to Plugin Manager.
- Modify: `Sources/LungfishWorkflow/Native/NativeToolRunner.swift`
  Responsibility: resolve BBTools and Java from managed conda environments instead of bundled resources; narrow bundled-tool validation to the actually bundled subset.
- Modify: `Sources/LungfishWorkflow/Engines/NextflowRunner.swift`
  Responsibility: prefer the dedicated `nextflow` environment before falling back to generic PATH discovery.
- Modify: `Sources/LungfishWorkflow/Engines/SnakemakeRunner.swift`
  Responsibility: prefer the dedicated `snakemake` environment before falling back to generic PATH discovery.
- Modify: `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift`
  Responsibility: replace duplicated bundled-JRE environment setup with the shared BBTools environment helper.
- Modify: `Sources/LungfishWorkflow/Recipes/RecipeEngine.swift`
  Responsibility: replace duplicated bundled-JRE environment setup with the shared BBTools environment helper.
- Modify: `Sources/LungfishWorkflow/Extraction/FASTQCLIMaterializer.swift`
  Responsibility: replace duplicated bundled-JRE environment setup with the shared BBTools environment helper.
- Modify: `Sources/LungfishWorkflow/Ingestion/FASTQIngestionPipeline.swift`
  Responsibility: resolve `clumpify.sh` and Java from the managed `bbtools` environment while preserving the existing no-space symlink workaround.
- Modify: `Sources/LungfishApp/Services/FASTQIngestionService.swift`
  Responsibility: replace duplicated bundled-JRE environment setup with the shared BBTools environment helper.
- Modify: `Sources/LungfishApp/Services/FASTQDerivativeService.swift`
  Responsibility: replace duplicated bundled-JRE environment setup with the shared BBTools environment helper.
- Modify: `Sources/LungfishWorkflow/Resources/Tools/tool-versions.json`
  Responsibility: remove bundled `bbtools` and `openjdk` entries once they are no longer shipped.
- Modify: `scripts/bundle-native-tools.sh`
  Responsibility: stop staging bundled BBTools/JRE payloads.
- Modify: `scripts/update-tool-versions.sh`
  Responsibility: stop updating/reporting BBTools/OpenJDK as bundled release assets.
- Modify: `scripts/sanitize-bundled-tools.sh`
  Responsibility: drop BBTools-specific allowlist entries once the bundle no longer contains BBTools.
- Modify: `scripts/release/build-notarized-dmg.sh`
  Responsibility: remove JRE-launcher signing logic.
- Modify: `scripts/smoke-test-release-tools.sh`
  Responsibility: assert BBTools/JRE are absent from the bundle and smoke-test the remaining bundled toolset instead.
- Modify: `README.md`
  Responsibility: describe `~/.lungfish` managed core tools instead of bundled BBTools/JRE.
- Modify: `THIRD-PARTY-NOTICES`
  Responsibility: remove bundled OpenJDK/BBTools notices that no longer apply to the shipped app artifact.
- Create: `Tests/LungfishWorkflowTests/PluginPackRegistryTests.swift`
  Responsibility: verify pack registry structure, required-pack metadata, and active-pack filtering.
- Create: `Tests/LungfishWorkflowTests/PluginPackStatusServiceTests.swift`
  Responsibility: verify pack health detection and pack install/reinstall orchestration.
- Create: `Tests/LungfishWorkflowTests/CoreToolLocatorTests.swift`
  Responsibility: verify deterministic `~/.lungfish` path calculation and shared BBTools environment values.
- Modify: `Tests/LungfishWorkflowTests/CondaManagerTests.swift`
  Responsibility: stop asserting the old 13-pack layout and cover new environment helper/reinstall behavior.
- Modify: `Tests/LungfishWorkflowTests/NativeToolRunnerTests.swift`
  Responsibility: split bundled-tool validation from managed-core-tool resolution.
- Modify: `Tests/LungfishWorkflowTests/FASTQIngestionPipelineTests.swift`
  Responsibility: preserve the path-with-spaces regression check using managed BBTools.
- Modify: `Tests/LungfishWorkflowTests/FASTQToolIntegrationTests.swift`
  Responsibility: use the shared BBTools environment helper instead of building a bundled-JRE environment manually.
- Create: `Tests/LungfishAppTests/PluginPackVisibilityTests.swift`
  Responsibility: verify Plugin Manager separates required setup from active optional packs.
- Create: `Tests/LungfishAppTests/WelcomeSetupTests.swift`
  Responsibility: verify welcome-screen gating and visible actions from a view-model/state perspective.
- Modify: `Tests/LungfishAppTests/DatabasesTabTests.swift`
  Responsibility: keep Plugin Manager tab tests aligned after the packs tab starts using shared pack-status state.
- Create: `Tests/LungfishCLITests/CondaPacksCommandTests.swift`
  Responsibility: verify CLI-visible packs come from the shared registry and exclude inactive packs.
- Modify: `Tests/LungfishAppTests/ReleaseBuildConfigurationTests.swift`
  Responsibility: flip release expectations from “bundle BBTools/JRE” to “do not bundle BBTools/JRE”.

### Task 1: Move Plugin Pack Registry Into A Focused File And Add Required/Active Metadata

**Files:**
- Create: `Sources/LungfishWorkflow/Conda/PluginPack.swift`
- Modify: `Sources/LungfishWorkflow/Conda/CondaManager.swift`
- Create: `Tests/LungfishWorkflowTests/PluginPackRegistryTests.swift`
- Modify: `Tests/LungfishWorkflowTests/CondaManagerTests.swift`

- [ ] **Step 1: Write the failing registry tests**

Create `Tests/LungfishWorkflowTests/PluginPackRegistryTests.swift` with:

```swift
import XCTest
@testable import LungfishWorkflow

final class PluginPackRegistryTests: XCTestCase {

    func testRequiredSetupPackIsLungfishTools() {
        let pack = PluginPack.requiredSetupPack

        XCTAssertEqual(pack.id, "lungfish-tools")
        XCTAssertEqual(pack.name, "Lungfish Tools")
        XCTAssertTrue(pack.isRequiredBeforeLaunch)
        XCTAssertTrue(pack.isActive)
        XCTAssertEqual(pack.packages, ["nextflow", "snakemake", "bbtools"])
    }

    func testRequiredSetupPackDefinesPerToolChecks() {
        let pack = PluginPack.requiredSetupPack
        let environments = pack.toolRequirements.map(\.environment)

        XCTAssertEqual(environments, ["nextflow", "snakemake", "bbtools"])
        XCTAssertEqual(pack.toolRequirements[2].executables, [
            "clumpify.sh", "bbduk.sh", "bbmerge.sh",
            "repair.sh", "tadpole.sh", "reformat.sh", "java",
        ])
    }

    func testActiveOptionalPacksOnlyExposeMetagenomics() {
        XCTAssertEqual(PluginPack.activeOptionalPacks.map(\.id), ["metagenomics"])
    }

    func testVisibleCLIPacksIncludeRequiredAndActiveOptional() {
        XCTAssertEqual(PluginPack.visibleForCLI.map(\.id), ["lungfish-tools", "metagenomics"])
    }
}
```

- [ ] **Step 2: Update the old pack-count test to the new registry shape**

Replace the old `CondaManagerTests.testBuiltInPacksExist` body with:

```swift
func testBuiltInPacksExist() {
    XCTAssertFalse(PluginPack.builtIn.isEmpty)
    XCTAssertEqual(PluginPack.builtIn.count, 14, "Should include Lungfish Tools plus 13 optional packs")
    XCTAssertEqual(PluginPack.activeOptionalPacks.count, 1, "Only metagenomics should be active in this branch")
}
```

- [ ] **Step 3: Run the new tests to verify they fail**

Run:

```bash
swift test --filter PluginPackRegistryTests
swift test --filter CondaManagerTests/testBuiltInPacksExist
```

Expected: FAIL because `PluginPack.requiredSetupPack`, `PluginPack.activeOptionalPacks`, `PluginPack.visibleForCLI`, and the new metadata do not exist yet.

- [ ] **Step 4: Create `PluginPack.swift` and move the registry into it**

Create `Sources/LungfishWorkflow/Conda/PluginPack.swift` with this structure:

```swift
@preconcurrency import Foundation

public enum PluginPackKind: String, Sendable, Codable, Hashable {
    case requiredSetup
    case optionalTools
}

public struct PackToolRequirement: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let environment: String
    public let executables: [String]

    public init(id: String, displayName: String, environment: String, executables: [String]) {
        self.id = id
        self.displayName = displayName
        self.environment = environment
        self.executables = executables
    }

    public static func package(_ name: String) -> PackToolRequirement {
        PackToolRequirement(
            id: name,
            displayName: name.capitalized,
            environment: name,
            executables: [name]
        )
    }

    public static let bbtools = PackToolRequirement(
        id: "bbtools",
        displayName: "BBTools",
        environment: "bbtools",
        executables: [
            "clumpify.sh", "bbduk.sh", "bbmerge.sh",
            "repair.sh", "tadpole.sh", "reformat.sh", "java",
        ]
    )
}

public struct PostInstallHook: Sendable, Codable, Hashable {
    public let description: String
    public let environment: String
    public let command: [String]
    public let requiresNetwork: Bool
    public let refreshIntervalDays: Int?
    public let estimatedDownloadSize: String?

    public init(
        description: String,
        environment: String,
        command: [String],
        requiresNetwork: Bool = true,
        refreshIntervalDays: Int? = nil,
        estimatedDownloadSize: String? = nil
    ) {
        self.description = description
        self.environment = environment
        self.command = command
        self.requiresNetwork = requiresNetwork
        self.refreshIntervalDays = refreshIntervalDays
        self.estimatedDownloadSize = estimatedDownloadSize
    }
}

public struct PluginPack: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let description: String
    public let sfSymbol: String
    public let packages: [String]
    public let category: String
    public let kind: PluginPackKind
    public let isActive: Bool
    public let requirements: [PackToolRequirement]
    public let postInstallHooks: [PostInstallHook]
    public let estimatedSizeMB: Int

    public init(
        id: String,
        name: String,
        description: String,
        sfSymbol: String,
        packages: [String],
        category: String,
        kind: PluginPackKind = .optionalTools,
        isActive: Bool = false,
        requirements: [PackToolRequirement] = [],
        postInstallHooks: [PostInstallHook] = [],
        estimatedSizeMB: Int = 0
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.sfSymbol = sfSymbol
        self.packages = packages
        self.category = category
        self.kind = kind
        self.isActive = isActive
        self.requirements = requirements
        self.postInstallHooks = postInstallHooks
        self.estimatedSizeMB = estimatedSizeMB
    }

    public var isRequiredBeforeLaunch: Bool {
        kind == .requiredSetup
    }

    public var toolRequirements: [PackToolRequirement] {
        requirements.isEmpty ? packages.map(PackToolRequirement.package) : requirements
    }
}

public extension PluginPack {
    static let builtIn: [PluginPack] = [
        PluginPack(
            id: "lungfish-tools",
            name: "Lungfish Tools",
            description: "Needed before you can create or open a project",
            sfSymbol: "checklist",
            packages: ["nextflow", "snakemake", "bbtools"],
            category: "Required Setup",
            kind: .requiredSetup,
            isActive: true,
            requirements: [.package("nextflow"), .package("snakemake"), .bbtools],
            estimatedSizeMB: 900
        ),
        PluginPack(
            id: "illumina-qc",
            name: "Illumina QC",
            description: "Quality control and reporting for Illumina short-read sequencing data",
            sfSymbol: "waveform.badge.magnifyingglass",
            packages: ["fastqc", "multiqc", "trimmomatic"],
            category: "Quality Control",
            estimatedSizeMB: 1000
        ),
        PluginPack(
            id: "alignment",
            name: "Alignment",
            description: "Map short and long reads to reference genomes",
            sfSymbol: "arrow.left.and.right.text.vertical",
            packages: ["bwa-mem2", "minimap2", "bowtie2", "hisat2"],
            category: "Alignment",
            estimatedSizeMB: 220
        ),
        PluginPack(
            id: "variant-calling",
            name: "Variant Calling",
            description: "Discover SNPs, indels, and structural variants from aligned reads",
            sfSymbol: "diamond.fill",
            packages: ["freebayes", "lofreq", "gatk4", "ivar"],
            category: "Variant Calling",
            estimatedSizeMB: 850
        ),
        PluginPack(
            id: "assembly",
            name: "Genome Assembly",
            description: "De novo genome assembly from short and long reads",
            sfSymbol: "puzzlepiece.extension.fill",
            packages: ["spades", "megahit", "flye", "quast"],
            category: "Assembly",
            estimatedSizeMB: 950
        ),
        PluginPack(
            id: "phylogenetics",
            name: "Phylogenetics",
            description: "Multiple sequence alignment and phylogenetic tree construction",
            sfSymbol: "tree",
            packages: ["iqtree", "mafft", "muscle", "raxml-ng", "treetime"],
            category: "Phylogenetics",
            estimatedSizeMB: 400
        ),
        PluginPack(
            id: "metagenomics",
            name: "Metagenomics",
            description: "Taxonomic classification, viral detection, and clinical triage of metagenomic samples",
            sfSymbol: "leaf.fill",
            packages: ["kraken2", "bracken", "metaphlan", "esviritu", "nextflow"],
            category: "Metagenomics",
            isActive: true,
            estimatedSizeMB: 1200
        ),
        PluginPack(
            id: "long-read",
            name: "Long Read Analysis",
            description: "Oxford Nanopore and PacBio long-read alignment, assembly, and polishing",
            sfSymbol: "ruler",
            packages: ["minimap2", "flye", "medaka", "hifiasm", "nanoplot"],
            category: "Long Read",
            estimatedSizeMB: 700
        ),
        PluginPack(
            id: "wastewater-surveillance",
            name: "Wastewater Surveillance",
            description: "SARS-CoV-2 and multi-pathogen lineage de-mixing from wastewater sequencing data",
            sfSymbol: "drop.triangle",
            packages: ["freyja", "ivar", "pangolin", "nextclade", "minimap2"],
            category: "Surveillance",
            postInstallHooks: [
                PostInstallHook(
                    description: "Download latest SARS-CoV-2 lineage barcodes",
                    environment: "freyja",
                    command: ["freyja", "update"],
                    refreshIntervalDays: 7,
                    estimatedDownloadSize: "~15 MB"
                ),
                PostInstallHook(
                    description: "Update Pango lineage designation data",
                    environment: "pangolin",
                    command: ["pangolin", "--update-data"],
                    refreshIntervalDays: 7,
                    estimatedDownloadSize: "~50 MB"
                ),
            ],
            estimatedSizeMB: 1500
        ),
        PluginPack(
            id: "rna-seq",
            name: "RNA-Seq Analysis",
            description: "Spliced alignment and transcript quantification for bulk RNA sequencing",
            sfSymbol: "bolt.horizontal",
            packages: ["star", "salmon", "subread", "stringtie"],
            category: "Transcriptomics",
            estimatedSizeMB: 600
        ),
        PluginPack(
            id: "single-cell",
            name: "Single-Cell Analysis",
            description: "Preprocessing and analysis of droplet-based single-cell RNA-seq data",
            sfSymbol: "circle.grid.3x3",
            packages: ["scanpy", "scvi-tools", "star"],
            category: "Single Cell",
            estimatedSizeMB: 1800
        ),
        PluginPack(
            id: "amplicon-analysis",
            name: "Amplicon Analysis",
            description: "Primer trimming, variant calling, and consensus generation for tiled-amplicon protocols",
            sfSymbol: "waveform.badge.magnifyingglass",
            packages: ["ivar", "pangolin", "nextclade"],
            category: "Amplicon",
            postInstallHooks: [
                PostInstallHook(
                    description: "Update Pango lineage designation data",
                    environment: "pangolin",
                    command: ["pangolin", "--update-data"],
                    refreshIntervalDays: 7,
                    estimatedDownloadSize: "~50 MB"
                ),
            ],
            estimatedSizeMB: 550
        ),
        PluginPack(
            id: "genome-annotation",
            name: "Genome Annotation",
            description: "Gene prediction and functional annotation for prokaryotic and viral genomes",
            sfSymbol: "tag.fill",
            packages: ["prokka", "bakta", "snpeff"],
            category: "Annotation",
            postInstallHooks: [
                PostInstallHook(
                    description: "Download Bakta light annotation database",
                    environment: "bakta",
                    command: ["bakta_db", "download", "--type", "light"],
                    refreshIntervalDays: 90,
                    estimatedDownloadSize: "~1.3 GB"
                ),
            ],
            estimatedSizeMB: 1200
        ),
        PluginPack(
            id: "data-format-utils",
            name: "Data Format Utilities",
            description: "File conversion, indexing, and interval manipulation for bioinformatics formats",
            sfSymbol: "arrow.triangle.2.circlepath",
            packages: ["bedtools", "picard"],
            category: "Utilities",
            estimatedSizeMB: 650
        ),
    ]

    static var requiredSetupPack: PluginPack {
        builtIn.first(where: \.isRequiredBeforeLaunch)!
    }

    static var activeOptionalPacks: [PluginPack] {
        builtIn.filter { $0.kind == .optionalTools && $0.isActive }
    }

    static var visibleForCLI: [PluginPack] {
        [requiredSetupPack] + activeOptionalPacks
    }
}
```

- [ ] **Step 5: Remove the moved type definitions from `CondaManager.swift` and add an environment helper**

Delete the old `PostInstallHook` and `PluginPack` definitions from `Sources/LungfishWorkflow/Conda/CondaManager.swift`, then add this helper near the other environment helpers:

```swift
public func environmentURL(named name: String) -> URL {
    rootPrefix.appendingPathComponent("envs/\(name)", isDirectory: true)
}
```

- [ ] **Step 6: Run the registry tests again**

Run:

```bash
swift test --filter PluginPackRegistryTests
swift test --filter CondaManagerTests/testBuiltInPacksExist
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishWorkflow/Conda/PluginPack.swift Sources/LungfishWorkflow/Conda/CondaManager.swift Tests/LungfishWorkflowTests/PluginPackRegistryTests.swift Tests/LungfishWorkflowTests/CondaManagerTests.swift
git commit -m "feat: add shared pack registry for Lungfish tools"
```

### Task 2: Add Shared Pack Health And Install/Reinstall Orchestration

**Files:**
- Create: `Sources/LungfishWorkflow/Conda/PluginPackStatusService.swift`
- Modify: `Sources/LungfishWorkflow/Conda/CondaManager.swift`
- Create: `Tests/LungfishWorkflowTests/PluginPackStatusServiceTests.swift`
- Modify: `Tests/LungfishWorkflowTests/CondaManagerTests.swift`

- [ ] **Step 1: Write the failing health-check and reinstall tests**

Create `Tests/LungfishWorkflowTests/PluginPackStatusServiceTests.swift` with:

```swift
import XCTest
@testable import LungfishWorkflow

final class PluginPackStatusServiceTests: XCTestCase {

    func testRequiredPackNeedsInstallWhenBBToolsExecutablesAreMissing() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("pack-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let manager = CondaManager(
            rootPrefix: sandbox.appendingPathComponent("conda"),
            bundledMicromambaProvider: { nil },
            bundledMicromambaVersionProvider: { nil }
        )

        let nextflowBin = await manager.environmentURL(named: "nextflow").appendingPathComponent("bin/nextflow")
        let snakemakeBin = await manager.environmentURL(named: "snakemake").appendingPathComponent("bin/snakemake")
        try FileManager.default.createDirectory(at: nextflowBin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snakemakeBin.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: nextflowBin.path, contents: Data("#!/bin/sh\n".utf8))
        FileManager.default.createFile(atPath: snakemakeBin.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nextflowBin.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: snakemakeBin.path)

        let service = PluginPackStatusService(condaManager: manager)
        let status = await service.status(for: .requiredSetupPack)

        XCTAssertEqual(status.pack.id, "lungfish-tools")
        XCTAssertEqual(status.state, .needsInstall)
        XCTAssertEqual(status.toolStatuses.first(where: { $0.requirement.environment == "bbtools" })?.isReady, false)
    }

    func testRequiredPackReadyWhenAllCoreExecutablesExist() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("pack-status-ready-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let manager = CondaManager(
            rootPrefix: sandbox.appendingPathComponent("conda"),
            bundledMicromambaProvider: { nil },
            bundledMicromambaVersionProvider: { nil }
        )

        for requirement in PluginPack.requiredSetupPack.toolRequirements {
            let binDir = await manager.environmentURL(named: requirement.environment).appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
            for executable in requirement.executables {
                let path = binDir.appendingPathComponent(executable)
                FileManager.default.createFile(atPath: path.path, contents: Data("#!/bin/sh\n".utf8))
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
            }
        }

        let service = PluginPackStatusService(condaManager: manager)
        let status = await service.status(for: .requiredSetupPack)

        XCTAssertEqual(status.state, .ready)
        XCTAssertTrue(status.toolStatuses.allSatisfy(\.isReady))
    }

    func testInstallPackUsesReinstallWhenRequested() async throws {
        actor InstallRecorder {
            var calls: [(packages: [String], environment: String, reinstall: Bool)] = []
            func record(_ packages: [String], _ environment: String, _ reinstall: Bool) {
                calls.append((packages, environment, reinstall))
            }
            func recordedCalls() -> [(packages: [String], environment: String, reinstall: Bool)] { calls }
        }

        let recorder = InstallRecorder()
        let manager = CondaManager(
            rootPrefix: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            bundledMicromambaProvider: { nil },
            bundledMicromambaVersionProvider: { nil }
        )

        let service = PluginPackStatusService(
            condaManager: manager,
            installAction: { packages, environment, reinstall, _ in
                await recorder.record(packages, environment, reinstall)
            }
        )

        try await service.install(pack: .requiredSetupPack, reinstall: true, progress: nil)

        let calls = await recorder.recordedCalls()
        XCTAssertEqual(calls.map(\.environment), ["nextflow", "snakemake", "bbtools"])
        XCTAssertTrue(calls.allSatisfy(\.reinstall))
    }
}
```

Add this targeted `CondaManagerTests` coverage too:

```swift
func testReinstallRemovesExistingEnvironmentBeforeCreate() async throws {
    let sandbox = try makeMicromambaSandbox()
    defer { try? FileManager.default.removeItem(at: sandbox) }

    let bundledMicromamba = try makeFakeMicromamba(
        at: sandbox.appendingPathComponent("bundled-micromamba"),
        version: "2.0.5-0"
    )
    let manager = CondaManager(
        rootPrefix: sandbox.appendingPathComponent("conda"),
        bundledMicromambaProvider: { bundledMicromamba },
        bundledMicromambaVersionProvider: { "2.0.5-0" }
    )

    let staleFile = await manager.environmentURL(named: "bbtools")
        .appendingPathComponent("conda-meta/stale.json")
    try FileManager.default.createDirectory(at: staleFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: staleFile.path, contents: Data("stale".utf8))

    try await manager.reinstall(packages: ["bbtools"], environment: "bbtools")

    XCTAssertFalse(FileManager.default.fileExists(atPath: staleFile.path))
}
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run:

```bash
swift test --filter PluginPackStatusServiceTests
swift test --filter CondaManagerTests/testReinstallRemovesExistingEnvironmentBeforeCreate
```

Expected: FAIL because `PluginPackStatusService`, `PluginPackStatus`, `PackToolStatus`, and `CondaManager.reinstall` do not exist yet.

- [ ] **Step 3: Implement `PluginPackStatusService`**

Create `Sources/LungfishWorkflow/Conda/PluginPackStatusService.swift` with:

```swift
@preconcurrency import Foundation

public enum PluginPackState: String, Sendable, Codable, Hashable {
    case ready
    case needsInstall
    case installing
    case failed
}

public struct PackToolStatus: Sendable, Codable, Hashable, Identifiable {
    public let requirement: PackToolRequirement
    public let missingExecutables: [String]

    public var id: String { requirement.id }
    public var isReady: Bool { missingExecutables.isEmpty }
}

public struct PluginPackStatus: Sendable, Codable, Hashable, Identifiable {
    public let pack: PluginPack
    public let state: PluginPackState
    public let toolStatuses: [PackToolStatus]
    public let failureMessage: String?

    public var id: String { pack.id }
}

public protocol PluginPackStatusProviding: Sendable {
    func visibleStatuses() async -> [PluginPackStatus]
    func status(for pack: PluginPack) async -> PluginPackStatus
    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws
}

public actor PluginPackStatusService: PluginPackStatusProviding {
    public typealias InstallAction = @Sendable (
        _ packages: [String],
        _ environment: String,
        _ reinstall: Bool,
        _ progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> Void

    public static let shared = PluginPackStatusService(condaManager: .shared)

    private let condaManager: CondaManager
    private let installAction: InstallAction

    public init(
        condaManager: CondaManager,
        installAction: InstallAction? = nil
    ) {
        self.condaManager = condaManager
        self.installAction = installAction ?? { [condaManager] packages, environment, reinstall, progress in
            if reinstall {
                try await condaManager.reinstall(packages: packages, environment: environment, progress: progress)
            } else {
                try await condaManager.install(packages: packages, environment: environment, progress: progress)
            }
        }
    }

    public func visibleStatuses() async -> [PluginPackStatus] {
        await PluginPack.visibleForCLI.asyncMap { pack in
            await status(for: pack)
        }
    }

    public func status(for pack: PluginPack) async -> PluginPackStatus {
        let statuses = await pack.toolRequirements.asyncMap { requirement in
            let envURL = await condaManager.environmentURL(named: requirement.environment)
            let binDir = envURL.appendingPathComponent("bin", isDirectory: true)
            let missing = requirement.executables.filter { executable in
                !FileManager.default.isExecutableFile(atPath: binDir.appendingPathComponent(executable).path)
            }
            return PackToolStatus(requirement: requirement, missingExecutables: missing)
        }

        return PluginPackStatus(
            pack: pack,
            state: statuses.allSatisfy(\.isReady) ? .ready : .needsInstall,
            toolStatuses: statuses,
            failureMessage: nil
        )
    }

    public func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws {
        let steps = max(pack.packages.count, 1)
        for (index, package) in pack.packages.enumerated() {
            let prefix = Double(index) / Double(steps)
            try await installAction([package], package, reinstall) { fraction, message in
                let scaled = prefix + (fraction / Double(steps))
                progress?(scaled, message)
            }
        }
        progress?(1.0, "\(pack.name) ready")
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var results: [T] = []
        for element in self {
            results.append(await transform(element))
        }
        return results
    }
}
```

- [ ] **Step 4: Add reinstall support to `CondaManager`**

Add this method near `install(packages:environment:)` in `Sources/LungfishWorkflow/Conda/CondaManager.swift`:

```swift
public func reinstall(
    packages: [String],
    environment: String,
    channels: [String]? = nil,
    progress: (@Sendable (Double, String) -> Void)? = nil
) async throws {
    let envPath = environmentURL(named: environment)
    if FileManager.default.fileExists(atPath: envPath.path) {
        try FileManager.default.removeItem(at: envPath)
    }
    try await install(
        packages: packages,
        environment: environment,
        channels: channels,
        progress: progress
    )
}
```

- [ ] **Step 5: Run the status-service tests again**

Run:

```bash
swift test --filter PluginPackStatusServiceTests
swift test --filter CondaManagerTests/testReinstallRemovesExistingEnvironmentBeforeCreate
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishWorkflow/Conda/PluginPackStatusService.swift Sources/LungfishWorkflow/Conda/CondaManager.swift Tests/LungfishWorkflowTests/PluginPackStatusServiceTests.swift Tests/LungfishWorkflowTests/CondaManagerTests.swift
git commit -m "feat: add shared pack health and reinstall service"
```

### Task 3: Switch Plugin Manager And CLI To The Shared Registry

**Files:**
- Modify: `Sources/LungfishCLI/Commands/CondaCommand.swift`
- Modify: `Sources/LungfishApp/Views/PluginManager/PluginManagerViewModel.swift`
- Modify: `Sources/LungfishApp/Views/PluginManager/PluginManagerView.swift`
- Modify: `Sources/LungfishApp/Views/PluginManager/PluginManagerWindowController.swift`
- Create: `Tests/LungfishAppTests/PluginPackVisibilityTests.swift`
- Create: `Tests/LungfishCLITests/CondaPacksCommandTests.swift`
- Modify: `Tests/LungfishAppTests/DatabasesTabTests.swift`

- [ ] **Step 1: Write the failing Plugin Manager and CLI visibility tests**

Create `Tests/LungfishAppTests/PluginPackVisibilityTests.swift` with:

```swift
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

private actor StubPluginManagerPackStatusProvider: PluginPackStatusProviding {
    let statuses: [PluginPackStatus]

    init(statuses: [PluginPackStatus]) {
        self.statuses = statuses
    }

    func visibleStatuses() async -> [PluginPackStatus] {
        statuses
    }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        statuses.first(where: { $0.pack.id == pack.id })!
    }

    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws {
        progress?(1.0, "Installed")
    }
}

@MainActor
final class PluginPackVisibilityTests: XCTestCase {

    func testViewModelExposesRequiredSetupSeparatelyFromOptionalPacks() async {
        let required = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )
        let optional = PluginPackStatus(
            pack: PluginPack.activeOptionalPacks[0],
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )
        let viewModel = PluginManagerViewModel(
            packStatusProvider: StubPluginManagerPackStatusProvider(statuses: [required, optional])
        )
        await viewModel.loadPackStatuses()

        XCTAssertEqual(viewModel.requiredSetupPack?.pack.id, "lungfish-tools")
        XCTAssertEqual(viewModel.optionalPackStatuses.map(\.pack.id), ["metagenomics"])
    }

    func testFocusPackSelectsPacksTabAndStoresPackID() {
        let viewModel = PluginManagerViewModel()

        viewModel.focusPack("metagenomics")

        XCTAssertEqual(viewModel.selectedTab, .packs)
        XCTAssertEqual(viewModel.focusedPackID, "metagenomics")
    }
}
```

Create `Tests/LungfishCLITests/CondaPacksCommandTests.swift` with:

```swift
import XCTest
@testable import LungfishCLI

final class CondaPacksCommandTests: XCTestCase {

    func testVisibleCLIPacksOnlyIncludeRequiredAndActivePacks() {
        XCTAssertEqual(
            CondaCommand.visiblePacksForTesting().map(\.id),
            ["lungfish-tools", "metagenomics"]
        )
    }
}
```

In `Tests/LungfishAppTests/DatabasesTabTests.swift`, update the tab-count expectation to keep the same four tabs while the packs tab’s data source changes:

```swift
func testAllTabsHaveDistinctIndices() {
    let tabs: [PluginManagerViewModel.Tab] = [.installed, .available, .packs, .databases]
    let indices = tabs.map(\.segmentIndex)
    XCTAssertEqual(Set(indices).count, 4)
    XCTAssertEqual(indices, [0, 1, 2, 3])
}
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run:

```bash
swift test --filter PluginPackVisibilityTests
swift test --filter CondaPacksCommandTests
```

Expected: FAIL because the view model still uses `PluginPack.builtIn` directly and `CondaCommand.visiblePacksForTesting()` does not exist.

- [ ] **Step 3: Update `PluginManagerViewModel` to read shared pack status**

Replace the current packs state in `Sources/LungfishApp/Views/PluginManager/PluginManagerViewModel.swift` with:

```swift
private let packStatusProvider: any PluginPackStatusProviding

var requiredSetupPack: PluginPackStatus?
var optionalPackStatuses: [PluginPackStatus] = []
var focusedPackID: String?

init(packStatusProvider: any PluginPackStatusProviding = PluginPackStatusService.shared) {
    self.packStatusProvider = packStatusProvider
    refreshInstalled()
    refreshPackStatuses()
}

func loadPackStatuses() async {
    let statuses = await packStatusProvider.visibleStatuses()
    requiredSetupPack = statuses.first(where: { $0.pack.isRequiredBeforeLaunch })
    optionalPackStatuses = statuses.filter { !$0.pack.isRequiredBeforeLaunch }
}

func refreshPackStatuses() {
    Task {
        await loadPackStatuses()
    }
}

func focusPack(_ packID: String) {
    selectedTab = .packs
    focusedPackID = packID
}

func installPack(_ pack: PluginPack, reinstall: Bool = false) {
    installingPacks.insert(pack.id)
    packProgressMessage[pack.id] = reinstall ? "Reinstalling..." : "Installing..."

    Task {
        defer {
            installingPacks.remove(pack.id)
            packProgressMessage.removeValue(forKey: pack.id)
        }

        do {
            try await packStatusProvider.install(pack: pack, reinstall: reinstall) { [weak self] _, message in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.packProgressMessage[pack.id] = message
                    }
                }
            }
        } catch {
            handleError(error, context: "\(reinstall ? "reinstalling" : "installing") '\(pack.name)'")
        }

        refreshInstalled()
        refreshPackStatuses()
    }
}
```

- [ ] **Step 4: Update the Packs tab UI and Plugin Manager window controller**

Update `Sources/LungfishApp/Views/PluginManager/PluginManagerView.swift` so the packs tab renders separate sections and can scroll to a focused pack:

```swift
private struct PacksTabView: View {
    @Bindable var viewModel: PluginManagerViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let required = viewModel.requiredSetupPack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Required Setup")
                                .font(.headline)
                            PackCard(
                                pack: required.pack,
                                installedNames: viewModel.installedEnvironmentNames,
                                isInstalling: viewModel.installingPacks.contains(required.pack.id),
                                progressMessage: viewModel.packProgressMessage[required.pack.id],
                                onInstallAll: {
                                    viewModel.installPack(required.pack, reinstall: required.state != .needsInstall)
                                },
                                onRemoveAll: {}
                            )
                            .id(required.pack.id)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Optional Tools")
                            .font(.headline)

                        ForEach(viewModel.optionalPackStatuses, id: \.id) { status in
                            PackCard(
                                pack: status.pack,
                                installedNames: viewModel.installedEnvironmentNames,
                                isInstalling: viewModel.installingPacks.contains(status.pack.id),
                                progressMessage: viewModel.packProgressMessage[status.pack.id],
                                onInstallAll: { viewModel.installPack(status.pack) },
                                onRemoveAll: { viewModel.removePack(status.pack) }
                            )
                            .id(status.pack.id)
                        }
                    }
                }
                .padding(16)
            }
            .onChange(of: viewModel.focusedPackID) { _, packID in
                guard let packID else { return }
                withAnimation {
                    proxy.scrollTo(packID, anchor: .top)
                }
            }
        }
    }
}
```

Add this helper to `Sources/LungfishApp/Views/PluginManager/PluginManagerWindowController.swift`:

```swift
@MainActor
public static func show(packID: String) {
    showWindow(tab: .packs)
    shared?.viewModel.focusPack(packID)
}
```

- [ ] **Step 5: Switch CLI pack listing and pack install to the shared registry**

Add this helper to `Sources/LungfishCLI/Commands/CondaCommand.swift`:

```swift
extension CondaCommand {
    static func visiblePacksForTesting() -> [PluginPack] {
        PluginPack.visibleForCLI
    }
}
```

Then change both pack lookup sites to use it:

```swift
guard let pack = CondaCommand.visiblePacksForTesting().first(where: { $0.id == packID }) else {
    print(formatter.error("Unknown tool pack: \(packID)"))
    print("Available packs: \(CondaCommand.visiblePacksForTesting().map(\.id).joined(separator: ", "))")
    throw ExitCode.failure
}
```

and:

```swift
print(formatter.header("Available Tool Packs"))
print("")
for pack in CondaCommand.visiblePacksForTesting() {
    print(formatter.bold("\(pack.name)") + " (\(pack.id))")
    print("  \(pack.description)")
    print("  Packages: \(pack.packages.joined(separator: ", "))")
    print("")
}
```

- [ ] **Step 6: Run the Plugin Manager and CLI tests again**

Run:

```bash
swift test --filter PluginPackVisibilityTests
swift test --filter CondaPacksCommandTests
swift test --filter DatabasesTabTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishCLI/Commands/CondaCommand.swift Sources/LungfishApp/Views/PluginManager/PluginManagerViewModel.swift Sources/LungfishApp/Views/PluginManager/PluginManagerView.swift Sources/LungfishApp/Views/PluginManager/PluginManagerWindowController.swift Tests/LungfishAppTests/PluginPackVisibilityTests.swift Tests/LungfishCLITests/CondaPacksCommandTests.swift Tests/LungfishAppTests/DatabasesTabTests.swift
git commit -m "feat: drive plugin manager and cli packs from shared registry"
```

### Task 4: Add Welcome-Screen Required Setup Gating And Remove Open Files

**Files:**
- Modify: `Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Create: `Tests/LungfishAppTests/WelcomeSetupTests.swift`

- [ ] **Step 1: Write the failing welcome-screen state tests**

Create `Tests/LungfishAppTests/WelcomeSetupTests.swift` with:

```swift
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

private actor StubPackStatusProvider: PluginPackStatusProviding {
    var statuses: [PluginPackStatus]

    init(statuses: [PluginPackStatus]) {
        self.statuses = statuses
    }

    func visibleStatuses() async -> [PluginPackStatus] {
        statuses
    }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        statuses.first(where: { $0.pack.id == pack.id })!
    }

    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws {
        progress?(1.0, "Installed")
    }
}

@MainActor
final class WelcomeSetupTests: XCTestCase {

    func testAvailableActionsExcludeOpenFiles() {
        XCTAssertEqual(WelcomeAction.allCases, [.createProject, .openProject])
    }

    func testLaunchRemainsDisabledUntilRequiredSetupIsReady() async {
        let required = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )
        let optional = PluginPackStatus(
            pack: PluginPack.activeOptionalPacks[0],
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )

        let viewModel = WelcomeViewModel(statusProvider: StubPackStatusProvider(statuses: [required, optional]))
        await viewModel.refreshSetup()

        XCTAssertFalse(viewModel.canLaunch)
        XCTAssertEqual(viewModel.optionalPackStatuses.map(\.pack.id), ["metagenomics"])
    }

    func testLaunchEnablesWhenRequiredSetupIsReady() async {
        let required = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .ready,
            toolStatuses: [],
            failureMessage: nil
        )

        let viewModel = WelcomeViewModel(statusProvider: StubPackStatusProvider(statuses: [required]))
        await viewModel.refreshSetup()

        XCTAssertTrue(viewModel.canLaunch)
    }
}
```

- [ ] **Step 2: Run the welcome tests to verify they fail**

Run:

```bash
swift test --filter WelcomeSetupTests
```

Expected: FAIL because `WelcomeAction` is not `CaseIterable`, `WelcomeViewModel` has no pack-status state, and `Open Files` still exists.

- [ ] **Step 3: Update the welcome view model and actions**

In `Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift`, replace the existing `WelcomeAction` and `WelcomeViewModel` definitions with:

```swift
enum WelcomeAction: String, Identifiable, CaseIterable {
    case createProject = "Create Project"
    case openProject = "Open Project"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .createProject: return "folder.badge.plus"
        case .openProject: return "folder"
        }
    }

    var description: String {
        switch self {
        case .createProject: return "Create a new project folder to organize your work"
        case .openProject: return "Open an existing Lungfish project"
        }
    }
}

@MainActor
final class WelcomeViewModel: ObservableObject {
    @Published var selectedAction: WelcomeAction?
    @Published var isLoading = false
    @Published var isInstallingRequiredSetup = false
    @Published private(set) var requiredSetupStatus: PluginPackStatus?
    @Published private(set) var optionalPackStatuses: [PluginPackStatus] = []
    @Published var setupErrorMessage: String?
    @Published var showingSetupDetails = false

    let recentProjects = RecentProjectsManager.shared

    private let statusProvider: any PluginPackStatusProviding

    var onCreateProject: ((URL) -> Void)?
    var onOpenProject: ((URL) -> Void)?
    var onOpenOptionalPack: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    init(statusProvider: any PluginPackStatusProviding = PluginPackStatusService.shared) {
        self.statusProvider = statusProvider
    }

    var canLaunch: Bool {
        requiredSetupStatus?.state == .ready && !isInstallingRequiredSetup
    }

    func refreshSetup() async {
        let statuses = await statusProvider.visibleStatuses()
        requiredSetupStatus = statuses.first(where: { $0.pack.isRequiredBeforeLaunch })
        optionalPackStatuses = statuses.filter { !$0.pack.isRequiredBeforeLaunch }
    }

    func installRequiredSetup() {
        guard let pack = requiredSetupStatus?.pack else { return }
        isInstallingRequiredSetup = true

        Task {
            defer { isInstallingRequiredSetup = false }
            do {
                try await statusProvider.install(
                    pack: pack,
                    reinstall: requiredSetupStatus?.state != .needsInstall,
                    progress: nil
                )
                await refreshSetup()
            } catch {
                setupErrorMessage = error.localizedDescription
            }
        }
    }
}
```

- [ ] **Step 4: Replace the welcome view layout with a setup-aware, HIG-aligned version**

Update the SwiftUI body in `Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift` so it:

```swift
VStack(alignment: .leading, spacing: 18) {
    VStack(alignment: .leading, spacing: 8) {
        Image(nsImage: Self.loadLogo())
            .resizable()
            .frame(width: 64, height: 64)

        Text("Lungfish Genome Explorer")
            .font(.system(size: 22, weight: .bold))

        Text("Seeing the invisible. Informing action.")
            .font(.system(size: 12))
            .foregroundColor(.secondary)
    }

    VStack(alignment: .leading, spacing: 12) {
        ForEach(WelcomeAction.allCases) { action in
            ActionButton(
                action: action,
                isHovered: hoveredAction == action,
                isEnabled: viewModel.canLaunch,
                onTap: { performAction(action) }
            )
            .onHover { isHovered in
                hoveredAction = isHovered ? action : nil
            }
        }
    }

    if let required = viewModel.requiredSetupStatus {
        RequiredSetupCard(
            status: required,
            isInstalling: viewModel.isInstallingRequiredSetup,
            showingDetails: $viewModel.showingSetupDetails,
            onInstall: { viewModel.installRequiredSetup() }
        )
    }

    if !viewModel.optionalPackStatuses.isEmpty {
        OptionalToolsCard(
            statuses: viewModel.optionalPackStatuses,
            onOpenPack: { viewModel.onOpenOptionalPack?($0) }
        )
    }

    Spacer()
}
```

Update `ActionButton` and `RecentProjectRow` so they take an `isEnabled` flag and use `.disabled(!isEnabled)` plus a muted opacity instead of color alone.

Call `Task { await viewModel.refreshSetup() }` from `setupContent()` after wiring the callbacks.

- [ ] **Step 5: Remove the welcome-screen Open Files flow and wire optional-pack clicks**

In `Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift`, delete:

```swift
public var onOpenFilesSelected: (() -> Void)?
```

and delete the old `viewModel.onOpenFiles` wiring block entirely.

Then add:

```swift
public var onOptionalPackSelected: ((String) -> Void)?
```

and wire it:

```swift
viewModel.onOpenOptionalPack = { [weak self] packID in
    self?.onOptionalPackSelected?(packID)
}
```

In `Sources/LungfishApp/App/AppDelegate.swift`, change `showWelcomeWindow()` to:

```swift
private func showWelcomeWindow() {
    welcomeWindowController = WelcomeWindowController()

    welcomeWindowController?.onProjectSelected = { [weak self] projectURL in
        self?.showMainWindowWithProject(projectURL)
    }

    welcomeWindowController?.onOptionalPackSelected = { packID in
        PluginManagerWindowController.show(packID: packID)
    }

    welcomeWindowController?.show()
}
```

- [ ] **Step 6: Run the welcome tests again**

Run:

```bash
swift test --filter WelcomeSetupTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift Sources/LungfishApp/App/AppDelegate.swift Tests/LungfishAppTests/WelcomeSetupTests.swift
git commit -m "feat: add required setup gating to welcome screen"
```

### Task 5: Resolve BBTools, Nextflow, And Snakemake From `~/.lungfish`

**Files:**
- Create: `Sources/LungfishWorkflow/Conda/CoreToolLocator.swift`
- Modify: `Sources/LungfishWorkflow/Native/NativeToolRunner.swift`
- Modify: `Sources/LungfishWorkflow/Engines/NextflowRunner.swift`
- Modify: `Sources/LungfishWorkflow/Engines/SnakemakeRunner.swift`
- Modify: `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift`
- Modify: `Sources/LungfishWorkflow/Recipes/RecipeEngine.swift`
- Modify: `Sources/LungfishWorkflow/Extraction/FASTQCLIMaterializer.swift`
- Modify: `Sources/LungfishWorkflow/Ingestion/FASTQIngestionPipeline.swift`
- Modify: `Sources/LungfishApp/Services/FASTQIngestionService.swift`
- Modify: `Sources/LungfishApp/Services/FASTQDerivativeService.swift`
- Create: `Tests/LungfishWorkflowTests/CoreToolLocatorTests.swift`
- Modify: `Tests/LungfishWorkflowTests/NativeToolRunnerTests.swift`
- Modify: `Tests/LungfishWorkflowTests/FASTQIngestionPipelineTests.swift`
- Modify: `Tests/LungfishWorkflowTests/FASTQToolIntegrationTests.swift`

- [ ] **Step 1: Write the failing path-resolution tests**

Create `Tests/LungfishWorkflowTests/CoreToolLocatorTests.swift` with:

```swift
import XCTest
@testable import LungfishWorkflow

final class CoreToolLocatorTests: XCTestCase {

    func testManagedExecutableURLUsesLungfishCondaRoot() {
        let home = URL(fileURLWithPath: "/tmp/lungfish-home", isDirectory: true)
        let url = CoreToolLocator.executableURL(
            environment: "bbtools",
            executableName: "clumpify.sh",
            homeDirectory: home
        )

        XCTAssertEqual(
            url.path,
            "/tmp/lungfish-home/.lungfish/conda/envs/bbtools/bin/clumpify.sh"
        )
    }

    func testBBToolsEnvironmentUsesManagedJava() {
        let home = URL(fileURLWithPath: "/tmp/lungfish-home", isDirectory: true)
        let env = CoreToolLocator.bbToolsEnvironment(
            homeDirectory: home,
            existingPath: "/usr/bin:/bin"
        )

        XCTAssertEqual(env["JAVA_HOME"], "/tmp/lungfish-home/.lungfish/conda/envs/bbtools")
        XCTAssertEqual(env["BBMAP_JAVA"], "/tmp/lungfish-home/.lungfish/conda/envs/bbtools/bin/java")
        XCTAssertEqual(
            env["PATH"],
            "/tmp/lungfish-home/.lungfish/conda/envs/bbtools/bin:/usr/bin:/bin"
        )
    }
}
```

Change `Tests/LungfishWorkflowTests/NativeToolRunnerTests.swift` to stop requiring BBTools/JRE in the bundled tools directory:

```swift
func testAllBundledToolsRemainAvailable() async {
    let runner = NativeToolRunner()
    let results = await runner.checkAllTools()

    for tool in NativeTool.allCases where tool.isBundled {
        XCTAssertTrue(
            results[tool] == true,
            "Bundled tool '\(tool.rawValue)' should still be available"
        )
    }
}

func testValidateBundledToolsInstallationIgnoresManagedCoreTools() async {
    let runner = NativeToolRunner()
    let (valid, missing) = await runner.validateBundledToolsInstallation()

    XCTAssertTrue(valid, "Bundled tools should still validate without BBTools/JRE in the app bundle")
    XCTAssertFalse(missing.contains(.clumpify))
    XCTAssertFalse(missing.contains(.java))
}

func testFindToolReturnsExecutableURLForBundledTools() async throws {
    let runner = NativeToolRunner()

    for tool in NativeTool.allCases where tool.isBundled {
        let url = try await runner.findTool(tool)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path))
    }
}

func testManagedCoreToolLocationsUseCondaEnvironments() {
    XCTAssertEqual(NativeTool.clumpify.location, .managed(environment: "bbtools", executableName: "clumpify.sh"))
    XCTAssertEqual(NativeTool.java.location, .managed(environment: "bbtools", executableName: "java"))
}

func testNativeToolExecutableNames() {
    XCTAssertEqual(NativeTool.samtools.executableName, "samtools")
    XCTAssertEqual(NativeTool.bbduk.executableName, "bbduk.sh")
    XCTAssertEqual(NativeTool.reformat.executableName, "reformat.sh")
    XCTAssertEqual(NativeTool.java.executableName, "java")
    XCTAssertTrue(NativeTool.samtools.isBundled)
    XCTAssertFalse(NativeTool.clumpify.isBundled)
    XCTAssertFalse(NativeTool.java.isBundled)
}
```

Update `Tests/LungfishWorkflowTests/FASTQToolIntegrationTests.swift` so its BBTools helper expects the shared locator:

```swift
private func bbToolsEnv() async -> [String: String] {
    CoreToolLocator.bbToolsEnvironment(
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
        existingPath: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    )
}
```

- [ ] **Step 2: Run the path tests to verify they fail**

Run:

```bash
swift test --filter CoreToolLocatorTests
swift test --filter NativeToolRunnerTests/testAllBundledToolsRemainAvailable
swift test --filter NativeToolRunnerTests/testValidateBundledToolsInstallationIgnoresManagedCoreTools
```

Expected: FAIL because `CoreToolLocator` and `validateBundledToolsInstallation()` do not exist.

- [ ] **Step 3: Add a shared core-tool locator**

Create `Sources/LungfishWorkflow/Conda/CoreToolLocator.swift` with:

```swift
import Foundation

public enum CoreToolLocator {
    public static func condaRoot(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".lungfish/conda", isDirectory: true)
    }

    public static func environmentURL(
        named environment: String,
        homeDirectory: URL
    ) -> URL {
        condaRoot(homeDirectory: homeDirectory)
            .appendingPathComponent("envs/\(environment)", isDirectory: true)
    }

    public static func executableURL(
        environment: String,
        executableName: String,
        homeDirectory: URL
    ) -> URL {
        environmentURL(named: environment, homeDirectory: homeDirectory)
            .appendingPathComponent("bin/\(executableName)")
    }

    public static func bbToolsEnvironment(
        homeDirectory: URL,
        existingPath: String
    ) -> [String: String] {
        let envRoot = environmentURL(named: "bbtools", homeDirectory: homeDirectory)
        let binDir = envRoot.appendingPathComponent("bin", isDirectory: true)
        let java = binDir.appendingPathComponent("java")

        return [
            "PATH": "\(binDir.path):\(existingPath)",
            "JAVA_HOME": envRoot.path,
            "BBMAP_JAVA": java.path,
        ]
    }
}
```

- [ ] **Step 4: Teach `NativeToolRunner` about managed core tools**

In `Sources/LungfishWorkflow/Native/NativeToolRunner.swift`, add:

```swift
public enum NativeToolLocation: Sendable, Hashable {
    case bundled(relativePath: String)
    case managed(environment: String, executableName: String)
}
```

Replace the old path properties with:

```swift
public var isBundled: Bool {
    if case .bundled = location { return true }
    return false
}

public var location: NativeToolLocation {
    switch self {
    case .clumpify: return .managed(environment: "bbtools", executableName: "clumpify.sh")
    case .bbduk: return .managed(environment: "bbtools", executableName: "bbduk.sh")
    case .bbmerge: return .managed(environment: "bbtools", executableName: "bbmerge.sh")
    case .repair: return .managed(environment: "bbtools", executableName: "repair.sh")
    case .tadpole: return .managed(environment: "bbtools", executableName: "tadpole.sh")
    case .reformat: return .managed(environment: "bbtools", executableName: "reformat.sh")
    case .java: return .managed(environment: "bbtools", executableName: "java")
    case .alignsTo: return .bundled(relativePath: "scrubber/bin/aligns_to")
    case .scrubSh: return .bundled(relativePath: "scrubber/scripts/scrub.sh")
    case .fasterqDump: return .bundled(relativePath: "sra-tools/fasterq-dump")
    case .prefetch: return .bundled(relativePath: "sra-tools/prefetch")
    default: return .bundled(relativePath: executableName)
    }
}
```

Then change discovery and validation:

```swift
private let homeDirectory: URL

public init() {
    self.toolsDirectory = Self.findToolsDirectory()
    self.homeDirectory = FileManager.default.homeDirectoryForCurrentUser
}

public init(toolsDirectory: URL?, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
    self.toolsDirectory = toolsDirectory
    self.homeDirectory = homeDirectory
}

private func discoverToolPath(_ tool: NativeTool) throws -> URL {
    switch tool.location {
    case .managed(let environment, let executableName):
        let managedURL = CoreToolLocator.executableURL(
            environment: environment,
            executableName: executableName,
            homeDirectory: homeDirectory
        )
        guard FileManager.default.isExecutableFile(atPath: managedURL.path) else {
            throw NativeToolError.toolNotFound(tool.rawValue)
        }
        return managedURL

    case .bundled(let relativePath):
        guard let toolsDir = toolsDirectory else {
            throw NativeToolError.toolsDirectoryNotFound
        }
        let bundledURL = toolsDir.appendingPathComponent(relativePath)
        guard FileManager.default.isExecutableFile(atPath: bundledURL.path) else {
            throw NativeToolError.toolNotFound(tool.rawValue)
        }
        return bundledURL
    }
}

public func validateBundledToolsInstallation() -> (valid: Bool, missing: [NativeTool]) {
    guard let toolsDir = toolsDirectory else {
        return (false, NativeTool.allCases.filter {
            if case .bundled = $0.location { return true }
            return false
        })
    }

    let missing = NativeTool.allCases.filter { tool in
        guard case .bundled(let relativePath) = tool.location else { return false }
        return !FileManager.default.isExecutableFile(atPath: toolsDir.appendingPathComponent(relativePath).path)
    }
    return (missing.isEmpty, missing)
}

public func validateToolsInstallation() -> (valid: Bool, missing: [NativeTool]) {
    validateBundledToolsInstallation()
}
```

- [ ] **Step 5: Switch workflow-engine and BBTools callers to the shared locator**

Update `Sources/LungfishWorkflow/Engines/NextflowRunner.swift` and `Sources/LungfishWorkflow/Engines/SnakemakeRunner.swift` so they prefer the dedicated env path:

```swift
private func preferredExecutablePath() -> URL? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let url = CoreToolLocator.executableURL(
        environment: engineType.executableName,
        executableName: engineType.executableName,
        homeDirectory: home
    )
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
}
```

Use it in `isAvailable()`, `getVersion()`, and `run(...)`:

```swift
if let path = preferredExecutablePath() ?? baseRunner.findEngine(.nextflow) {
    executablePath = path
    return true
}
```

Replace the duplicated BBTools environment builders in these files:

- `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift`
- `Sources/LungfishWorkflow/Recipes/RecipeEngine.swift`
- `Sources/LungfishWorkflow/Extraction/FASTQCLIMaterializer.swift`
- `Sources/LungfishWorkflow/Ingestion/FASTQIngestionPipeline.swift`
- `Sources/LungfishApp/Services/FASTQIngestionService.swift`
- `Sources/LungfishApp/Services/FASTQDerivativeService.swift`

with the shared helper:

```swift
let env = CoreToolLocator.bbToolsEnvironment(
    homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
    existingPath: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
)
```

In `FASTQIngestionPipeline.clumpify(...)`, replace the bundled Java lookup with:

```swift
let clumpifyScript = try await runner.toolPath(for: .clumpify)
let env = CoreToolLocator.bbToolsEnvironment(
    homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
    existingPath: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
)
```

Leave the existing no-space symlink workaround untouched.

- [ ] **Step 6: Run the workflow and runtime tests again**

Run:

```bash
swift test --filter CoreToolLocatorTests
swift test --filter NativeToolRunnerTests
swift test --filter FASTQIngestionPipelineTests
swift test --filter FASTQToolIntegrationTests
```

Expected: PASS, with the BBTools-dependent tests skipping cleanly if the managed `bbtools` environment is not installed on the machine running the suite.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishWorkflow/Conda/CoreToolLocator.swift Sources/LungfishWorkflow/Native/NativeToolRunner.swift Sources/LungfishWorkflow/Engines/NextflowRunner.swift Sources/LungfishWorkflow/Engines/SnakemakeRunner.swift Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift Sources/LungfishWorkflow/Recipes/RecipeEngine.swift Sources/LungfishWorkflow/Extraction/FASTQCLIMaterializer.swift Sources/LungfishWorkflow/Ingestion/FASTQIngestionPipeline.swift Sources/LungfishApp/Services/FASTQIngestionService.swift Sources/LungfishApp/Services/FASTQDerivativeService.swift Tests/LungfishWorkflowTests/CoreToolLocatorTests.swift Tests/LungfishWorkflowTests/NativeToolRunnerTests.swift Tests/LungfishWorkflowTests/FASTQIngestionPipelineTests.swift Tests/LungfishWorkflowTests/FASTQToolIntegrationTests.swift
git commit -m "refactor: resolve core tools from managed conda environments"
```

### Task 6: Remove Bundled BBTools/JRE And Update Release Packaging Expectations

**Files:**
- Modify: `Sources/LungfishWorkflow/Resources/Tools/tool-versions.json`
- Modify: `scripts/bundle-native-tools.sh`
- Modify: `scripts/update-tool-versions.sh`
- Modify: `scripts/sanitize-bundled-tools.sh`
- Modify: `scripts/release/build-notarized-dmg.sh`
- Modify: `scripts/smoke-test-release-tools.sh`
- Modify: `README.md`
- Modify: `THIRD-PARTY-NOTICES`
- Delete: `Sources/LungfishWorkflow/Resources/Tools/bbtools`
- Delete: `Sources/LungfishWorkflow/Resources/Tools/jre`
- Delete: `scripts/release/jre-launcher.entitlements`
- Modify: `Tests/LungfishAppTests/ReleaseBuildConfigurationTests.swift`

- [ ] **Step 1: Write the failing release-configuration tests**

Add these tests to `Tests/LungfishAppTests/ReleaseBuildConfigurationTests.swift`:

```swift
@Test("Bundled tool manifest excludes bbtools and openjdk")
func bundledToolManifestExcludesManagedCoreDependencies() throws {
    let manifest = try String(
        contentsOf: Self.repositoryRoot()
            .appendingPathComponent("Sources/LungfishWorkflow/Resources/Tools/tool-versions.json"),
        encoding: .utf8
    )

    #expect(manifest.contains(#""name": "bbtools""#) == false)
    #expect(manifest.contains(#""name": "openjdk""#) == false)
}

@Test("Notarized DMG release script no longer signs JRE launchers")
func notarizedDMGReleaseScriptNoLongerSignsJRELaunchers() throws {
    let script = try String(
        contentsOf: Self.repositoryRoot()
            .appendingPathComponent("scripts/release/build-notarized-dmg.sh"),
        encoding: .utf8
    )

    #expect(script.contains("sign_jre_launcher") == false)
    #expect(script.contains("jre/bin/java") == false)
}

@Test("Release smoke test asserts bbtools and JRE are not bundled")
func releaseSmokeTestAssertsBundledBBToolsAndJREAreAbsent() throws {
    let script = try String(
        contentsOf: Self.repositoryRoot()
            .appendingPathComponent("scripts/smoke-test-release-tools.sh"),
        encoding: .utf8
    )

    #expect(script.contains("bbtools should not be bundled"))
    #expect(script.contains("jre should not be bundled"))
}
```

- [ ] **Step 2: Run the release tests to verify they fail**

Run:

```bash
swift test --filter ReleaseBuildConfigurationTests
```

Expected: FAIL because the manifest and scripts still assume bundled BBTools/JRE.

- [ ] **Step 3: Remove BBTools/OpenJDK from bundled manifests and scripts**

Make these concrete changes:

In `Sources/LungfishWorkflow/Resources/Tools/tool-versions.json`, remove the entire `bbtools` and `openjdk` tool entries.

In `scripts/bundle-native-tools.sh`, remove the code path that downloads/copies BBTools and the Temurin/OpenJDK runtime.

In `scripts/update-tool-versions.sh`, remove the `bbtools)` and `openjdk)` case blocks and their generated summary entries.

In `scripts/sanitize-bundled-tools.sh`, remove the BBTools allowlist entries so the script only preserves actual remaining bundled wrappers:

```bash
case "$relative_path" in
    scrubber/scripts/scrub.sh|\
    scrubber/scripts/cut_spots_fastq.py|\
    scrubber/scripts/fastq_to_fasta.py)
        return 0
        ;;
esac
```

In `scripts/release/build-notarized-dmg.sh`, delete the entire `JRE_ENTITLEMENTS`, `sign_jre_launcher()`, and `is_jre_launcher_candidate()` block and the three explicit `sign_jre_launcher ...` calls.

In `scripts/smoke-test-release-tools.sh`, replace the JRE/BBTools checks with:

```bash
if [ -e "$TOOLS_DIR/bbtools" ]; then
    echo "bbtools should not be bundled: $TOOLS_DIR/bbtools" >&2
    exit 66
fi

if [ -e "$TOOLS_DIR/jre" ]; then
    echo "jre should not be bundled: $TOOLS_DIR/jre" >&2
    exit 66
fi

run_test samtools "$TOOLS_DIR/samtools" --version
run_test seqkit "$TOOLS_DIR/seqkit" version
run_test fastp "$TOOLS_DIR/fastp" --version
```

- [ ] **Step 4: Delete the bundled BBTools/JRE payloads and update docs/notices**

Run:

```bash
git rm -r Sources/LungfishWorkflow/Resources/Tools/bbtools
git rm -r Sources/LungfishWorkflow/Resources/Tools/jre
git rm scripts/release/jre-launcher.entitlements
```

Then update `README.md` and `THIRD-PARTY-NOTICES` so they describe:

```text
Core tools such as Nextflow, Snakemake, and BBTools are installed into ~/.lungfish the first time the user chooses Install on the welcome screen.
```

and remove the old bundled-Temurin redistribution note entirely.

- [ ] **Step 5: Run the release tests again**

Run:

```bash
swift test --filter ReleaseBuildConfigurationTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishWorkflow/Resources/Tools/tool-versions.json scripts/bundle-native-tools.sh scripts/update-tool-versions.sh scripts/sanitize-bundled-tools.sh scripts/release/build-notarized-dmg.sh scripts/smoke-test-release-tools.sh README.md THIRD-PARTY-NOTICES Tests/LungfishAppTests/ReleaseBuildConfigurationTests.swift
git commit -m "build: remove bundled bbtools and jre"
```

### Task 7: Run End-To-End Verification And Capture Release-Impact Measurements

**Files:**
- None required unless you choose to record measurements in the branch notes or PR description.

- [ ] **Step 1: Run the focused verification suite**

Run:

```bash
swift test --filter PluginPackRegistryTests
swift test --filter PluginPackStatusServiceTests
swift test --filter CondaPacksCommandTests
swift test --filter PluginPackVisibilityTests
swift test --filter WelcomeSetupTests
swift test --filter CoreToolLocatorTests
swift test --filter NativeToolRunnerTests
swift test --filter FASTQIngestionPipelineTests
swift test --filter FASTQToolIntegrationTests
swift test --filter ReleaseBuildConfigurationTests
```

Expected: PASS, with BBTools-dependent runtime tests skipping cleanly if `~/.lungfish/conda/envs/bbtools` is not installed on the local machine.

- [ ] **Step 2: Run the full package test suite**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 3: Measure bundle-size and tool-staging impact against the untouched main workspace**

Run:

```bash
du -sh /Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishWorkflow/Resources/Tools
/usr/bin/time -l bash -lc 'cd /Users/dho/Documents/lungfish-genome-explorer && ./scripts/bundle-native-tools.sh --arch arm64'
du -sh /Users/dho/Documents/lungfish-genome-explorer/.worktrees/base-tools-launch-refactor/Sources/LungfishWorkflow/Resources/Tools
/usr/bin/time -l bash -lc 'cd /Users/dho/Documents/lungfish-genome-explorer/.worktrees/base-tools-launch-refactor && ./scripts/bundle-native-tools.sh --arch arm64'
```

Expected: the refactor worktree reports a materially smaller `Resources/Tools` footprint and a shorter native-tool staging run than the untouched main workspace.

- [ ] **Step 4: Measure the notarized release-build impact when signing credentials are available**

Run:

```bash
if [ -n "${LUNGFISH_SIGNING_IDENTITY:-}" ] && [ -n "${LUNGFISH_TEAM_ID:-}" ] && [ -n "${LUNGFISH_NOTARY_PROFILE:-}" ]; then
  /usr/bin/time -l bash -lc 'cd /Users/dho/Documents/lungfish-genome-explorer && ./scripts/release/build-notarized-dmg.sh --signing-identity "$LUNGFISH_SIGNING_IDENTITY" --team-id "$LUNGFISH_TEAM_ID" --notary-profile "$LUNGFISH_NOTARY_PROFILE"'
  /usr/bin/time -l bash -lc 'cd /Users/dho/Documents/lungfish-genome-explorer/.worktrees/base-tools-launch-refactor && ./scripts/release/build-notarized-dmg.sh --signing-identity "$LUNGFISH_SIGNING_IDENTITY" --team-id "$LUNGFISH_TEAM_ID" --notary-profile "$LUNGFISH_NOTARY_PROFILE"'
fi
```

Expected: the refactor worktree’s notarized release build completes faster than main because there is no bundled JRE launcher signing and no bundled BBTools/JRE payload to stage.
