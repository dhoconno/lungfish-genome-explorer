# Viral Recon Mapping Operations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add SARS-CoV-2 Viral Recon as a first-class FASTQ/FASTA Mapping operation, driven by Lungfish FASTQ and primer bundles, while removing the generic nf-core menu surface.

**Architecture:** Keep the user-facing feature specific to Viral Recon and hide nf-core as an implementation detail. Put reusable request, samplesheet, primer-staging, and bundle-writing code in `LungfishWorkflow`; route GUI execution through a new app service that invokes `lungfish-cli workflow run nf-core/viralrecon` and reports status through `OperationCenter`.

**Tech Stack:** Swift, SwiftUI, XCTest, ArgumentParser, existing Lungfish `.lungfishfastq`, `.lungfishprimers`, and `.lungfishrun` bundle APIs, nf-core/viralrecon 3.0.0 command parameters.

---

## Baseline

- Worktree: `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/viral-recon-mapping`
- Branch: `codex/viral-recon-mapping`
- Full `swift test` currently fails before feature work because `Tests/LungfishIntegrationTests/PrimerTrim/PrimerTrimGUIIntegrationTests.swift` imports `LungfishApp` but the `LungfishIntegrationTests` target in `Package.swift` does not depend on `LungfishApp`.
- Use targeted tests during implementation, then run `swift build` plus targeted test filters. Report the baseline full-suite failure separately.

## File Structure

Create:

- `Sources/LungfishWorkflow/ViralRecon/ViralReconRunRequest.swift`  
  Owns Viral Recon enums, request validation, generated parameter assembly, CLI argument construction, and conflict checks for advanced params.
- `Sources/LungfishWorkflow/ViralRecon/ViralReconSamplesheetBuilder.swift`  
  Writes nf-core/viralrecon Illumina and Nanopore samplesheets and stages ONT `fastq_pass` layout.
- `Sources/LungfishWorkflow/ViralRecon/ViralReconInputResolver.swift`  
  Converts selected `.lungfishfastq` bundles into `ViralReconSample` values, infers platform from metadata/header, and rejects mixed-platform selections.
- `Sources/LungfishWorkflow/ViralRecon/ViralReconPrimerStager.swift`  
  Resolves `.lungfishprimers` bundles against the selected reference, stages BED/FASTA files, and derives `primers.fasta` from BED plus reference when needed.
- `Sources/LungfishApp/Services/ViralReconWorkflowExecutionService.swift`  
  Creates `.lungfishrun` bundles under `Analyses/`, writes generated inputs, launches `lungfish-cli`, streams logs into `OperationCenter`, and reports completion/failure.
- `Sources/LungfishApp/Views/Mapping/ViralReconWizardSheet.swift`  
  Embedded SwiftUI pane used by FASTQ/FASTA Operations > Mapping for multi-bundle Viral Recon setup.
- `Tests/LungfishWorkflowTests/ViralRecon/ViralReconRunRequestTests.swift`
- `Tests/LungfishWorkflowTests/ViralRecon/ViralReconSamplesheetBuilderTests.swift`
- `Tests/LungfishWorkflowTests/ViralRecon/ViralReconInputResolverTests.swift`
- `Tests/LungfishWorkflowTests/ViralRecon/ViralReconPrimerStagerTests.swift`
- `Tests/LungfishAppTests/ViralReconWorkflowExecutionServiceTests.swift`
- `Tests/LungfishXCUITests/ViralReconXCUITests.swift`

Modify:

- `Sources/LungfishCLI/Commands/WorkflowCommand.swift`  
  Keep `workflow run nf-core/viralrecon` supported, write run bundles and command previews, and reject unsupported generic nf-core workflow names.
- `Sources/LungfishApp/Services/DownloadCenter.swift`  
  Add `OperationType.viralRecon`.
- `Sources/LungfishApp/App/AppDelegate.swift`  
  Remove generic nf-core dialog wiring and dispatch `pendingViralReconRequest` from FASTQ operations.
- `Sources/LungfishApp/App/MainMenu.swift`  
  Remove `Tools > nf-core Workflows...`.
- `Sources/LungfishApp/App/XCUIAccessibilityIdentifiers.swift`  
  Remove generic nf-core identifiers and add only Viral Recon identifiers used by the new pane/test.
- `Sources/LungfishApp/App/AboutAcknowledgements.swift`  
  Replace catalog-driven "Supported nf-core Workflows" with one `nf-core/viralrecon` acknowledgement.
- `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift`  
  Add `.viralRecon`, pending request storage, readiness text, and state capture.
- `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift`  
  Route `.viralRecon` to `ViralReconWizardSheet`.
- `Sources/LungfishApp/Views/FASTQ/FASTQOperationsCatalog.swift`  
  Keep Viral Recon in the existing Mapping category and keep Mapping gated by the read-mapping pack.
- `Tests/LungfishAppTests/FASTQOperationDialogRoutingTests.swift`
- `Tests/LungfishAppTests/FASTQOperationsCatalogTests.swift`
- `Tests/LungfishAppTests/AboutAcknowledgementsTests.swift`
- `Tests/LungfishAppTests/ImportCenterMenuTests.swift`
- `Tests/LungfishAppTests/GUIRegressionTests.swift` if this file exists in the worktree at implementation time.
- `Tests/LungfishCLITests/CLIRegressionTests.swift`
- `Tests/LungfishXCUITests/TestSupport/LungfishProjectFixtureBuilder.swift`
- `Tests/Fixtures/README.md`

Delete after replacement behavior is covered:

- `Sources/LungfishApp/Views/Workflow/NFCoreWorkflowDialogController.swift`
- `Sources/LungfishApp/Views/Workflow/NFCoreWorkflowDialogModel.swift`
- `Sources/LungfishApp/Services/NFCoreWorkflowExecutionService.swift`
- `Sources/LungfishApp/App/AppUITestNFCoreWorkflowProcessRunner.swift`
- `Sources/LungfishWorkflow/nf-core/NFCoreSupportedWorkflowCatalog.swift`
- `Tests/LungfishXCUITests/NFCoreWorkflowXCUITests.swift`
- `Tests/LungfishAppTests/NFCoreWorkflowDialogAppearanceTests.swift`
- `Tests/LungfishAppTests/NFCoreWorkflowDialogModelTests.swift`
- `Tests/LungfishAppTests/NFCoreWorkflowExecutionServiceTests.swift`
- `Tests/LungfishWorkflowTests/NFCoreSupportedWorkflowCatalogTests.swift`

Keep as internal infrastructure unless the implementation proves they are unused:

- `Sources/LungfishWorkflow/nf-core/NFCorePipeline.swift`
- `Sources/LungfishWorkflow/nf-core/NFCoreRegistry.swift`
- `Sources/LungfishWorkflow/nf-core/NFCoreRunBundleManifest.swift`
- `Sources/LungfishWorkflow/nf-core/NFCoreRunRequest.swift`

## Worker Rules

- Every implementation worker must use `superpowers:test-driven-development`.
- Every worker must work in `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/viral-recon-mapping`.
- Workers are not alone in the codebase. They must not revert edits made by other workers, and they must adapt their changes to whatever has landed in the worktree.
- Implementation workers must commit their task changes. Reviewer workers must not edit files.
- Use `apply_patch` for manual file edits.

---

### Task 1: Core Viral Recon Workflow Models

**Ownership:** `Sources/LungfishWorkflow/ViralRecon/*`, `Tests/LungfishWorkflowTests/ViralRecon/*`, and narrow imports needed for compilation.

**Files:**

- Create: `Sources/LungfishWorkflow/ViralRecon/ViralReconRunRequest.swift`
- Create: `Sources/LungfishWorkflow/ViralRecon/ViralReconSamplesheetBuilder.swift`
- Create: `Sources/LungfishWorkflow/ViralRecon/ViralReconInputResolver.swift`
- Create: `Sources/LungfishWorkflow/ViralRecon/ViralReconPrimerStager.swift`
- Test: `Tests/LungfishWorkflowTests/ViralRecon/ViralReconRunRequestTests.swift`
- Test: `Tests/LungfishWorkflowTests/ViralRecon/ViralReconSamplesheetBuilderTests.swift`
- Test: `Tests/LungfishWorkflowTests/ViralRecon/ViralReconInputResolverTests.swift`
- Test: `Tests/LungfishWorkflowTests/ViralRecon/ViralReconPrimerStagerTests.swift`
- Test helper: `Tests/LungfishWorkflowTests/ViralRecon/ViralReconWorkflowTestFixtures.swift`

- [ ] **Step 1: Write failing request and samplesheet tests**

Create tests that exercise the API below before adding production files:

```swift
func testIlluminaRequestBuildsViralReconCLIArgumentsWithGeneratedParameters() throws {
    let input = URL(fileURLWithPath: "/tmp/run/inputs/samplesheet.csv")
    let output = URL(fileURLWithPath: "/tmp/run/outputs")
    let request = try ViralReconRunRequest(
        samples: [
            ViralReconSample(
                sampleName: "SARS2_A",
                sourceBundleURL: URL(fileURLWithPath: "/tmp/A.lungfishfastq"),
                fastqURLs: [
                    URL(fileURLWithPath: "/tmp/A_R1.fastq.gz"),
                    URL(fileURLWithPath: "/tmp/A_R2.fastq.gz"),
                ],
                barcode: nil,
                sequencingSummaryURL: nil
            )
        ],
        platform: .illumina,
        protocol: .amplicon,
        samplesheetURL: input,
        outputDirectory: output,
        executor: .docker,
        version: "3.0.0",
        reference: .genome("MN908947.3"),
        primer: ViralReconPrimerSelection(
            bundleURL: URL(fileURLWithPath: "/tmp/QIASeqDIRECT-SARS2.lungfishprimers"),
            displayName: "QIASeq DIRECT SARS-CoV-2",
            bedURL: URL(fileURLWithPath: "/tmp/primers.bed"),
            fastaURL: URL(fileURLWithPath: "/tmp/primers.fasta"),
            leftSuffix: "_LEFT",
            rightSuffix: "_RIGHT",
            derivedFasta: true
        ),
        minimumMappedReads: 1000,
        variantCaller: .ivar,
        consensusCaller: .bcftools,
        skipOptions: [.assembly, .kraken2],
        advancedParams: ["max_cpus": "4", "max_memory": "8.GB"]
    )

    let args = request.cliArguments(bundlePath: URL(fileURLWithPath: "/tmp/run/viralrecon.lungfishrun"))

    XCTAssertEqual(args.prefix(3), ["workflow", "run", "nf-core/viralrecon"])
    XCTAssertTrue(args.contains("--version"))
    XCTAssertTrue(args.contains("3.0.0"))
    XCTAssertTrue(args.contains("--param"))
    XCTAssertTrue(args.contains("platform=illumina"))
    XCTAssertTrue(args.contains("protocol=amplicon"))
    XCTAssertTrue(args.contains("genome=MN908947.3"))
    XCTAssertTrue(args.contains("primer_bed=/tmp/primers.bed"))
    XCTAssertTrue(args.contains("primer_fasta=/tmp/primers.fasta"))
    XCTAssertTrue(args.contains("skip_assembly=true"))
    XCTAssertTrue(args.contains("skip_kraken2=true"))
}

func testAdvancedParamsRejectGeneratedKeys() {
    XCTAssertThrowsError(
        try ViralReconRunRequest.validateAdvancedParams(["input": "manual.csv"])
    ) { error in
        XCTAssertEqual(error as? ViralReconRunRequest.ValidationError, .conflictingAdvancedParam("input"))
    }
}

func testIlluminaSamplesheetWritesMultipleBundleRows() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    let samples = [
        ViralReconSample(sampleName: "A", sourceBundleURL: temp, fastqURLs: [temp.appendingPathComponent("A_R1.fastq.gz"), temp.appendingPathComponent("A_R2.fastq.gz")], barcode: nil, sequencingSummaryURL: nil),
        ViralReconSample(sampleName: "B", sourceBundleURL: temp, fastqURLs: [temp.appendingPathComponent("B.fastq.gz")], barcode: nil, sequencingSummaryURL: nil),
    ]

    let url = try ViralReconSamplesheetBuilder.writeIlluminaSamplesheet(samples: samples, in: temp)
    let csv = try String(contentsOf: url, encoding: .utf8)

    XCTAssertTrue(csv.contains("sample,fastq_1,fastq_2"))
    XCTAssertTrue(csv.contains("A,\(temp.path)/A_R1.fastq.gz,\(temp.path)/A_R2.fastq.gz"))
    XCTAssertTrue(csv.contains("B,\(temp.path)/B.fastq.gz,"))
}

func testNanoporeSamplesheetStagesFastqPassAndBarcodes() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let source = temp.appendingPathComponent("reads.fastq")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    try "@read\nACGT\n+\n!!!!\n".write(to: source, atomically: true, encoding: .utf8)
    let samples = [
        ViralReconSample(sampleName: "ONT_A", sourceBundleURL: temp, fastqURLs: [source], barcode: "01", sequencingSummaryURL: nil)
    ]

    let staged = try ViralReconSamplesheetBuilder.stageNanoporeInputs(samples: samples, in: temp)
    let csv = try String(contentsOf: staged.samplesheetURL, encoding: .utf8)

    XCTAssertTrue(csv.contains("sample,barcode"))
    XCTAssertTrue(csv.contains("ONT_A,01"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: staged.fastqPassDirectory.appendingPathComponent("barcode01/reads.fastq").path))
}
```

- [ ] **Step 2: Run tests to verify RED**

Run:

```bash
swift test --filter ViralReconRunRequestTests
swift test --filter ViralReconSamplesheetBuilderTests
```

Expected: both fail to compile because `ViralReconRunRequest`, `ViralReconSample`, and `ViralReconSamplesheetBuilder` do not exist.

- [ ] **Step 3: Implement request and samplesheet types**

Expose these exact public names and behavior:

```swift
public enum ViralReconPlatform: String, Codable, Sendable, Equatable, CaseIterable {
    case illumina
    case nanopore
}

public enum ViralReconProtocol: String, Codable, Sendable, Equatable {
    case amplicon
}

public enum ViralReconVariantCaller: String, Codable, Sendable, Equatable, CaseIterable {
    case ivar
    case bcftools
}

public enum ViralReconConsensusCaller: String, Codable, Sendable, Equatable, CaseIterable {
    case ivar
    case bcftools
}

public enum ViralReconSkipOption: String, Codable, Sendable, Equatable, CaseIterable {
    case assembly = "skip_assembly"
    case variants = "skip_variants"
    case consensus = "skip_consensus"
    case fastQC = "skip_fastqc"
    case kraken2 = "skip_kraken2"
    case fastp = "skip_fastp"
    case cutadapt = "skip_cutadapt"
    case ivarTrim = "skip_ivar_trim"
    case multiQC = "skip_multiqc"
}

public struct ViralReconSample: Codable, Sendable, Equatable {
    public let sampleName: String
    public let sourceBundleURL: URL
    public let fastqURLs: [URL]
    public let barcode: String?
    public let sequencingSummaryURL: URL?
}

public enum ViralReconReference: Codable, Sendable, Equatable {
    case genome(String)
    case local(fastaURL: URL, gffURL: URL?)
}

public struct ViralReconPrimerSelection: Codable, Sendable, Equatable {
    public let bundleURL: URL
    public let displayName: String
    public let bedURL: URL
    public let fastaURL: URL
    public let leftSuffix: String
    public let rightSuffix: String
    public let derivedFasta: Bool
}
```

`ViralReconRunRequest.effectiveParams` must include `input`, `outdir`, `platform`, `protocol`, reference params, primer params, `min_mapped_reads`, callers, skip flags, and sorted advanced params that do not conflict with generated keys. `cliArguments(bundlePath:prepareOnly:)` must build:

```swift
[
    "workflow", "run", "nf-core/viralrecon",
    "--executor", executor.rawValue,
    "--results-dir", outputDirectory.path,
    "--bundle-path", bundlePath.path,
    "--version", version,
    "--input", samplesheetURL.path,
    "--param", "key=value"
]
```

- [ ] **Step 4: Run request and samplesheet tests to verify GREEN**

Run:

```bash
swift test --filter ViralReconRunRequestTests
swift test --filter ViralReconSamplesheetBuilderTests
```

Expected: all Viral Recon request and samplesheet tests pass.

- [ ] **Step 5: Add failing resolver and primer-staging tests**

Write tests for these behaviors:

```swift
func testResolverRejectsMixedIlluminaAndNanoporeSelections() throws {
    let illumina = ViralReconResolvedInput(bundleURL: URL(fileURLWithPath: "/tmp/I.lungfishfastq"), sampleName: "I", fastqURLs: [URL(fileURLWithPath: "/tmp/I_R1.fastq.gz")], platform: .illumina, barcode: nil, sequencingSummaryURL: nil)
    let nanopore = ViralReconResolvedInput(bundleURL: URL(fileURLWithPath: "/tmp/N.lungfishfastq"), sampleName: "N", fastqURLs: [URL(fileURLWithPath: "/tmp/N.fastq")], platform: .nanopore, barcode: "01", sequencingSummaryURL: nil)

    XCTAssertThrowsError(try ViralReconInputResolver.makeSamples(from: [illumina, nanopore])) { error in
        XCTAssertEqual(error as? ViralReconInputResolver.ResolveError, .mixedPlatforms)
    }
}

func testPrimerStagerDerivesPrimerFastaWhenBundleHasOnlyBed() throws {
    let tempDirectory = try ViralReconWorkflowTestFixtures.makeTempDirectory()
    let fixtureReferenceFASTA = try ViralReconWorkflowTestFixtures.writeReferenceFASTA(in: tempDirectory)
    let fixturePrimerBundleWithoutFasta = try ViralReconWorkflowTestFixtures.writePrimerBundleWithoutFasta(in: tempDirectory)

    let staged = try ViralReconPrimerStager.stage(
        primerBundleURL: fixturePrimerBundleWithoutFasta,
        referenceFASTAURL: fixtureReferenceFASTA,
        referenceName: "MN908947.3",
        destinationDirectory: tempDirectory
    )

    XCTAssertTrue(staged.derivedFasta)
    XCTAssertTrue(FileManager.default.fileExists(atPath: staged.fastaURL.path))
    XCTAssertTrue(try String(contentsOf: staged.fastaURL, encoding: .utf8).contains(">"))
}
```

- [ ] **Step 6: Run resolver and primer tests to verify RED**

Run:

```bash
swift test --filter ViralReconInputResolverTests
swift test --filter ViralReconPrimerStagerTests
```

Expected: compile failures for `ViralReconInputResolver`, `ViralReconResolvedInput`, and `ViralReconPrimerStager`.

- [ ] **Step 7: Implement input resolver and primer stager**

`ViralReconInputResolver` must:

- Accept `.lungfishfastq` bundle URLs and direct FASTQ URLs.
- Use `FASTQBundle.resolveAllFASTQURLs(for:)`.
- Use `FASTQBundleCSVMetadata.load(from:)`, `FASTQSourceFileManifest.load(from:)`, and `LungfishIO.SequencingPlatform.detect(fromFASTQ:)` where available.
- Normalize Illumina to `.illumina` and ONT/Oxford Nanopore to `.nanopore`.
- Assign missing Nanopore barcodes as `"01"`, `"02"`, `"03"` in selected order.
- Throw `.mixedPlatforms` when resolved inputs contain both platforms.

`ViralReconPrimerStager` must:

- Load with `PrimerSchemeBundle.load(from:)`.
- Resolve BED with `PrimerSchemeResolver.resolve(bundle:targetReferenceName:)`.
- Copy BED into `destinationDirectory/primers/primers.bed`.
- Use bundled `primers.fasta` when present.
- Derive `destinationDirectory/primers/primers.fasta` from BED coordinates and reference FASTA when absent.
- Return `ViralReconPrimerSelection`.

The test helper must provide concrete fixture writers:

```swift
enum ViralReconWorkflowTestFixtures {
    static func makeTempDirectory() throws -> URL
    static func writeReferenceFASTA(in directory: URL) throws -> URL
    static func writePrimerBundleWithoutFasta(in directory: URL) throws -> URL
}
```

- [ ] **Step 8: Run all Task 1 tests**

Run:

```bash
swift test --filter ViralRecon
```

Expected: all new `LungfishWorkflowTests/ViralRecon` tests pass.

- [ ] **Step 9: Commit Task 1**

Run:

```bash
git add Sources/LungfishWorkflow/ViralRecon Tests/LungfishWorkflowTests/ViralRecon
git commit -m "feat: add viral recon workflow models"
```

---

### Task 2: CLI Run Bundle Support for Direct Viral Recon

**Ownership:** `Sources/LungfishCLI/Commands/WorkflowCommand.swift`, `Tests/LungfishCLITests/CLIRegressionTests.swift`, and internal nf-core request/bundle files if needed.

**Files:**

- Modify: `Sources/LungfishCLI/Commands/WorkflowCommand.swift`
- Modify: `Tests/LungfishCLITests/CLIRegressionTests.swift`
- Modify if required: `Sources/LungfishWorkflow/nf-core/NFCoreRunBundleManifest.swift`
- Modify if required: `Sources/LungfishWorkflow/nf-core/NFCoreRunRequest.swift`

- [ ] **Step 1: Write failing CLI regression tests**

Add:

```swift
func testRunSubcommandAllowsOnlyViralReconNFCoreWorkflow() throws {
    let command = try RunSubcommand.parse([
        "nf-core/viralrecon",
        "--executor", "docker",
        "--input", "/tmp/samplesheet.csv",
        "--results-dir", "/tmp/results",
        "--bundle-path", "/tmp/viralrecon.lungfishrun",
        "--version", "3.0.0",
        "--param", "platform=illumina",
        "--prepare-only",
    ])

    XCTAssertEqual(command.workflow, "nf-core/viralrecon")
    XCTAssertEqual(command.input, ["/tmp/samplesheet.csv"])
    XCTAssertEqual(command.version, "3.0.0")
    XCTAssertTrue(command.prepareOnly)
}

func testUnsupportedNFCoreWorkflowIsRejected() throws {
    let command = try RunSubcommand.parse([
        "nf-core/fetchngs",
        "--input", "/tmp/accessions.csv",
        "--prepare-only",
    ])

    XCTAssertThrowsError(try command.validateViralReconWorkflowName())
}
```

- [ ] **Step 2: Run CLI tests to verify RED**

Run:

```bash
swift test --filter WorkflowCommandRegressionTests
```

Expected: failure for missing `validateViralReconWorkflowName()` or unsupported workflow still being accepted through the generic catalog.

- [ ] **Step 3: Implement direct viralrecon CLI path**

Change `RunSubcommand.runNFCoreWorkflow` so it:

- Accepts only `nf-core/viralrecon` and `viralrecon`.
- Creates a `ViralReconRunRequest` or a direct `NFCoreRunRequest` descriptor whose workflow name is `viralrecon`, display name is `nf-core/viralrecon`, pinned version is `3.0.0`, and result surfaces include reports/custom outputs.
- Requires `--input` to point at the generated samplesheet path.
- Writes `.lungfishrun/manifest.json`, `logs/`, `reports/`, `outputs/`, and a command preview.
- Honors `--prepare-only` without launching Nextflow.
- Passes Nextflow args equivalent to:

```bash
nextflow run nf-core/viralrecon -r 3.0.0 -profile docker --input /path/samplesheet.csv --outdir /path/results --platform illumina --protocol amplicon
```

- [ ] **Step 4: Run CLI tests to verify GREEN**

Run:

```bash
swift test --filter WorkflowCommandRegressionTests
swift test --filter NFCoreRunBundleManifestTests
```

Expected: tests pass with direct Viral Recon support and unsupported generic nf-core names rejected.

- [ ] **Step 5: Commit Task 2**

Run:

```bash
git add Sources/LungfishCLI/Commands/WorkflowCommand.swift Tests/LungfishCLITests/CLIRegressionTests.swift Sources/LungfishWorkflow/nf-core
git commit -m "feat: route cli viral recon runs"
```

---

### Task 3: App Execution Service and Operations Panel Logging

**Ownership:** `Sources/LungfishApp/Services/ViralReconWorkflowExecutionService.swift`, `Sources/LungfishApp/Services/DownloadCenter.swift`, deterministic Viral Recon runner code, and `Tests/LungfishAppTests/ViralReconWorkflowExecutionServiceTests.swift`.

**Files:**

- Create: `Sources/LungfishApp/Services/ViralReconWorkflowExecutionService.swift`
- Modify: `Sources/LungfishApp/Services/DownloadCenter.swift`
- Test: `Tests/LungfishAppTests/ViralReconWorkflowExecutionServiceTests.swift`
- Test helper: `Tests/LungfishAppTests/Support/ViralReconAppTestFixtures.swift`

- [ ] **Step 1: Write failing service tests**

Add tests:

```swift
@MainActor
func testServiceCreatesRunBundleAndLogsPreparation() async throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let request = try ViralReconAppTestFixtures.illuminaRequest(root: temp)
    let operationCenter = OperationCenter()
    let runner = StubViralReconProcessRunner(result: .init(exitCode: 0, standardOutput: "nextflow progress", standardError: ""))
    let service = ViralReconWorkflowExecutionService(operationCenter: operationCenter, processRunner: runner)

    let result = try await service.run(request, bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true))

    XCTAssertTrue(result.bundleURL.pathExtension == "lungfishrun")
    let item = try XCTUnwrap(operationCenter.items.first { $0.id == result.operationID })
    XCTAssertEqual(item.operationType, .viralRecon)
    XCTAssertEqual(item.title, "Viral Recon")
    XCTAssertTrue(item.logEntries.map(\.message).contains { $0.contains("samplesheet") })
    XCTAssertTrue(item.logEntries.map(\.message).contains { $0.contains("lungfish-cli workflow run nf-core/viralrecon") })
    XCTAssertEqual(item.state, .completed)
}

@MainActor
func testServiceFailsWithExitCodeAndStderrTail() async throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let request = try ViralReconAppTestFixtures.illuminaRequest(root: temp)
    let operationCenter = OperationCenter()
    let runner = StubViralReconProcessRunner(result: .init(exitCode: 2, standardOutput: "", standardError: "bad params"))
    let service = ViralReconWorkflowExecutionService(operationCenter: operationCenter, processRunner: runner)

    do {
        _ = try await service.run(request, bundleRoot: temp.appendingPathComponent("Analyses", isDirectory: true))
        XCTFail("Expected Viral Recon service to throw for a non-zero CLI exit")
    } catch {
        XCTAssertEqual(error as? ViralReconWorkflowExecutionError, .nonZeroExit(2))
    }

    let item = try XCTUnwrap(operationCenter.items.first)
    XCTAssertEqual(item.state, .failed)
    XCTAssertEqual(item.errorMessage, "Viral Recon failed")
    XCTAssertTrue(item.errorDetail?.contains("bad params") == true)
}
```

- [ ] **Step 2: Run service tests to verify RED**

Run:

```bash
swift test --filter ViralReconWorkflowExecutionServiceTests
```

Expected: compile failure for missing service, runner, process result, and `OperationType.viralRecon`.

- [ ] **Step 3: Implement execution service**

Implement:

```swift
@MainActor
final class ViralReconWorkflowExecutionService {
    struct RunResult {
        let operationID: UUID
        let bundleURL: URL
        let operationItem: OperationCenter.Item?
    }

    func run(_ request: ViralReconRunRequest, bundleRoot: URL) async throws -> RunResult
}

struct ViralReconWorkflowProcessResult: Sendable, Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

@MainActor
protocol ViralReconWorkflowProcessRunning {
    func runLungfishCLI(arguments: [String], workingDirectory: URL) async throws -> ViralReconWorkflowProcessResult
}
```

Service behavior:

- Allocate `viralrecon.lungfishrun`, `viralrecon-2.lungfishrun`, etc.
- Write manifest and generated input paths into the bundle.
- Start `OperationCenter` item:

```swift
operationCenter.start(
    title: "Viral Recon",
    detail: "\(request.platform.rawValue) · \(request.samples.count) sample(s)",
    operationType: .viralRecon,
    targetBundleURL: bundleURL,
    cliCommand: request.cliCommandPreview(bundlePath: bundleURL, executableName: "lungfish-cli")
)
```

- Log samplesheet, primer scheme, derived primer FASTA, and command preview.
- Invoke `lungfish-cli` with `request.cliArguments(bundlePath:)`.
- Write stdout/stderr to `.lungfishrun/logs/stdout.log` and `.lungfishrun/logs/stderr.log`.
- Complete with bundle URL on exit code 0.
- Fail with error message `Viral Recon failed` and stderr tail on non-zero exit.

`ViralReconAppTestFixtures` must create real temporary `samplesheet.csv`, primer BED/FASTA paths, output directory, and a valid `ViralReconRunRequest`. Keep it in the app test support folder so Task 4 can reuse it.

- [ ] **Step 4: Run service tests to verify GREEN**

Run:

```bash
swift test --filter ViralReconWorkflowExecutionServiceTests
```

Expected: service tests pass.

- [ ] **Step 5: Commit Task 3**

Run:

```bash
git add Sources/LungfishApp/Services/ViralReconWorkflowExecutionService.swift Sources/LungfishApp/Services/DownloadCenter.swift Tests/LungfishAppTests/ViralReconWorkflowExecutionServiceTests.swift
git commit -m "feat: run viral recon through operations panel"
```

---

### Task 4: FASTQ/FASTA Mapping UI Integration

**Ownership:** FASTQ operation state/panes, `ViralReconWizardSheet`, app dispatch, and routing tests.

**Files:**

- Create: `Sources/LungfishApp/Views/Mapping/ViralReconWizardSheet.swift`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationsCatalog.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Modify: `Sources/LungfishApp/App/XCUIAccessibilityIdentifiers.swift`
- Test: `Tests/LungfishAppTests/FASTQOperationDialogRoutingTests.swift`
- Test: `Tests/LungfishAppTests/FASTQOperationsCatalogTests.swift`

- [ ] **Step 1: Write failing routing tests**

Add:

```swift
func testViralReconAppearsInMappingTools() {
    let mappingTools = FASTQOperationDialogState.toolIDs(for: .mapping)

    XCTAssertTrue(mappingTools.contains(.viralRecon))
    XCTAssertEqual(FASTQOperationToolID.viralRecon.categoryID, .mapping)
    XCTAssertEqual(FASTQOperationToolID.viralRecon.title, "Viral Recon")
    XCTAssertEqual(FASTQOperationToolID.viralRecon.subtitle, "Run SARS-CoV-2 viral consensus and variant analysis.")
    XCTAssertTrue(FASTQOperationToolID.viralRecon.usesEmbeddedConfiguration)
    XCTAssertEqual(FASTQOperationToolID.viralRecon.embeddedReadinessText, "Complete the viral recon settings to continue.")
}

func testViralReconPendingRequestControlsRunReadiness() throws {
    let state = FASTQOperationDialogState(
        initialCategory: .mapping,
        selectedInputURLs: [URL(fileURLWithPath: "/tmp/A.lungfishfastq")]
    )
    state.selectTool(.viralRecon)

    XCTAssertFalse(state.isRunEnabled)
    state.captureViralReconRequest(try ViralReconAppTestFixtures.illuminaRequest(root: URL(fileURLWithPath: "/tmp")))

    XCTAssertTrue(state.isRunEnabled)
    XCTAssertNotNil(state.pendingViralReconRequest)
}
```

- [ ] **Step 2: Run routing tests to verify RED**

Run:

```bash
swift test --filter FASTQOperationDialogRoutingTests/testViralRecon
swift test --filter FASTQOperationsCatalogTests
```

Expected: compile failure because `.viralRecon` and `pendingViralReconRequest` do not exist.

- [ ] **Step 3: Add state and catalog routing**

Modify `FASTQOperationToolID`:

```swift
case viralRecon
```

Return:

- title: `Viral Recon`
- subtitle: `Run SARS-CoV-2 viral consensus and variant analysis.`
- category: `.mapping`
- required inputs: `[.fastqDataset]`
- uses embedded configuration: `true`
- default embedded readiness: `false`
- readiness text: `Complete the viral recon settings to continue.`

Modify `FASTQOperationDialogState`:

```swift
var pendingViralReconRequest: ViralReconRunRequest?

func captureViralReconRequest(_ request: ViralReconRunRequest) {
    pendingLaunchRequest = nil
    pendingMinimap2Config = nil
    pendingMappingRequest = nil
    pendingAssemblyRequest = nil
    pendingClassificationConfigs = []
    pendingEsVirituConfigs = []
    pendingTaxTriageConfig = nil
    pendingViralReconRequest = request
    updateEmbeddedReadiness(true, for: .viralRecon)
}
```

Ensure `prepareForRun()` clears `pendingViralReconRequest` before triggering embedded panes, and ensure `isRunEnabled` is true for `.viralRecon` only when `pendingViralReconRequest != nil` or embedded readiness is true according to the existing embedded-tool pattern.

- [ ] **Step 4: Create the embedded Viral Recon pane**

`ViralReconWizardSheet` must:

- Accept:

```swift
struct ViralReconWizardSheet: View {
    let inputFiles: [URL]
    let projectURL: URL?
    let embeddedInOperationsDialog: Bool
    let embeddedRunTrigger: Int
    let onRun: (ViralReconRunRequest) -> Void
    let onRunnerAvailabilityChange: (Bool) -> Void
}
```

- Show selected bundles, platform picker/override, primer scheme picker from `BuiltInPrimerSchemeService.listBuiltInSchemes()` plus `PrimerSchemesFolder.listBundles(in:)`, reference controls, executor, version, minimum mapped reads, callers, and skip toggles.
- Support multiple selected bundles as one request.
- Never show a generic "nf-core" category label.
- On `embeddedRunTrigger` change, build and send a `ViralReconRunRequest` through `onRun`.
- Call `onRunnerAvailabilityChange(true)` only when selected bundles, single platform, primer scheme, reference, and output directory are valid.

- [ ] **Step 5: Wire pane and AppDelegate dispatch**

In `FASTQOperationToolPanes`, route:

```swift
case .viralRecon:
    ViralReconWizardSheet(
        inputFiles: state.selectedInputURLs,
        projectURL: state.projectURL,
        embeddedInOperationsDialog: true,
        embeddedRunTrigger: state.embeddedRunTrigger,
        onRun: state.captureViralReconRequest(_:),
        onRunnerAvailabilityChange: readinessHandler(for: state.selectedToolID)
    )
```

In `AppDelegate.showFASTQOperationsDialog`, dispatch before mapping/minimap2:

```swift
if let request = state.pendingViralReconRequest {
    let service: ViralReconWorkflowExecutionService
    if AppUITestConfiguration.current.isEnabled,
       AppUITestConfiguration.current.backendMode == .deterministic {
        service = ViralReconWorkflowExecutionService(processRunner: AppUITestViralReconWorkflowProcessRunner())
    } else {
        service = ViralReconWorkflowExecutionService()
    }
    Task { try await service.run(request, bundleRoot: request.outputDirectory.deletingLastPathComponent()) }
    return
}
```

Use the actual project `Analyses/` path rather than a temp parent when `projectURL` is available.

- [ ] **Step 6: Run routing tests to verify GREEN**

Run:

```bash
swift test --filter FASTQOperationDialogRoutingTests/testViralRecon
swift test --filter FASTQOperationsCatalogTests
```

Expected: routing and catalog tests pass.

- [ ] **Step 7: Commit Task 4**

Run:

```bash
git add Sources/LungfishApp/Views/Mapping/ViralReconWizardSheet.swift Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift Sources/LungfishApp/Views/FASTQ/FASTQOperationsCatalog.swift Sources/LungfishApp/App/AppDelegate.swift Sources/LungfishApp/App/XCUIAccessibilityIdentifiers.swift Tests/LungfishAppTests/FASTQOperationDialogRoutingTests.swift Tests/LungfishAppTests/FASTQOperationsCatalogTests.swift
git commit -m "feat: add viral recon mapping operation"
```

---

### Task 5: Remove Generic nf-core Menu and UI Surface

**Ownership:** generic nf-core menu/dialog/model/service/test removal plus acknowledgements.

**Files:**

- Delete: `Sources/LungfishApp/Views/Workflow/NFCoreWorkflowDialogController.swift`
- Delete: `Sources/LungfishApp/Views/Workflow/NFCoreWorkflowDialogModel.swift`
- Delete: `Sources/LungfishApp/Services/NFCoreWorkflowExecutionService.swift`
- Delete: `Sources/LungfishApp/App/AppUITestNFCoreWorkflowProcessRunner.swift`
- Delete: `Sources/LungfishWorkflow/nf-core/NFCoreSupportedWorkflowCatalog.swift`
- Delete: `Tests/LungfishXCUITests/NFCoreWorkflowXCUITests.swift`
- Delete: `Tests/LungfishAppTests/NFCoreWorkflowDialogAppearanceTests.swift`
- Delete: `Tests/LungfishAppTests/NFCoreWorkflowDialogModelTests.swift`
- Delete: `Tests/LungfishAppTests/NFCoreWorkflowExecutionServiceTests.swift`
- Delete: `Tests/LungfishWorkflowTests/NFCoreSupportedWorkflowCatalogTests.swift`
- Modify: `Sources/LungfishApp/App/MainMenu.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Modify: `Sources/LungfishApp/App/XCUIAccessibilityIdentifiers.swift`
- Modify: `Sources/LungfishApp/App/AboutAcknowledgements.swift`
- Modify: `Tests/LungfishAppTests/AboutAcknowledgementsTests.swift`
- Modify: `Tests/LungfishAppTests/ImportCenterMenuTests.swift`
- Modify: `Tests/LungfishCLITests/CLIRegressionTests.swift`

- [ ] **Step 1: Write failing removal tests**

Add/adjust tests:

```swift
func testToolsMenuDoesNotExposeGenericNFCoreWorkflowsItem() {
    let menu = MainMenu.createMainMenu()
    let allTitles = collectMenuItemTitles(menu)

    XCTAssertFalse(allTitles.contains("nf-core Workflows…"))
    XCTAssertTrue(allTitles.contains("FASTQ/FASTA Operations"))
    XCTAssertTrue(allTitles.contains("Mapping…"))
}

private func collectMenuItemTitles(_ menu: NSMenu) -> [String] {
    menu.items.flatMap { item -> [String] in
        let ownTitle = item.title.isEmpty ? [] : [item.title]
        guard let submenu = item.submenu else { return ownTitle }
        return ownTitle + collectMenuItemTitles(submenu)
    }
}

func testAboutAcknowledgementsCreditViralReconWithoutGenericCatalogSection() {
    let sections = AboutAcknowledgements.currentSections(bundledManifest: nil, activeOptionalPacks: [])

    XCTAssertFalse(sections.contains { $0.title == "Supported nf-core Workflows" })
    XCTAssertTrue(sections.flatMap(\.entries).contains { $0.id == "nf-core-viralrecon" && $0.displayName == "nf-core/viralrecon" })
}
```

- [ ] **Step 2: Run tests to verify RED**

Run:

```bash
swift test --filter ImportCenterMenuTests
swift test --filter AboutAcknowledgementsTests
```

Expected: at least one assertion fails because the menu and acknowledgement still expose generic nf-core workflows.

- [ ] **Step 3: Remove menu action and dialog ownership**

Remove from `MainMenu.swift`:

```swift
let nfCoreItem = toolsMenu.addItem(
    withTitle: "nf-core Workflows…",
    action: #selector(ToolsMenuActions.showNFCoreWorkflows(_:)),
    keyEquivalent: ""
)
```

Remove from `AppDelegate.swift`:

```swift
private var nfCoreWorkflowDialogController: NFCoreWorkflowDialogController?

@objc func showNFCoreWorkflows(_ sender: Any?) { ... }
```

Remove `ToolsMenuActions.showNFCoreWorkflows(_:)` declarations and generic nf-core accessibility constants.

- [ ] **Step 4: Replace acknowledgements**

Replace catalog-driven section with:

```swift
let viralReconEntry = Entry(
    id: "nf-core-viralrecon",
    displayName: "nf-core/viralrecon",
    detail: "Pinned 3.0.0",
    secondaryDetail: "SARS-CoV-2 viral consensus and variant analysis workflow",
    sourceURL: "https://nf-co.re/viralrecon"
)
sections.append(Section(title: "Workflow Credits", entries: [viralReconEntry]))
```

- [ ] **Step 5: Delete generic nf-core files and tests**

Delete the files listed in this task. Keep internal bundle infrastructure when still referenced by the CLI or Viral Recon request code.

- [ ] **Step 6: Run removal tests to verify GREEN**

Run:

```bash
swift test --filter ImportCenterMenuTests
swift test --filter AboutAcknowledgementsTests
swift test --filter WorkflowCommandRegressionTests
```

Expected: no generic nf-core UI tests remain, and the updated menu/acknowledgement/CLI tests pass.

- [ ] **Step 7: Commit Task 5**

Run:

```bash
git add -A Sources/LungfishApp Sources/LungfishWorkflow Tests/LungfishAppTests Tests/LungfishWorkflowTests Tests/LungfishXCUITests Tests/LungfishCLITests
git commit -m "refactor: remove generic nf-core app surface"
```

---

### Task 6: Fixtures and Deterministic UI Coverage

**Ownership:** XCUITest fixture builder, fixture docs, deterministic runner, and XCUITest.

**Files:**

- Modify: `Tests/LungfishXCUITests/TestSupport/LungfishProjectFixtureBuilder.swift`
- Modify: `Tests/LungfishXCUITests/TestSupport/LungfishFixtureCatalog.swift`
- Create: `Tests/LungfishXCUITests/ViralReconXCUITests.swift`
- Modify: `Tests/Fixtures/README.md`
- Add fixture directory if needed: `Tests/Fixtures/viralrecon-ont/*`

- [ ] **Step 1: Add fixture test for multi-bundle projects**

Add a unit or XCUITest support test that verifies:

```swift
let projectURL = try LungfishProjectFixtureBuilder.makeViralReconProject(named: "ViralReconFixture")
let fastqBundles = try FileManager.default.contentsOfDirectory(at: projectURL, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "lungfishfastq" }
let primerFolder = projectURL.appendingPathComponent("Primer Schemes", isDirectory: true)

XCTAssertGreaterThanOrEqual(fastqBundles.count, 2)
XCTAssertTrue(FileManager.default.fileExists(atPath: primerFolder.path))
```

- [ ] **Step 2: Run fixture test to verify RED**

Run:

```bash
swift test --filter ViralReconFixture
```

Expected: compile failure or test failure because the fixture builder method does not exist.

- [ ] **Step 3: Implement real fixture project builder**

Add `makeViralReconProject(named:)` that:

- Creates a `.lungfish` project.
- Includes at least two SARS-CoV-2 Illumina `.lungfishfastq` bundles from `Tests/Fixtures/sarscov2/test_1.fastq.gz` and `test_2.fastq.gz`.
- Includes an ONT fixture bundle from a small public SARS-CoV-2 Nanopore test read file, or a minimal FASTQ copied from a documented nf-core/test-datasets source.
- Copies `QIASeqDIRECT-SARS2.lungfishprimers` or `mt192765-integration.lungfishprimers` into `Primer Schemes/`.
- Writes `Tests/Fixtures/README.md` provenance for any new vendored ONT fixture.

- [ ] **Step 4: Add deterministic XCUITest**

Create an XCUITest that:

```swift
func testViralReconRunsDeterministicWorkflowIntoOperationsPanel() throws {
    let projectURL = try LungfishProjectFixtureBuilder.makeViralReconProject(named: "ViralReconWorkflowFixture")
    let app = XCUIApplication()
    app.launchEnvironment["LUNGFISH_UI_TEST_PROJECT"] = projectURL.path
    app.launchEnvironment["LUNGFISH_UI_TEST_BACKEND"] = "deterministic"
    app.launch()

    app.menuBars.menuBarItems["Tools"].click()
    app.menuItems["FASTQ/FASTA Operations"].click()
    app.menuItems["Mapping…"].click()

    XCTAssertTrue(app.staticTexts["Viral Recon"].waitForExistence(timeout: 5))
    app.buttons["viral-recon-run"].click()

    XCTAssertTrue(app.staticTexts["Viral Recon"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.menuItems["nf-core Workflows…"].exists)
}
```

Use the actual accessibility identifiers implemented in Task 4. The deterministic runner must append an event containing:

```text
viralrecon.cli.invoked workflow run nf-core/viralrecon
```

- [ ] **Step 5: Run deterministic coverage**

Run:

```bash
swift test --filter ViralRecon
```

If XCUITest is run through xcodebuild in this repo, run the same command pattern used by existing XCUITest docs/scripts and record the command in the final verification notes.

Expected: unit tests pass; XCUITest compiles and deterministic backend produces a `.lungfishrun` operation without launching Nextflow.

- [ ] **Step 6: Commit Task 6**

Run:

```bash
git add Tests/LungfishXCUITests Tests/Fixtures Sources/LungfishApp
git commit -m "test: cover viral recon deterministic workflow"
```

---

### Task 7: Integration Verification

**Ownership:** final build/test cleanup only. Do not add feature scope in this task.

**Files:** As required by compile/test failures caused by Tasks 1-6.

- [ ] **Step 1: Run focused verification**

Run:

```bash
swift test --filter ViralRecon
swift test --filter FASTQOperationDialogRoutingTests
swift test --filter FASTQOperationsCatalogTests
swift test --filter AboutAcknowledgementsTests
swift test --filter ImportCenterMenuTests
swift test --filter WorkflowCommandRegressionTests
swift build
```

Expected: all listed commands pass.

- [ ] **Step 2: Run full suite and capture known baseline failure**

Run:

```bash
swift test
```

Expected: if it still fails at `LungfishIntegrationTests` with `no such module 'LungfishApp'`, record that as the existing baseline target-dependency issue. Any new Viral Recon, nf-core-removal, CLI, or app compile failure must be fixed before continuing.

- [ ] **Step 3: Search for removed generic nf-core surface**

Run:

```bash
rg -n "nf-core Workflows|showNFCoreWorkflows|NFCoreWorkflowDialog|fetchngs|NFCoreSupportedWorkflowCatalog" Sources Tests
```

Expected: no matches except acceptable historical docs or internal comments that do not create user-facing generic nf-core functionality.

- [ ] **Step 4: Commit verification fixes**

If fixes were required:

```bash
git add -A
git commit -m "fix: stabilize viral recon integration"
```

If no fixes were required, do not create an empty commit.
