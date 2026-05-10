# Read Mapping Pack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an active `read-mapping` micromamba plugin pack, expose `BBMap` from the required BBTools environment, replace the minimap2-only mapping flow with a shared mapping dialog, and open completed runs in a `Mapping` list/detail viewport backed by canonical sorted, indexed BAM.

**Architecture:** Activate and rename the pack first, then add a mapper-neutral workflow layer (`MappingTool`, `MappingRunRequest`, `MappingCompatibility`, `MappingResult`, `ManagedMappingPipeline`, `MappingSummaryBuilder`). The app layer will route all four approved mappers through one shared dialog, normalize every mapper output to sorted/indexed BAM, persist `mapping-result.json`, and render the result in a mapping viewport whose detail pane opens an analysis-local viewer bundle whose manifest already includes the mapping BAM as an alignment track. When the selected reference already comes from a richer genome bundle, create a lightweight overlay bundle in the analysis directory by symlinking genome/annotation/variant assets and writing a cloned manifest with the new alignment track; when the selected reference is only a FASTA, create a minimal `.lungfishref` bundle first and then add the alignment track.

**Tech Stack:** Swift 6, AppKit, SwiftUI, XCTest, `CondaManager`, `NativeToolRunner`, `AlignmentDataProvider`, `ReferenceBundleImportService`, `ViewerViewController`, micromamba-managed Bioconda environments.

---

## File Map

- Create: `Sources/LungfishWorkflow/Mapping/MappingTool.swift`
  Responsibility: mapper enum, display names, executable names, pack/environment identity, and mode labels.
- Create: `Sources/LungfishWorkflow/Mapping/MappingCompatibility.swift`
  Responsibility: shared read-class and read-length compatibility rules, especially the BBMap `500` / `6000` gates.
- Create: `Sources/LungfishWorkflow/Mapping/MappingRunRequest.swift`
  Responsibility: mapper-neutral launch payload from UI/CLI into workflow execution, including reference bundle identity when available.
- Create: `Sources/LungfishWorkflow/Mapping/MappingResult.swift`
  Responsibility: canonical sorted/indexed BAM result model, per-contig summaries, sidecar persistence, and backward-safe loading.
- Create: `Sources/LungfishWorkflow/Mapping/MappingSummaryBuilder.swift`
  Responsibility: per-contig summary generation from sorted BAM using one `samtools coverage` pass plus one streamed `samtools view` pass for MAPQ/identity histograms.
- Create: `Sources/LungfishWorkflow/Mapping/ManagedMappingPipeline.swift`
  Responsibility: tool-specific command construction for `minimap2`, `bwa-mem2`, `bowtie2`, and `BBMap`, plus common post-processing to sorted/indexed BAM.
- Create: `Sources/LungfishWorkflow/Mapping/MappingCommandBuilder.swift`
  Responsibility: isolated command construction and reference-index staging for `bwa-mem2`, `bowtie2`, and `BBMap`.
- Create: `Sources/LungfishApp/Views/Mapping/MappingWizardSheet.swift`
  Responsibility: shared mapper sidebar/detail pane configuration UI used from FASTQ operations.
- Create: `Sources/LungfishApp/Views/Mapping/MappingCompatibilityPresentation.swift`
  Responsibility: small UI adapter that maps workflow compatibility state to Lungfish status strings and palette choices.
- Create: `Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift`
  Responsibility: list/detail split view, contig table, selection handling, and embedded mapping detail viewer.
- Create: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift`
  Responsibility: mount and unmount the mapping result viewport inside the main viewer, parallel to the existing assembly helpers.
- Create: `Sources/LungfishApp/Services/MappingDisplayBundleBuilder.swift`
  Responsibility: build the analysis-local viewer bundle, either by cloning/symlinking a source genome bundle or by creating a minimal bundle from a FASTA and then adding the mapping alignment track.
- Create: `Tests/LungfishWorkflowTests/Mapping/MappingCompatibilityTests.swift`
  Responsibility: tool/read-class/read-length matrix coverage, including BBMap mode blocking.
- Create: `Tests/LungfishWorkflowTests/Mapping/ManagedMappingPipelineTests.swift`
  Responsibility: command construction, reference-index staging, and sorted/indexed output normalization coverage.
- Create: `Tests/LungfishWorkflowTests/Mapping/MappingResultSidecarTests.swift`
  Responsibility: `mapping-result.json` round-trip coverage and viewer-bundle/source-bundle persistence.
- Create: `Tests/LungfishWorkflowTests/Mapping/MappingSummaryBuilderTests.swift`
  Responsibility: per-contig metric parsing and weighted-identity calculations.
- Create: `Tests/LungfishAppTests/MappingResultViewControllerTests.swift`
  Responsibility: contig-table rendering, initial selection, and detail-view synchronization.
- Create: `Tests/LungfishAppTests/MainSplitViewMappingRoutingTests.swift`
  Responsibility: routing coverage for reopening saved mapping analyses through `MainSplitViewController`.
- Create: `Tests/LungfishAppTests/MappingCompatibilityPresentationTests.swift`
  Responsibility: readiness and blocking-message coverage for the shared mapping pane.
- Modify: `Sources/LungfishWorkflow/Conda/PluginPack.swift`
  Responsibility: rename/activate the optional pack as `read-mapping`, remove `hisat2`, add explicit tool metadata, and expose extra BBTools executables.
- Modify: `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`
  Responsibility: register `bbmap.sh` and `mapPacBio.sh` in the required BBTools environment.
- Modify: `Sources/LungfishWorkflow/Native/NativeToolRunner.swift`
  Responsibility: add `bbmap` and `mapPacBio` native-tool entries and BBTools-shell-script handling.
- Modify: `Sources/LungfishIO/Formats/FASTQ/ReferenceCandidate.swift`
  Responsibility: preserve source genome-bundle URL when the mapping reference comes from an existing bundle.
- Modify: `Sources/LungfishIO/Formats/FASTQ/ReferenceSequenceScanner.swift`
  Responsibility: populate the new bundle-aware `ReferenceCandidate` payloads so source-bundle identity survives discovery.
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationsCatalog.swift`
  Responsibility: gate the `MAPPING` category on `read-mapping` rather than the old `alignment` pack.
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift`
  Responsibility: add shared mapping state, new mapper tool IDs, readiness text, and `pendingMappingRequest`.
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift`
  Responsibility: swap the minimap2-specific pane for the shared mapping pane.
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialog.swift`
  Responsibility: observe `pendingMappingRequest` so embedded mapping sheets actually dismiss and submit.
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
  Responsibility: run `MappingRunRequest`, build analysis-local viewer bundles when needed, persist `MappingResult`, and record the new analysis manifest entries.
- Modify: `Sources/LungfishCLI/Commands/MapCommand.swift`
  Responsibility: point CLI help at `read-mapping`, add mapper selection, and route to the managed mapping pipeline.
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
  Responsibility: route mapping analyses into the new mapping viewport instead of the minimap2 placeholder.
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
  Responsibility: add hide/reset coverage for the mapping viewport so `clearViewport()` and mode switches cleanly remove it.
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`
  Responsibility: show `mapping` analyses with a first-class icon/title instead of the generic fallback circle.
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/AnalysesSection.swift`
  Responsibility: give mapping analyses the same explicit icon/color treatment as other result families.
- Modify: `Sources/LungfishIO/Bundles/AnalysesFolder.swift`
  Responsibility: recognize `mapping`, `bwa-mem2`, `bowtie2`, and `bbmap` analysis directories.
- Modify: `Sources/LungfishApp/Views/Results/Alignment/AlignmentResultViewController.swift`
  Responsibility: retire or replace the BAM stub with the new `MappingResultViewController`.
- Modify tests: `Tests/LungfishWorkflowTests/PluginPackRegistryTests.swift`, `Tests/LungfishWorkflowTests/NativeToolRunnerTests.swift`, `Tests/LungfishWorkflowTests/CondaManagerTests.swift`, `Tests/LungfishAppTests/FASTQOperationsCatalogTests.swift`, `Tests/LungfishAppTests/FASTQOperationDialogRoutingTests.swift`, `Tests/LungfishCLITests/CLIRegressionTests.swift`
  Responsibility: lock in pack identity, mapper visibility, routing, and CLI help text.
- Modify tests: `Tests/LungfishCLITests/CondaPacksCommandTests.swift`, `Tests/LungfishAppTests/PluginPackVisibilityTests.swift`, `Tests/LungfishAppTests/WelcomeSetupTests.swift`
  Responsibility: keep pack-listing UIs aligned with the newly active `read-mapping` pack.

## Task 1: Activate The Read-Mapping Pack And Expose BBMap From Required Setup

**Files:**
- Modify: `Sources/LungfishWorkflow/Conda/PluginPack.swift`
- Modify: `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`
- Modify: `Sources/LungfishWorkflow/Native/NativeToolRunner.swift`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationsCatalog.swift`
- Modify: `Tests/LungfishWorkflowTests/PluginPackRegistryTests.swift`
- Modify: `Tests/LungfishWorkflowTests/NativeToolRunnerTests.swift`
- Modify: `Tests/LungfishAppTests/FASTQOperationsCatalogTests.swift`
- Modify: `Tests/LungfishWorkflowTests/CondaManagerTests.swift`
- Modify: `Tests/LungfishCLITests/CondaPacksCommandTests.swift`
- Modify: `Tests/LungfishAppTests/PluginPackVisibilityTests.swift`
- Modify: `Tests/LungfishAppTests/WelcomeSetupTests.swift`

- [ ] **Step 1: Add failing tests for the renamed pack and required BBTools executables**

Add assertions that the mapping category requires `read-mapping`, the active optional packs include `read-mapping`, and the required BBTools environment now exposes both `bbmap.sh` and `mapPacBio.sh`:

```swift
XCTAssertEqual(PluginPack.activeOptionalPacks.map(\.id), ["read-mapping", "assembly", "metagenomics"])

let bbtools = try XCTUnwrap(
    PluginPack.requiredSetupPack.toolRequirements.first(where: { $0.environment == "bbtools" })
)
XCTAssertEqual(
    bbtools.executables,
    ["clumpify.sh", "bbduk.sh", "bbmerge.sh", "repair.sh", "tadpole.sh", "reformat.sh", "bbmap.sh", "mapPacBio.sh", "java"]
)

let category = try XCTUnwrap(await FASTQOperationsCatalog(statusProvider: provider).category(id: .mapping))
XCTAssertEqual(category.requiredPackIDs, ["read-mapping"])

XCTAssertEqual(viewModel.optionalPackStatuses.map(\.pack.id), ["read-mapping", "assembly", "metagenomics"])
```

- [ ] **Step 2: Run the pack-facing test slice and verify it fails before the metadata change**

Run:

```bash
swift test --filter PluginPackRegistryTests
swift test --filter NativeToolRunnerTests
swift test --filter FASTQOperationsCatalogTests
swift test --filter CondaManagerTests
swift test --filter CondaPacksCommandTests
swift test --filter PluginPackVisibilityTests
swift test --filter WelcomeSetupTests
```

Expected: FAIL because the optional pack is still named `alignment`, `hisat2` is still present, and the BBTools executable list still omits `bbmap.sh` and `mapPacBio.sh`.

- [ ] **Step 3: Rename the pack to `read-mapping`, remove `hisat2`, and register the extra BBTools executables**

Implement explicit tool requirements rather than the old bare package list:

```swift
PluginPack(
    id: "read-mapping",
    name: "Read Mapping",
    description: "Reference-guided mapping for short and long sequencing reads",
    sfSymbol: "arrow.left.and.right.text.vertical",
    packages: ["minimap2", "bwa-mem2", "bowtie2"],
    category: "Mapping",
    isActive: true,
    requirements: [
        PackToolRequirement(
            id: "minimap2",
            displayName: "minimap2",
            environment: "minimap2",
            installPackages: ["bioconda::minimap2"],
            executables: ["minimap2"],
            smokeTest: .command(arguments: ["--help"], timeoutSeconds: 10, acceptedExitCodes: [0, 1], requiredOutputSubstring: "Usage"),
            sourceURL: "https://github.com/lh3/minimap2"
        ),
        PackToolRequirement(
            id: "bwa-mem2",
            displayName: "BWA-MEM2",
            environment: "bwa-mem2",
            installPackages: ["bioconda::bwa-mem2"],
            executables: ["bwa-mem2"],
            smokeTest: .command(arguments: ["version"], timeoutSeconds: 10, acceptedExitCodes: [0], requiredOutputSubstring: "bwa-mem2"),
            sourceURL: "https://github.com/bwa-mem2/bwa-mem2"
        ),
        PackToolRequirement(
            id: "bowtie2",
            displayName: "Bowtie2",
            environment: "bowtie2",
            installPackages: ["bioconda::bowtie2"],
            executables: ["bowtie2", "bowtie2-build"],
            smokeTest: .command(arguments: ["--help"], timeoutSeconds: 10, acceptedExitCodes: [0, 1], requiredOutputSubstring: "bowtie2"),
            sourceURL: "https://bowtie-bio.sourceforge.net/bowtie2/manual.shtml"
        ),
    ],
    estimatedSizeMB: 260
)
```

Also extend the required BBTools entries:

```json
"executables": ["clumpify.sh", "bbduk.sh", "bbmerge.sh", "repair.sh", "tadpole.sh", "reformat.sh", "bbmap.sh", "mapPacBio.sh", "java"]
```

and add:

```swift
case bbmap
case mapPacBio
```

to `NativeToolRunner.NativeTool`.

- [ ] **Step 4: Re-run the pack-facing tests and verify the new pack surface is green**

Run:

```bash
swift test --filter PluginPackRegistryTests
swift test --filter NativeToolRunnerTests
swift test --filter FASTQOperationsCatalogTests
swift test --filter CondaManagerTests
swift test --filter CondaPacksCommandTests
swift test --filter PluginPackVisibilityTests
swift test --filter WelcomeSetupTests
```

Expected: PASS with `read-mapping` visible as an active optional pack and the BBTools environment exposing `bbmap.sh` and `mapPacBio.sh`.

- [ ] **Step 5: Commit the pack-surface tranche**

Run:

```bash
git add Sources/LungfishWorkflow/Conda/PluginPack.swift Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json Sources/LungfishWorkflow/Native/NativeToolRunner.swift Sources/LungfishApp/Views/FASTQ/FASTQOperationsCatalog.swift Tests/LungfishWorkflowTests/PluginPackRegistryTests.swift Tests/LungfishWorkflowTests/NativeToolRunnerTests.swift Tests/LungfishAppTests/FASTQOperationsCatalogTests.swift Tests/LungfishWorkflowTests/CondaManagerTests.swift Tests/LungfishCLITests/CondaPacksCommandTests.swift Tests/LungfishAppTests/PluginPackVisibilityTests.swift Tests/LungfishAppTests/WelcomeSetupTests.swift
git commit -m "feat: add read mapping pack metadata"
```

## Task 2: Add The Shared Mapping Domain Model, Compatibility Rules, And Sidecar Format

**Files:**
- Create: `Sources/LungfishWorkflow/Mapping/MappingTool.swift`
- Create: `Sources/LungfishWorkflow/Mapping/MappingCompatibility.swift`
- Create: `Sources/LungfishWorkflow/Mapping/MappingRunRequest.swift`
- Create: `Sources/LungfishWorkflow/Mapping/MappingResult.swift`
- Create: `Tests/LungfishWorkflowTests/Mapping/MappingCompatibilityTests.swift`
- Create: `Tests/LungfishWorkflowTests/Mapping/MappingResultSidecarTests.swift`
- Modify: `Sources/LungfishIO/Formats/FASTQ/ReferenceCandidate.swift`
- Modify: `Sources/LungfishIO/Formats/FASTQ/ReferenceSequenceScanner.swift`

- [ ] **Step 1: Write failing tests for tool compatibility and mapping-result persistence**

Add tests that pin the supported mapper matrix and BBMap length thresholds:

```swift
XCTAssertEqual(
    MappingCompatibility.evaluate(tool: .bbmap, mode: .bbmapStandard, readClass: .ontLongReads, observedMaxReadLength: 1200).state,
    .blocked("Standard BBMap mode supports reads up to 500 bases. Switch to PacBio mode or choose another mapper.")
)

XCTAssertEqual(
    MappingCompatibility.evaluate(tool: .bbmap, mode: .bbmapPacBio, readClass: .pacBioCLR, observedMaxReadLength: 7001).state,
    .blocked("BBMap PacBio mode supports reads up to 6000 bases. Choose another mapper for longer reads.")
)
```

and a sidecar round trip:

```swift
let result = MappingResult(
    mapper: .minimap2,
    modeID: "map-ont",
    sourceReferenceBundleURL: URL(fileURLWithPath: "/tmp/source.lungfishref"),
    viewerBundleURL: URL(fileURLWithPath: "/tmp/viewer.lungfishref"),
    bamURL: URL(fileURLWithPath: "/tmp/sample.sorted.bam"),
    baiURL: URL(fileURLWithPath: "/tmp/sample.sorted.bam.bai"),
    totalReads: 1000,
    mappedReads: 950,
    unmappedReads: 50,
    wallClockSeconds: 12.5,
    contigs: []
)
```

Also add a legacy-load expectation so pre-existing minimap2 analyses survive the rename:

```swift
let legacy = try MappingResult.load(from: fixtureDirectoryContainingLegacyAlignmentResult)
XCTAssertEqual(legacy.mapper, .minimap2)
XCTEqual(legacy.bamURL.lastPathComponent, "sample.sorted.bam")
```

- [ ] **Step 2: Run the new mapping-domain tests and verify they fail**

Run:

```bash
swift test --filter MappingCompatibilityTests
swift test --filter MappingResultSidecarTests
```

Expected: FAIL because the mapping domain files and `mapping-result.json` do not exist yet.

- [ ] **Step 3: Implement the neutral mapping model and preserve reference-bundle identity**

Add the mapper enum and request/result types:

```swift
public enum MappingTool: String, CaseIterable, Sendable, Codable {
    case minimap2
    case bwaMem2 = "bwa-mem2"
    case bowtie2
    case bbmap
}

public struct MappingRunRequest: Sendable, Codable, Equatable {
    public let tool: MappingTool
    public let modeID: String
    public let inputFASTQURLs: [URL]
    public let referenceFASTAURL: URL
    public let sourceReferenceBundleURL: URL?
    public let outputDirectory: URL
    public let sampleName: String
    public let threads: Int
    public let advancedArguments: [String]
}
```

and sidecar persistence:

```swift
private let mappingResultFilename = "mapping-result.json"
```

Also extend `ReferenceCandidate` so bundle-backed FASTA picks keep their parent bundle URL:

```swift
case genomeBundleFASTA(fastaURL: URL, bundleURL: URL, displayName: String)
```

Update `ReferenceSequenceScanner` at the same time so the discovered candidates actually populate the new payload:

```swift
references.append(
    .genomeBundleFASTA(
        fastaURL: fastaURL,
        bundleURL: bundleURL,
        displayName: displayName
    )
)
```

- [ ] **Step 4: Re-run the mapping-domain tests and verify the model is stable**

Run:

```bash
swift test --filter MappingCompatibilityTests
swift test --filter MappingResultSidecarTests
```

Expected: PASS with explicit coverage for the `500` / `6000` BBMap gates and `mapping-result.json` persistence.

- [ ] **Step 5: Commit the workflow-model tranche**

Run:

```bash
git add Sources/LungfishWorkflow/Mapping Sources/LungfishIO/Formats/FASTQ/ReferenceCandidate.swift Tests/LungfishWorkflowTests/Mapping
git commit -m "feat: add shared mapping workflow model"
```

## Task 3: Implement Managed Mapping Execution And Canonical BAM Post-Processing

**Files:**
- Create: `Sources/LungfishWorkflow/Mapping/MappingCommandBuilder.swift`
- Create: `Sources/LungfishWorkflow/Mapping/MappingSummaryBuilder.swift`
- Create: `Sources/LungfishWorkflow/Mapping/ManagedMappingPipeline.swift`
- Create: `Tests/LungfishWorkflowTests/Mapping/ManagedMappingPipelineTests.swift`
- Create: `Tests/LungfishWorkflowTests/Mapping/MappingSummaryBuilderTests.swift`
- Modify: `Sources/LungfishCLI/Commands/MapCommand.swift`

- [ ] **Step 1: Write failing pipeline tests for each mapper family and the canonical sorted/indexed BAM contract**

Add tests that pin the command shape:

```swift
XCTAssertEqual(command.executable, "bwa-mem2")
XCTAssertEqual(command.arguments.prefix(2), ["mem", "-t"])

XCTAssertEqual(command.executable, "bowtie2")
XCTAssertTrue(command.arguments.contains("-x"))

XCTAssertEqual(command.executable, "bbmap.sh")
XCTAssertTrue(command.arguments.contains("ref=/tmp/reference.fa"))
XCTAssertEqual(nativeToolCalls.first?.tool, .bbmap)

let samResult = try await pipeline.normalizeAlignment(
    rawAlignmentURL: URL(fileURLWithPath: "/tmp/sample.sam"),
    outputDirectory: URL(fileURLWithPath: "/tmp")
)
XCTAssertEqual(samResult.bamURL.lastPathComponent, "sample.sorted.bam")
XCTAssertEqual(recordedSamtoolsCalls.map(\.arguments.first), ["view", "sort", "index"])

let bamResult = try await pipeline.normalizeAlignment(
    rawAlignmentURL: URL(fileURLWithPath: "/tmp/sample.unsorted.bam"),
    outputDirectory: URL(fileURLWithPath: "/tmp")
)
XCTAssertEqual(bamResult.bamURL.lastPathComponent, "sample.sorted.bam")
XCTAssertEqual(recordedSamtoolsCalls.suffix(2).map(\.arguments.first), ["sort", "index"])

let alreadySorted = try await pipeline.normalizeAlignment(
    rawAlignmentURL: URL(fileURLWithPath: "/tmp/sample.sorted.bam"),
    outputDirectory: URL(fileURLWithPath: "/tmp")
)
XCTAssertEqual(alreadySorted.bamURL.lastPathComponent, "sample.sorted.bam")
XCTAssertEqual(recordedSamtoolsCalls.suffix(1).map(\.arguments.first), ["index"])
```

- [ ] **Step 2: Run the pipeline tests and verify they fail before implementation**

Run:

```bash
swift test --filter ManagedMappingPipelineTests
swift test --filter MappingSummaryBuilderTests
```

Expected: FAIL because the shared pipeline, summary builder, and command builder do not exist.

- [ ] **Step 3: Implement tool-specific command construction and common SAM/BAM normalization**

Build each mapper as a `MappingCommandBuilder.Command` and then normalize output through the same post-processing tail:

```swift
switch rawAlignmentURL.pathExtension.lowercased() {
case "sam":
    let tempBAM = outputDirectory.appendingPathComponent(rawAlignmentURL.deletingPathExtension().lastPathComponent + ".bam")
    try await condaManager.runTool(
        "samtools",
        arguments: ["view", "-@", String(sortThreads), "-b", "-o", tempBAM.path, rawAlignmentURL.path]
    )
    try await sortAndIndex(tempBAM)
case "bam" where rawAlignmentURL.lastPathComponent.hasSuffix(".sorted.bam"):
    try await condaManager.runTool(
        "samtools",
        arguments: ["index", rawAlignmentURL.path]
    )
default:
    try await sortAndIndex(rawAlignmentURL)
}
```

For mapper-specific setup:

```swift
// bwa-mem2 index staged in a temp directory so source references are not mutated.
["index", stagedReference.path]

// bowtie2-build writes to a temp prefix, then bowtie2 maps with -x <prefix>.
["bowtie2-build", stagedReference.path, indexPrefix.path]

// BBMap standard vs PacBio mode
let executable = request.modeID == "pacbio" ? "mapPacBio.sh" : "bbmap.sh"
```

Route BBMap through `NativeToolRunner`, not generic `CondaManager.runTool`, so the existing BBTools wrapper logic keeps `key=value` arguments and path quoting intact:

```swift
let tool: NativeToolRunner.NativeTool = request.modeID == "pacbio" ? .mapPacBio : .bbmap
try await nativeToolRunner.run(
    tool,
    arguments: command.arguments,
    in: request.outputDirectory
)
```

- [ ] **Step 4: Implement per-contig metrics and generic CLI routing**

Use one `samtools coverage` pass for contig inventory, mapped reads, breadth, mean depth, and mean mapq, then one streamed `samtools view` pass for weighted identity:

```swift
let coverageRows = try await condaManager.captureOutput(
    tool: "samtools",
    arguments: ["coverage", sortedBAM.path]
)

for try await record in SAMRecordStream(sortedBAM: sortedBAM, condaManager: condaManager) {
    let alignedQueryBases = record.cigar.reduce(0) { partial, op in
        partial + (op.consumesQuery && op.op != .softClip ? op.length : 0)
    }
    let editDistance = record.editDistance ?? 0
    accumulators[record.referenceName].add(
        alignedQueryBases: alignedQueryBases,
        editDistance: editDistance,
        mappingQuality: record.mappingQuality
    )
}
```

Update the CLI to carry the mapper through:

```swift
@Option(name: .customLong("mapper"), help: "Mapper: minimap2, bwa-mem2, bowtie2, bbmap")
var mapper: String = "minimap2"
```

- [ ] **Step 5: Re-run the workflow and CLI test slice**

Run:

```bash
swift test --filter ManagedMappingPipelineTests
swift test --filter MappingSummaryBuilderTests
swift test --filter CLIRegressionTests
```

Expected: PASS with command construction locked for all four mappers, canonical SAM/BAM normalization verified across raw SAM, unsorted BAM, and already-sorted BAM inputs, and CLI help asserting both `--mapper` and `read-mapping` are present:

```swift
let help = MapCommand.helpMessage()
XCTAssertTrue(help.contains("--mapper"))
XCTAssertTrue(help.contains("read-mapping"))
```

## Task 4: Replace The Minimap2-Only UI With The Shared Mapping Dialog And Launch Path

**Files:**
- Create: `Sources/LungfishApp/Views/Mapping/MappingWizardSheet.swift`
- Create: `Sources/LungfishApp/Views/Mapping/MappingCompatibilityPresentation.swift`
- Create: `Tests/LungfishAppTests/MappingCompatibilityPresentationTests.swift`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialog.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Modify: `Tests/LungfishAppTests/FASTQOperationDialogRoutingTests.swift`

- [ ] **Step 1: Add failing UI tests for the four-tool mapping sidebar and embedded-run capture**

Add routing expectations like:

```swift
XCTAssertEqual(FASTQOperationDialogState.toolIDs(for: .mapping), [.minimap2, .bwaMem2, .bowtie2, .bbmap])

state.selectTool(.bbmap)
state.prepareForRun()
XCTNil(state.pendingMappingRequest)

state.captureMappingRequest(request)
XCTEqual(state.pendingMappingRequest?.tool, .bbmap)

state.selectTool(.minimap2)
XCTEqual(state.outputStrategyOptions, [.perInput])
```

- [ ] **Step 2: Run the mapping-dialog test slice and verify it fails**

Run:

```bash
swift test --filter FASTQOperationDialogRoutingTests
swift test --filter MappingCompatibilityPresentationTests
```

Expected: FAIL because the FASTQ dialog still exposes only `.minimap2` and still stores `pendingMinimap2Config`.

- [ ] **Step 3: Replace the minimap2-specific dialog state with shared mapping state and embedded submission**

Update the tool IDs and pending state:

```swift
case minimap2
case bwaMem2
case bowtie2
case bbmap

var pendingMappingRequest: MappingRunRequest?
```

and capture the embedded run through the new shared sheet:

```swift
func captureMappingRequest(_ request: MappingRunRequest) {
    pendingLaunchRequest = nil
    pendingMappingRequest = request
}
```

Restrict mapping to single-result output in v1 so the reopen path stays on `.analysisResult` rather than `.batchGroup`:

```swift
var outputStrategyOptions: [FASTQOperationOutputMode] {
    selectedToolID.categoryID == .mapping
        ? [.perInput]
        : (showsOutputStrategyPicker ? [.perInput, .groupedResult] : [.fixedBatch])
}
```

and update the dialog observer so embedded mapping runs actually dismiss and submit:

```swift
.onChange(of: state.pendingMappingRequest?.sampleName) { _, _ in
    guard state.pendingMappingRequest != nil else { return }
    onRun(state)
    dismiss()
}
```

- [ ] **Step 4: Implement the shared mapping pane and run it from `AppDelegate`**

Use the existing `DatasetOperationsDialog` shell and route the run through the generic pipeline:

```swift
MappingWizardSheet(
    inputFiles: state.selectedInputURLs,
    projectURL: state.projectURL,
    embeddedInOperationsDialog: true,
    embeddedRunTrigger: state.embeddedRunTrigger,
    onRun: state.captureMappingRequest(_:),
    onRunnerAvailabilityChange: state.updateEmbeddedReadiness(_:)
)
```

and in `AppDelegate`:

```swift
if let request = state.pendingMappingRequest {
    self.runMapping(request: request)
    return
}
```

Preserve the current virtual-file materialization behavior from the minimap2 path before launching the pipeline:

```swift
let inputFiles = try resolveInputFiles(
    from: request.inputFASTQURLs,
    preferredProjectURL: request.projectURL
)
let materializedRequest = request.withInputFASTQURLs(inputFiles)
try await runManagedMapping(materializedRequest)
```

- [ ] **Step 5: Re-run the mapping-dialog tests**

Run:

```bash
swift test --filter FASTQOperationDialogRoutingTests
swift test --filter MappingCompatibilityPresentationTests
```

Expected: PASS with all four mappers visible and the embedded sheet capturing `MappingRunRequest` instead of `Minimap2Config`.

## Task 5: Build The Mapping Viewport, Create The Viewer Bundle, And Route Analysis Reopening

**Files:**
- Create: `Sources/LungfishApp/Services/MappingDisplayBundleBuilder.swift`
- Create: `Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift`
- Create: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift`
- Create: `Tests/LungfishAppTests/MappingResultViewControllerTests.swift`
- Create: `Tests/LungfishAppTests/MainSplitViewMappingRoutingTests.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/AnalysesSection.swift`
- Modify: `Sources/LungfishIO/Bundles/AnalysesFolder.swift`
- Modify: `Sources/LungfishApp/Views/Results/Alignment/AlignmentResultViewController.swift`

- [ ] **Step 1: Write failing tests for mapping-result loading and initial contig selection**

Add tests like:

```swift
let controller = MappingResultViewController()
controller.loadViewIfNeeded()
controller.configure(result: result)

XCTAssertEqual(controller.numberOfRows(in: controller.contigTableView), 2)
XCTAssertEqual(controller.selectedContigName, "chr1")
```

and a routing expectation:

```swift
XCTAssertTrue(AnalysesFolder.knownTools.contains("mapping"))
XCTAssertTrue(AnalysesFolder.knownTools.contains("bbmap"))

mainSplitViewController.displayMappingAnalysisFromSidebar(at: mappingAnalysisURL)
XCTAssertNotNil(mainSplitViewController.viewerController.mappingResultController)
```

- [ ] **Step 2: Run the viewport test slice and verify it fails**

Run:

```bash
swift test --filter MappingResultViewControllerTests
swift test --filter MainSplitViewMappingRoutingTests
```

Expected: FAIL because the mapping result controller does not exist and sidebar reopening still clears the viewport for minimap2 analyses.

- [ ] **Step 3: Persist `MappingResult` from the app layer and build the analysis-local viewer bundle**

After the pipeline completes, create the stable reference substrate:

```swift
let viewerBundleURL = try await MappingDisplayBundleBuilder.build(
    referenceFASTAURL: request.referenceFASTAURL,
    sourceReferenceBundleURL: request.sourceReferenceBundleURL,
    bamURL: result.bamURL,
    baiURL: result.baiURL,
    outputDirectory: request.outputDirectory,
    displayName: request.sampleName
)

let persisted = result.withViewerBundle(
    viewerBundleURL: viewerBundleURL,
    sourceReferenceBundleURL: request.sourceReferenceBundleURL
)
try persisted.save(to: request.outputDirectory)
```

- [ ] **Step 4: Implement the list/detail viewport, viewer lifecycle, and immediate-open behavior**

Embed a child `ViewerViewController` inside `MappingResultViewController` and load the prepared viewer bundle directly:

```swift
try viewerController.displayBundle(at: result.viewerBundleURL)
viewerController.navigateToPosition(chromosome: contig.contigName, start: 0, end: min(contig.contigLength, 10_000))
```

Route analyses back into the viewport:

```swift
if toolId.hasPrefix("mapping") || toolId.hasPrefix("minimap2") || toolId.hasPrefix("bwa-mem2") || toolId.hasPrefix("bowtie2") || toolId.hasPrefix("bbmap") {
    displayMappingAnalysisFromSidebar(at: url)
}
```

Add the same kind of hide/reset coverage that the viewer already uses for assembly and taxonomy views so `clearViewport()` cannot leave a mapping split view mounted:

```swift
hideMappingView()
mappingResultController = nil
```

Open the finished mapping result immediately after success, not only after a later sidebar click:

```swift
self.mainWindowController?.mainSplitViewController?.sidebarController.reloadFromFilesystem()
self.mainWindowController?.mainSplitViewController?.displayMappingAnalysisFromSidebar(at: capturedRequest.outputDirectory)
```

- [ ] **Step 5: Re-run the viewport and reopening verification**

Run:

```bash
swift test --filter MappingResultViewControllerTests
swift test --filter MainSplitViewMappingRoutingTests
swift test --filter FASTQOperationDialogRoutingTests
```

Expected: PASS with mapping analyses reopening into a contig list/detail viewer instead of the old placeholder.
