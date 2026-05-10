# BAM Variant Calling Dialog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a bundle-scoped BAM variant-calling workflow that activates a viral `variant-calling` pack (`LoFreq`, `iVar`, `Medaka`), runs the caller through `lungfish-cli`, persists real `VCF.gz` / `.tbi` / SQLite artifacts, and launches from a new inspector-backed operations dialog.

**Architecture:** The work lands in four layers. `LungfishWorkflow` owns pack metadata, tool resolution, BAM/reference preflight, caller pipeline models, and the bundle-attachment/import helpers. `LungfishIO` extends `VariantDatabase` with a viral/sample-less import mode so SQLite storage stays truthful for AF-first viral callsets. `lungfish-cli` adds a `variants` command family plus internal helper subcommands that preserve helper/resume/materialization behavior. `LungfishApp` adds a BAM variant-calling dialog, a CLI event runner, and inspector wiring through `OperationCenter`.

**Tech Stack:** Swift 6.2, ArgumentParser, SwiftUI + AppKit, `OperationCenter`, `PluginPackStatusService`, `NativeToolRunner`, `samtools` / `bcftools` / `bgzip` / `tabix`, SQLite-backed `VariantDatabase`, XCTest.

---

## File Structure

### Modify

- `Sources/LungfishWorkflow/Conda/PluginPack.swift`
- `Sources/LungfishWorkflow/Native/NativeToolRunner.swift`
- `Sources/LungfishWorkflow/Extraction/BAMToFASTQConverter.swift`
- `Sources/LungfishIO/Bundles/VariantDatabase.swift`
- `Sources/LungfishCLI/LungfishCLI.swift`
- `Sources/LungfishApp/Services/DownloadCenter.swift`
- `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift`
- `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- `Tests/LungfishWorkflowTests/CondaManagerTests.swift`
- `Tests/LungfishWorkflowTests/PluginPackRegistryTests.swift`
- `Tests/LungfishWorkflowTests/NativeToolRunnerTests.swift`
- `Tests/LungfishWorkflowTests/PluginPackStatusServiceTests.swift`
- `Tests/LungfishAppTests/PluginPackVisibilityTests.swift`
- `Tests/LungfishAppTests/WelcomeSetupTests.swift`
- `Tests/LungfishAppTests/DownloadCenterTests.swift`
- `Tests/LungfishCLITests/CLIRegressionTests.swift`

### Create

- `Sources/LungfishWorkflow/Variants/BundleVariantCallingModels.swift`
- `Sources/LungfishWorkflow/Variants/BAMVariantCallingPreflight.swift`
- `Sources/LungfishWorkflow/Variants/VariantSQLiteImportCoordinator.swift`
- `Sources/LungfishWorkflow/Variants/BundleVariantTrackAttachmentService.swift`
- `Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift`
- `Sources/LungfishCLI/Commands/VariantsCommand.swift`
- `Sources/LungfishApp/Services/CLIVariantCallingRunner.swift`
- `Sources/LungfishApp/Views/BAM/BAMVariantCallingCatalog.swift`
- `Sources/LungfishApp/Views/BAM/BAMVariantCallingDialogState.swift`
- `Sources/LungfishApp/Views/BAM/BAMVariantCallingDialog.swift`
- `Sources/LungfishApp/Views/BAM/BAMVariantCallingToolPanes.swift`
- `Sources/LungfishApp/Views/BAM/BAMVariantCallingDialogPresenter.swift`
- `Tests/LungfishWorkflowTests/Variants/BAMVariantCallingPreflightTests.swift`
- `Tests/LungfishWorkflowTests/Variants/BundleVariantTrackAttachmentServiceTests.swift`
- `Tests/LungfishWorkflowTests/Variants/ViralVariantCallingPipelineTests.swift`
- `Tests/LungfishCLITests/VariantsCommandTests.swift`
- `Tests/LungfishAppTests/CLIVariantCallingRunnerTests.swift`
- `Tests/LungfishAppTests/BAMVariantCallingDialogRoutingTests.swift`

## Task 1: Activate The Variant-Calling Pack

**Files:**
- Modify: `Sources/LungfishWorkflow/Conda/PluginPack.swift`
- Modify: `Sources/LungfishWorkflow/Native/NativeToolRunner.swift`
- Test: `Tests/LungfishWorkflowTests/CondaManagerTests.swift`
- Test: `Tests/LungfishWorkflowTests/PluginPackRegistryTests.swift`
- Test: `Tests/LungfishWorkflowTests/NativeToolRunnerTests.swift`
- Test: `Tests/LungfishWorkflowTests/PluginPackStatusServiceTests.swift`
- Test: `Tests/LungfishAppTests/PluginPackVisibilityTests.swift`
- Test: `Tests/LungfishAppTests/WelcomeSetupTests.swift`

- [ ] **Step 1: Write failing pack-metadata tests**

```swift
func testVariantCallingPackIsActiveAndViralScoped() throws {
    let pack = try XCTUnwrap(PluginPack.activeOptionalPacks.first(where: { $0.id == "variant-calling" }))
    XCTAssertEqual(pack.description, "Viral BAM variant calling from bundle-owned alignment tracks")
    XCTAssertEqual(pack.toolRequirements.map(\.environment), ["lofreq", "ivar", "medaka"])
}

func testVisibleCLIPacksIncludeVariantCalling() {
    XCTAssertEqual(
        PluginPack.visibleForCLI.map(\.id),
        ["lungfish-tools", "variant-calling", "assembly", "metagenomics"]
    )
}

func testNativeToolRunnerDefinesVariantCallingExecutables() {
    XCTAssertEqual(NativeTool.lofreq.executableName, "lofreq")
    XCTAssertEqual(NativeTool.ivar.executableName, "ivar")
    XCTAssertEqual(NativeTool.medaka.executableName, "medaka")
}
```

- [ ] **Step 2: Run the pack-focused tests and watch them fail**

Run:

```bash
swift test --filter 'CondaManagerTests|PluginPackRegistryTests|NativeToolRunnerTests|PluginPackStatusServiceTests|PluginPackVisibilityTests|WelcomeSetupTests'
```

Expected: failures because `variant-calling` is inactive, not modeled in `NativeTool`, and pack order expectations still assume only `assembly` and `metagenomics`.

- [ ] **Step 3: Activate the pack and add the tool requirements**

```swift
PluginPack(
    id: "variant-calling",
    name: "Variant Calling",
    description: "Viral BAM variant calling from bundle-owned alignment tracks",
    sfSymbol: "diamond.fill",
    packages: ["lofreq", "ivar", "medaka"],
    category: "Variant Calling",
    isActive: true,
    requirements: [
        PackToolRequirement(
            id: "lofreq",
            displayName: "LoFreq",
            environment: "lofreq",
            installPackages: ["bioconda::lofreq=2.1.5"],
            executables: ["lofreq"],
            smokeTest: .command(arguments: ["--help"])
        ),
        PackToolRequirement(
            id: "ivar",
            displayName: "iVar",
            environment: "ivar",
            installPackages: ["bioconda::ivar=1.4.4"],
            executables: ["ivar"],
            smokeTest: .command(arguments: ["version"])
        ),
        PackToolRequirement(
            id: "medaka",
            displayName: "Medaka",
            environment: "medaka",
            installPackages: ["bioconda::medaka=2.1.1"],
            executables: ["medaka"],
            smokeTest: .command(arguments: ["--help"])
        ),
    ]
)
```

```swift
public enum NativeTool: String, CaseIterable, Sendable {
    case lofreq
    case ivar
    case medaka
}
```

- [ ] **Step 4: Update pack-order expectations across tests**

```swift
XCTAssertEqual(PluginPack.activeOptionalPacks.map(\.id), ["variant-calling", "assembly", "metagenomics"])
```

- [ ] **Step 5: Re-run the focused tests**

Run:

```bash
swift test --filter 'CondaManagerTests|PluginPackRegistryTests|NativeToolRunnerTests|PluginPackStatusServiceTests|PluginPackVisibilityTests|WelcomeSetupTests'
```

Expected: pack metadata and tool-resolution tests pass.

## Task 2: Add Viral SQLite Semantics And Bundle Attachment Services

**Files:**
- Modify: `Sources/LungfishIO/Bundles/VariantDatabase.swift`
- Create: `Sources/LungfishWorkflow/Variants/BundleVariantCallingModels.swift`
- Create: `Sources/LungfishWorkflow/Variants/BAMVariantCallingPreflight.swift`
- Create: `Sources/LungfishWorkflow/Variants/VariantSQLiteImportCoordinator.swift`
- Create: `Sources/LungfishWorkflow/Variants/BundleVariantTrackAttachmentService.swift`
- Test: `Tests/LungfishWorkflowTests/Variants/BAMVariantCallingPreflightTests.swift`
- Test: `Tests/LungfishWorkflowTests/Variants/BundleVariantTrackAttachmentServiceTests.swift`

- [ ] **Step 1: Write failing viral-import and attachment tests**

```swift
func testCreateFromVCFInViralModeDoesNotInventSyntheticSamples() throws {
    let count = try VariantDatabase.createFromVCF(
        vcfURL: viralVCF,
        outputURL: dbURL,
        importSemantics: .viralFrequency
    )
    XCTAssertEqual(count, 2)
    let db = try VariantDatabase(url: dbURL)
    XCTAssertEqual(db.sampleNames(), [])
}

func testCreateFromVCFInViralModeLeavesSampleCountZeroAndNoGenotypeRows() throws {
    try VariantDatabase.createFromVCF(
        vcfURL: viralVCF,
        outputURL: dbURL,
        importSemantics: .viralFrequency
    )
    let db = try VariantDatabase(url: dbURL)
    let variants = db.variants(in: "NC_045512.2", start: 0, end: 30_000)
    XCTAssertTrue(variants.allSatisfy { $0.sampleCount == 0 })
    XCTAssertEqual(db.sampleNames(chromosome: "NC_045512.2"), [])
}

func testAttachmentServicePersistsRealVcfgzPathsAndRollbackOnManifestFailure() async throws {
    let result = try await BundleVariantTrackAttachmentService().attach(
        request: request,
        simulateManifestFailure: true
    )
    XCTAssertThrowsError(try result.get())
    XCTAssertFalse(FileManager.default.fileExists(atPath: finalVCF.path))
}

func testPreflightRejectsBamReferenceLengthMismatch() async throws {
    await XCTAssertThrowsError(
        try await BAMVariantCallingPreflight().validate(request)
    )
}

func testPreflightAcceptsAliasMatchedContigs() async throws {
    let result = try await BAMVariantCallingPreflight().validate(aliasMatchedRequest)
    XCTAssertEqual(result.contigValidation, .matchedByAlias)
}

func testPreflightRejectsM5ChecksumMismatchWhenPresent() async throws {
    await XCTAssertThrowsError(
        try await BAMVariantCallingPreflight().validate(m5MismatchRequest)
    )
}

func testPreflightBlocksIVarWithoutPrimerTrimConfirmation() async throws {
    await XCTAssertThrowsError(
        try await BAMVariantCallingPreflight().validate(ivarUnconfirmedRequest)
    )
}

func testPreflightBlocksMedakaWithoutOntModelMetadata() async throws {
    await XCTAssertThrowsError(
        try await BAMVariantCallingPreflight().validate(medakaMissingMetadataRequest)
    )
}

func testImportCoordinatorReplaysResumeAndMaterializationStates() async throws {
    let coordinator = VariantSQLiteImportCoordinator(helperInvoker: stubInvoker)
    let result = try await coordinator.importNormalizedVCF(request)
    XCTAssertTrue(result.didResumeIndexBuild)
    XCTAssertTrue(result.didResumeMaterialization)
}
```

- [ ] **Step 2: Run the new workflow tests and watch them fail**

Run:

```bash
swift test --filter 'BAMVariantCallingPreflightTests|BundleVariantTrackAttachmentServiceTests'
```

Expected: compile failures because the new models/services and `importSemantics` do not exist.

- [ ] **Step 3: Add an explicit viral import mode to `VariantDatabase`**

```swift
public enum VCFImportSemantics: String, Sendable, Codable {
    case defaultSamples
    case viralFrequency
}

public static func createFromVCF(
    vcfURL: URL,
    outputURL: URL,
    parseGenotypes: Bool = true,
    sourceFile: String? = nil,
    importSemantics: VCFImportSemantics = .defaultSamples,
    ...
) throws -> Int
```

```swift
if fields.count > 9 {
    // existing sample behavior
} else if importSemantics == .viralFrequency {
    sampleNames = []
} else {
    // existing synthetic sample fallback
}
```

- [ ] **Step 4: Implement the shared models, preflight, and attachment services**

```swift
public struct BundleVariantCallingRequest: Sendable {
    public let bundleURL: URL
    public let alignmentTrackID: String
    public let caller: ViralVariantCaller
    public let outputTrackName: String
}

public enum ViralVariantCaller: String, CaseIterable, Sendable {
    case lofreq
    case ivar
    case medaka
}
```

```swift
public actor BundleVariantTrackAttachmentService {
    public func attach(request: AttachmentRequest) async throws -> AttachmentResult
}
```

The attachment service must:

- rename chromosomes against bundle aliases,
- write provenance metadata,
- promote staged `VCF.gz`, `.tbi`, and `.db`,
- create `VariantTrackInfo` using those real paths,
- save the manifest, and
- delete promoted files on manifest-save failure.

- [ ] **Step 5: Re-run the workflow tests**

Run:

```bash
swift test --filter 'BAMVariantCallingPreflightTests|BundleVariantTrackAttachmentServiceTests'
```

Expected: the new preflight and attachment tests pass, and the viral import tests prove there are no synthetic sample/genotype rows.

## Task 3: Add The CLI Variants Command Family

**Files:**
- Modify: `Sources/LungfishWorkflow/Extraction/BAMToFASTQConverter.swift`
- Create: `Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift`
- Create: `Sources/LungfishCLI/Commands/VariantsCommand.swift`
- Modify: `Sources/LungfishCLI/LungfishCLI.swift`
- Test: `Tests/LungfishCLITests/VariantsCommandTests.swift`
- Modify: `Tests/LungfishCLITests/CLIRegressionTests.swift`
- Test: `Tests/LungfishWorkflowTests/Variants/ViralVariantCallingPipelineTests.swift`

- [ ] **Step 1: Write failing CLI command tests**

```swift
func testIVarPipelineUsesNativeVcfOutputAndNoTsvTranslation() async throws {
    let plan = try await makePipeline(.ivar).buildExecutionPlan()
    XCTAssertTrue(plan.commandLine.contains("--output-format vcf"))
    XCTAssertFalse(plan.commandLine.contains(".tsv"))
}

func testAllCallersUseStagedUncompressedReference() async throws {
    for caller in ViralVariantCaller.allCases {
        let plan = try await makePipeline(caller).buildExecutionPlan()
        XCTAssertTrue(plan.referenceURL.path.hasSuffix(".fa"))
        XCTAssertFalse(plan.referenceURL.path.hasSuffix(".fa.gz"))
    }
}

func testMedakaPipelineUsesSharedBamToFastqConverterAndRejectsMissingMetadata() async throws {
    let pipeline = try makePipeline(.medaka, metadataMode: .missing)
    await XCTAssertThrowsError(try await pipeline.run())
}

func testVariantsCommandNameAndHelp() {
    XCTAssertEqual(VariantsCommand.configuration.commandName, "variants")
    XCTAssertTrue(VariantsCommand.helpMessage().contains("call"))
}

func testCallSubcommandParsesBundleAlignmentAndCaller() throws {
    let command = try VariantsCommand.CallSubcommand.parse([
        "call",
        "--bundle", "/tmp/Test.lungfishref",
        "--alignment-track", "aln-1",
        "--caller", "lofreq",
        "--format", "json",
    ])
    XCTAssertEqual(command.bundlePath, "/tmp/Test.lungfishref")
    XCTAssertEqual(command.alignmentTrackID, "aln-1")
    XCTAssertEqual(command.caller, "lofreq")
}

func testCallSubcommandEmitsRunCompleteJson() async throws {
    let output = try await runVariantsCommandFixture()
    XCTAssertTrue(output.contains(#""event":"runComplete""#))
}

func testCallSubcommandCancellationEmitsFailureAndCleansStaging() async throws {
    let output = try await runCancelledVariantsCommandFixture()
    XCTAssertTrue(output.contains(#""event":"runFailed""#))
    XCTAssertTrue(output.contains(#""message":"Variant calling cancelled""#))
    XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledStageURL.path))
}
```

- [ ] **Step 2: Run the CLI tests and watch them fail**

Run:

```bash
swift test --filter 'VariantsCommandTests|CLIRegressionTests'
```

Expected: failures because `VariantsCommand` does not exist and `LungfishCLI` does not register it.

- [ ] **Step 3: Implement `VariantsCommand` and internal helper subcommands**

```swift
struct VariantsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "variants",
        abstract: "Call viral variants from a bundle-owned alignment track",
        subcommands: [
            CallSubcommand.self,
            ImportHelperSubcommand.self,
            ResumeHelperSubcommand.self,
            MaterializeHelperSubcommand.self,
        ]
    )
}
```

```swift
struct CallSubcommand: AsyncParsableCommand {
    @Option(name: .customLong("bundle")) var bundlePath: String
    @Option(name: .customLong("alignment-track")) var alignmentTrackID: String
    @Option(name: .customLong("caller")) var caller: String
}
```

Pick the CLI-side helper route, not app-only helper flags. The call command should compose:

- `BAMVariantCallingPreflight`
- `ViralVariantCallingPipeline`
- `VariantSQLiteImportCoordinator`
- `BundleVariantTrackAttachmentService`

When implementing Medaka support, harden `BAMToFASTQConverter` so the Medaka path does not fall back to the lossy stdout-only reconstruction mode.

- [ ] **Step 3.1: Make coordinator resilience explicit**

The coordinator implementation must have direct tests or fixtures for:

- helper-driven initial import
- interrupted `import_state == indexing` resume
- interrupted `materialize_state == materializing` resume
- cancellation during import with staged-artifact cleanup
- forwarding child-helper failures back to the caller command

- [ ] **Step 4: Emit structured JSON events and map typed failures**

```swift
struct VariantCallingEvent: Codable {
    let event: String
    let progress: Double?
    let message: String
}
```

```swift
emit(.init(event: "preflightStart", progress: 0.02, message: "Checking bundle and alignment…"))
emit(.init(event: "runComplete", progress: 1.0, message: "Variant calling complete"))
```

- [ ] **Step 5: Re-run the CLI tests**

Run:

```bash
swift test --filter 'ViralVariantCallingPipelineTests|VariantsCommandTests|CLIRegressionTests'
```

Expected: the new CLI tests pass and regression help-text coverage includes the `variants` command family.

## Task 4: Add The App-Side CLI Runner And BAM Dialog State

**Files:**
- Create: `Sources/LungfishApp/Services/CLIVariantCallingRunner.swift`
- Create: `Sources/LungfishApp/Views/BAM/BAMVariantCallingCatalog.swift`
- Create: `Sources/LungfishApp/Views/BAM/BAMVariantCallingDialogState.swift`
- Create: `Sources/LungfishApp/Views/BAM/BAMVariantCallingDialog.swift`
- Create: `Sources/LungfishApp/Views/BAM/BAMVariantCallingToolPanes.swift`
- Create: `Sources/LungfishApp/Views/BAM/BAMVariantCallingDialogPresenter.swift`
- Test: `Tests/LungfishAppTests/CLIVariantCallingRunnerTests.swift`
- Test: `Tests/LungfishAppTests/BAMVariantCallingDialogRoutingTests.swift`

- [ ] **Step 1: Write failing app-dialog tests**

```swift
func testRunnerParsesRunCompleteEvent() throws {
    let event = try XCTUnwrap(CLIVariantCallingRunner.parseEvent(from: #"{"event":"runComplete","variantTrackID":"vc-1","message":"done"}"#))
    guard case let .runComplete(trackID, _, _, _, _) = event else { return XCTFail() }
    XCTAssertEqual(trackID, "vc-1")
}

@MainActor
func testDialogStateBlocksIVarUntilPrimerTrimAcknowledged() async {
    let state = BAMVariantCallingDialogState(bundle: bundleFixture)
    state.selectCaller(.ivar)
    XCTAssertFalse(state.isRunEnabled)
    state.ivarPrimerTrimConfirmed = true
    XCTAssertTrue(state.isRunEnabled)
}

@MainActor
func testCatalogDisablesAllToolsWhenVariantCallingPackIsMissing() async {
    let catalog = BAMVariantCallingCatalog(statusProvider: missingPackProvider)
    let items = await catalog.sidebarItems()
    XCTAssertTrue(items.allSatisfy { $0.availability != .available })
}

@MainActor
func testDialogStateAutoSuffixesDefaultTrackNameWhenCollisionExists() async {
    let state = BAMVariantCallingDialogState(bundle: bundleFixtureWithExistingLoFreqTrack)
    state.selectCaller(.lofreq)
    XCTAssertEqual(state.outputTrackName, "Sample 1 • LoFreq (2)")
}
```

- [ ] **Step 2: Run the new app tests and watch them fail**

Run:

```bash
swift test --filter 'CLIVariantCallingRunnerTests|BAMVariantCallingDialogRoutingTests'
```

Expected: failures because the runner, catalog, and dialog state do not exist.

- [ ] **Step 3: Implement the CLI runner and dialog state**

```swift
public enum CLIVariantCallingEvent: Sendable {
    case runStart(message: String)
    case preflightStart(message: String)
    case stageProgress(progress: Double, message: String)
    case runComplete(trackID: String, trackName: String, databasePath: String, vcfPath: String, tbiPath: String)
    case runFailed(message: String)
}
```

```swift
@Observable
@MainActor
final class BAMVariantCallingDialogState {
    var selectedAlignmentTrackID: String
    var selectedCaller: ViralVariantCaller
    var outputTrackName: String
    var ivarPrimerTrimConfirmed: Bool
    var readinessText: String
}
```

The dialog state must also own:

- `generatedTrackID` separate from the display name
- collision-aware default-name suffixing
- a guarantee that every launch request creates a new track id rather than replacing an existing track

- [ ] **Step 4: Build the SwiftUI dialog on `DatasetOperationsDialog`**

```swift
DatasetOperationsDialog(
    title: "CALL VARIANTS",
    subtitle: "Configure a viral variant caller for the selected alignment track.",
    datasetLabel: state.bundleLabel,
    tools: state.sidebarItems,
    selectedToolID: state.selectedCaller.rawValue,
    statusText: state.readinessText,
    isRunEnabled: state.isRunEnabled,
    onSelectTool: state.selectCaller(named:),
    onCancel: onCancel,
    onRun: onRun
) {
    BAMVariantCallingToolPanes(state: state)
}
```

- [ ] **Step 5: Re-run the app tests**

Run:

```bash
swift test --filter 'CLIVariantCallingRunnerTests|BAMVariantCallingDialogRoutingTests'
```

Expected: event parsing, pack gating, and readiness routing tests pass.

## Task 5: Wire Inspector Launch, OperationCenter, And Success Reload

**Files:**
- Modify: `Sources/LungfishApp/Services/DownloadCenter.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Modify: `Tests/LungfishAppTests/DownloadCenterTests.swift`
- Modify: `Tests/LungfishAppTests/PluginPackVisibilityTests.swift`
- Modify: `Tests/LungfishAppTests/WelcomeSetupTests.swift`
- Extend: `Tests/LungfishAppTests/BAMVariantCallingDialogRoutingTests.swift`

- [ ] **Step 1: Write failing integration-focused app tests**

```swift
func testAllOperationTypesExist() {
    let allTypes: [OperationType] = [
        .download, .bamImport, .vcfImport, .bundleBuild, .export,
        .assembly, .ingestion, .fastqOperation, .qualityReport,
        .taxonomyExtraction, .classification, .blastVerification,
        .variantCalling,
    ]
    XCTAssertEqual(allTypes.count, 13)
}

@MainActor
func testInspectorRegistersVariantCallingOperationAndReloadsBundleOnSuccess() async throws {
    let controller = makeInspectorController(bundle: bundleFixture)
    try await controller.test_runVariantCallingWorkflow(...)
    XCTAssertEqual(OperationCenter.shared.items.first?.operationType, .variantCalling)
}

@MainActor
func testInspectorCancellationRemovesStagingAndUnlocksBundle() async throws {
    let controller = makeInspectorController(bundle: bundleFixture)
    try await controller.test_cancelVariantCallingWorkflow()
    XCTAssertTrue(OperationCenter.shared.canStartOperation(on: bundleFixture.url))
    XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledStageURL.path))
}

@MainActor
func testSamplelessViralTrackRemainsViewableWithoutSampleRows() async throws {
    let controller = makeInspectorController(bundle: samplelessVariantBundleFixture)
    try controller.displaySamplelessVariantTrack()
    XCTAssertEqual(controller.viewModel.sampleSectionViewModel.sampleCount, 0)
}
```

- [ ] **Step 2: Run the focused app integration tests and watch them fail**

Run:

```bash
swift test --filter 'DownloadCenterTests|BAMVariantCallingDialogRoutingTests'
```

Expected: failures because there is no `.variantCalling` type and no inspector wiring.

- [ ] **Step 3: Add the new operation type and read-style callback**

```swift
public enum OperationType: String, Sendable {
    case variantCalling = "Variant Calling"
}
```

```swift
public var onCallVariantsRequested: (() -> Void)?
Button("Call Variants…") { viewModel.onCallVariantsRequested?() }
```

- [ ] **Step 4: Wire the inspector launch path**

```swift
viewModel.readStyleSectionViewModel.onCallVariantsRequested = { [weak self] in
    self?.runCallVariantsWorkflow()
}
```

`runCallVariantsWorkflow()` must:

- validate bundle/alignment presence,
- present `BAMVariantCallingDialogPresenter`,
- register `OperationCenter.shared.start(..., operationType: .variantCalling, targetBundleURL: bundleURL)`,
- set a cancel callback that stops the CLI runner,
- update progress from `CLIVariantCallingRunner`,
- call `displayBundle(at:)` on success.

It must also:

- preserve the manifest on cancellation/failure,
- surface cancellation as a non-destructive terminal state,
- and leave the bundle unlocked for the next run.

- [ ] **Step 5: Re-run the app integration tests**

Run:

```bash
swift test --filter 'DownloadCenterTests|BAMVariantCallingDialogRoutingTests|PluginPackVisibilityTests|WelcomeSetupTests'
```

Expected: operation typing, inspector launch, and optional-pack ordering tests pass.

## Task 6: Verification And Review Gates

**Files:**
- No new source files; verification only

- [ ] **Step 1: Run the focused new-test suites**

Run:

```bash
swift test --filter 'BAMVariantCallingPreflightTests|BundleVariantTrackAttachmentServiceTests|ViralVariantCallingPipelineTests|VariantsCommandTests|CLIVariantCallingRunnerTests|BAMVariantCallingDialogRoutingTests'
```

Expected: all new feature suites pass.

- [ ] **Step 2: Run the regression suites that this feature touches**

Run:

```bash
swift test --filter 'CondaManagerTests|PluginPackRegistryTests|NativeToolRunnerTests|PluginPackStatusServiceTests|DownloadCenterTests|CLIRegressionTests'
```

Expected: pack, tool, operation-center, and CLI regression coverage stays green.

- [ ] **Step 3: Build all tests**

Run:

```bash
swift build --build-tests
```

Expected: build succeeds.

- [ ] **Step 4: Run expert review gates before merge**

Required reviewers:

- architecture / error-handling review against the final implementation
- bioinformatics / data-integrity review against the final implementation

Artifacts to save:

- `docs/superpowers/reviews/2026-04-19-bam-variant-calling-dialog/implementation-review-architecture.md`
- `docs/superpowers/reviews/2026-04-19-bam-variant-calling-dialog/implementation-review-bioinformatics.md`

- [ ] **Step 5: Commit intentionally**

```bash
git add Sources/LungfishWorkflow Sources/LungfishIO Sources/LungfishCLI Sources/LungfishApp Tests docs/superpowers/specs/2026-04-19-bam-variant-calling-dialog-design.md docs/superpowers/plans/2026-04-19-bam-variant-calling-dialog.md docs/superpowers/reviews/2026-04-19-bam-variant-calling-dialog
git commit -m "feat: add BAM variant calling dialog and CLI workflow"
```
