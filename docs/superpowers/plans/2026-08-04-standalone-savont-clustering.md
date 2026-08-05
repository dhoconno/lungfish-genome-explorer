# Standalone Savont Clustering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a standalone Savont FASTQ clustering command and FASTQ Operations tool that publishes one counted-cluster FASTA with complete provenance per selected input.

**Architecture:** Introduce a focused `LungfishWorkflow` Savont request, strict FASTA normalizer, process runner, and atomic publisher. The CLI owns one-input execution; the GUI fans multiple inputs into independent CLI plans and reuses the existing per-input operation infrastructure. Generic retry classification is extracted from the MHC-specific helper without changing MHC behavior.

**Tech Stack:** Swift 6, Swift Argument Parser, SwiftUI/AppKit FASTQ Operations, Lungfish managed conda runtime, canonical Lungfish provenance, XCTest/Swift Testing.

---

## File structure

- `Sources/LungfishWorkflow/Savont/SavontClusteringRunRequest.swift`: typed defaults, option validation, output/input identity.
- `Sources/LungfishWorkflow/Savont/SavontClusterFASTA.swift`: strict Savont FASTA parsing, count normalization, summary calculation.
- `Sources/LungfishWorkflow/Savont/SavontRetryPolicy.swift`: shared crash and low-SNPmer retry decisions.
- `Sources/LungfishWorkflow/Savont/SavontClusteringPipeline.swift`: managed Savont attempts, cancellation-safe scratch use, final publication, and canonical provenance.
- `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCSavontRunSupport.swift`: delegate retry classification to the shared policy while retaining MHC-specific paths/materialization.
- `Sources/LungfishCLI/Commands/FastqSavontClusterSubcommand.swift`: `fastq savont-cluster` command and JSON result payload.
- `Sources/LungfishCLI/Commands/FastqCommand.swift`: register the subcommand.
- `Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift`: register the scientific writer.
- `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift`: tool identity, state defaults, validation, and launch request.
- `Sources/LungfishApp/Services/FASTQSavontClusteringRequest.swift`: lightweight GUI batch request that retains all selected inputs and creates one CLI plan per input.
- `Sources/LungfishApp/Services/WorkflowLibrary.swift`: declare the existing full-length MHC/Savont managed pack as the tool prerequisite.
- `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift`: simple Savont controls and Advanced Options.
- `Sources/LungfishApp/Services/FASTQOperationPlanner.swift`: one output FASTA per input and result discovery.
- `Sources/LungfishApp/Services/FASTQOperationCLIInvocationBuilder.swift`: exact CLI construction.
- `Sources/LungfishApp/Services/FASTQOperationOutputImporter.swift`: return final FASTA while retaining its hidden sidecar.
- `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`: operation title/routing coverage for the new launch request.
- Focused workflow, CLI, and app tests named below.

### Task 1: Typed request, counted FASTA, and shared retry policy

**Files:**
- Create: `Sources/LungfishWorkflow/Savont/SavontClusteringRunRequest.swift`
- Create: `Sources/LungfishWorkflow/Savont/SavontClusterFASTA.swift`
- Create: `Sources/LungfishWorkflow/Savont/SavontRetryPolicy.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCSavontRunSupport.swift`
- Create: `Tests/LungfishWorkflowTests/SavontClusteringRunRequestTests.swift`
- Create: `Tests/LungfishWorkflowTests/SavontClusterFASTANormalizerTests.swift`
- Create: `Tests/LungfishWorkflowTests/SavontRetryPolicyTests.swift`
- Modify: `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift`

- [ ] **Step 1: Write failing request tests**

Cover defaults, no implicit length bounds, compound-extension naming, explicit bounds, invalid ranges, and positive numeric constraints. Exercise the intended API:

```swift
let request = try SavontClusteringRunRequest(
    inputFASTQURL: URL(fileURLWithPath: "/tmp/barcode12.fastq.gz"),
    outputFASTAURL: URL(fileURLWithPath: "/tmp/barcode12-savont-clusters.fasta")
)
XCTAssertEqual(request.qualityValueCutoff, 90)
XCTAssertEqual(request.minimumClusterSize, 3)
XCTAssertNil(request.minimumReadLength)
XCTAssertNil(request.maximumReadLength)
XCTAssertEqual(request.arguments(outputDirectory: URL(fileURLWithPath: "/tmp/run")), [
    "asv", "/tmp/barcode12.fastq.gz", "-o", "/tmp/run", "-t", String(request.threads),
    "--quality-value-cutoff", "90", "--min-cluster-size", "3",
])
```

- [ ] **Step 2: Run request tests and confirm RED**

Run: `swift test --filter SavontClusteringRunRequestTests`

Expected: compile failure because `SavontClusteringRunRequest` does not exist.

- [ ] **Step 3: Implement the minimal request**

Define a public `Sendable`, `Codable`, `Equatable` value with these defaults and fields:

```swift
public struct SavontClusteringRunRequest: Sendable, Codable, Equatable {
    public static let workflowVersion = "1"
    public static let toolVersion = "0.5.0"
    public static let condaEnvironment = "savont"
    public let inputFASTQURL: URL
    public let outputFASTAURL: URL
    public let threads: Int
    public let qualityValueCutoff: Int
    public let minimumClusterSize: Int
    public let minimumReadLength: Int?
    public let maximumReadLength: Int?
    public let singleStrand: Bool
}
```

Validation rejects nonpositive threads/cluster size/length, quality outside `0...100`, non-FASTA output, and minimum greater than maximum. `defaultOutputBaseName(for:)` strips `.fastq`, `.fq`, and their optional `.gz` suffix before adding `-savont-clusters`; `arguments(outputDirectory:threads:singleStrand:)` omits unset bounds.

- [ ] **Step 4: Run request tests and confirm GREEN**

Run: `swift test --filter SavontClusteringRunRequestTests`

Expected: all request tests pass.

- [ ] **Step 5: Write failing strict FASTA tests**

Test `_depth_N` conversion, existing valid `ReadCount-N`, record order, wrapped sequences, count totals, empty input, missing counts, negative/malformed counts, duplicate IDs, malformed records, and integer overflow:

```swift
let summary = try SavontClusterFASTA.normalize(
    sourceURL: input,
    destinationURL: output
)
XCTAssertEqual(summary.clusterCount, 2)
XCTAssertEqual(summary.totalSupportingReads, 83)
XCTAssertEqual(try String(contentsOf: output),
    ">final_consensus_0_depth_71_ReadCount-71\nACGT\n>existing_ReadCount-12\nTGCA\n")
```

- [ ] **Step 6: Run FASTA tests and confirm RED**

Run: `swift test --filter SavontClusterFASTANormalizerTests`

Expected: compile failure because `SavontClusterFASTA` does not exist.

- [ ] **Step 7: Implement strict streaming normalization**

Implement:

```swift
public struct SavontClusterSummary: Sendable, Codable, Equatable {
    public let clusterCount: Int
    public let totalSupportingReads: Int
}

public enum SavontClusterFASTA {
    public static func normalize(sourceURL: URL, destinationURL: URL) throws -> SavontClusterSummary
}
```

Parse one record at a time. Preserve one existing valid `ReadCount-N` field; otherwise derive the count from one valid `_depth_N` field and append `_ReadCount-N`. Reject multiple read-count fields, missing counts, malformed/negative counts, and conflicting identifiers rather than writing `ReadCount-0`. Preserve sequence characters and record order while writing one sequence line per record.

- [ ] **Step 8: Run FASTA tests and confirm GREEN**

Run: `swift test --filter SavontClusterFASTANormalizerTests`

Expected: all normalizer tests pass.

- [ ] **Step 9: Write failing shared retry tests**

Specify `.singleThread`, `.singleStrand`, `.emptyClusters`, and `.none` for the known statuses/message. Include existing MHC cases.

- [ ] **Step 10: Run retry tests and confirm RED**

Run: `swift test --filter SavontRetryPolicyTests`

Expected: compile failure because `SavontRetryPolicy` does not exist.

- [ ] **Step 11: Implement shared retry policy and delegate MHC to it**

Create:

```swift
public enum SavontRetryDecision: Sendable, Equatable {
    case none, singleThread, singleStrand, emptyClusters
}

public enum SavontRetryPolicy {
    public static func decision(
        exitCode: Int32,
        attemptedThreads: Int,
        attemptedSingleStrand: Bool,
        stderr: String
    ) -> SavontRetryDecision
}
```

Keep `FullLengthONTMHCSavontRetryDecision` and make its existing `retryDecision` method map each shared decision into the MHC enum, so no unrelated MHC call sites change.

- [ ] **Step 12: Run focused workflow tests**

Run: `swift test --filter 'Savont(ClusteringRunRequest|ClusterFASTA|RetryPolicy)Tests|FullLengthONTMHCGenotypingPipelineTests/testSavontRunSupport'`

Expected: all selected tests pass.

- [ ] **Step 13: Commit Task 1**

```bash
git add Sources/LungfishWorkflow/Savont Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCSavontRunSupport.swift Tests/LungfishWorkflowTests
git commit -m "feat: define standalone Savont clustering contracts"
```

### Task 2: Managed execution, publication, and provenance

**Files:**
- Create: `Sources/LungfishWorkflow/Savont/SavontClusteringPipeline.swift`
- Create: `Tests/LungfishWorkflowTests/SavontClusteringPipelineTests.swift`
- Modify: `Tests/LungfishWorkflowTests/ScientificProvenancePolicyTests.swift`

- [ ] **Step 1: Write failing pipeline tests with a real fake runner**

Define a test runner that writes `final_asvs.fasta` into the requested directory and returns real argv/stdout/stderr/status. Cover successful publication, input bundle resolution, one-thread retry, single-strand retry, empty-cluster fallback, ordinary failure, cancellation cleanup, missing output, malformed count rejection, rollback preserving an existing output/sidecar, and complete provenance.

The test-facing protocol is:

```swift
public protocol SavontProcessRunning: Sendable {
    func run(arguments: [String], workingDirectory: URL) async throws -> SavontProcessResult
}
```

Verify the final envelope contains top-level replay argv plus one `ProvenanceStep` per actual Savont attempt, with exact argv, checksummed input/output descriptors, runtime identity, exit status, timing, stderr, resolved defaults, final durable output path, cluster count, and total supporting reads.

- [ ] **Step 2: Run pipeline tests and confirm RED**

Run: `swift test --filter SavontClusteringPipelineTests`

Expected: compile failure because pipeline types do not exist.

- [ ] **Step 3: Implement managed runner and pipeline**

Implement:

```swift
public struct SavontClusteringResult: Sendable, Codable, Equatable {
    public let outputFASTAURL: URL
    public let provenanceURL: URL
    public let summary: SavontClusterSummary
    public let usedSingleThreadFallback: Bool
    public let usedSingleStrandFallback: Bool
}

public struct SavontClusteringPipeline: Sendable {
    public func run(_ request: SavontClusteringRunRequest) async throws -> SavontClusteringResult
}
```

The default runner calls `CondaManager.runTool(name: "savont", environment: "savont", timeout: 7_200)`. Each attempt receives its own owned scratch directory. Defer removes scratch on success, failure, cancellation, and throw.

Resolve `.lungfishfastq` with `FASTQBundle.resolvePrimaryFASTQURL`. Preserve the original bundle as the durable top-level input and record the resolved payload as the attempt input.

- [ ] **Step 4: Implement atomic payload-plus-sidecar publication**

Normalize into same-parent hidden staging files. Build a `ProvenanceEnvelope` with `ProvenanceRunBuilder`, a relocated final-output descriptor, exact top-level argv, options/defaults/resolved values, runtime identity, and attempt steps. Install the output and `ProvenanceRecorder.fileSidecarURL(for:)` together using the established backup/restore pattern from `ScientificFileExportProvenance.writeAtomically`. Never leave only one of the pair, and never destroy a prior pair after a failed replacement.

- [ ] **Step 5: Register scientific provenance policy**

Add:

```swift
"fastq savont-cluster": dataWriting(
    "cli.fastq.savont-cluster",
    writer: "SavontClusteringPipeline"
)
```

- [ ] **Step 6: Run pipeline and provenance tests**

Run: `swift test --filter 'SavontClusteringPipelineTests|ScientificProvenancePolicyTests'`

Expected: all selected tests pass with no leftover temporary directories.

- [ ] **Step 7: Commit Task 2**

```bash
git add Sources/LungfishWorkflow/Savont/SavontClusteringPipeline.swift Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift Tests/LungfishWorkflowTests
git commit -m "feat: run and publish standalone Savont clusters"
```

### Task 3: CLI command and stable JSON result

**Files:**
- Create: `Sources/LungfishCLI/Commands/FastqSavontClusterSubcommand.swift`
- Modify: `Sources/LungfishCLI/Commands/FastqCommand.swift`
- Create: `Tests/LungfishCLITests/FastqSavontClusterCommandTests.swift`

- [ ] **Step 1: Write failing CLI parsing and argv tests**

Parse the minimal command and a fully specified command. Assert unset length values remain nil, explicit bounds and `--single-strand` survive, validation errors are clear, and the command is registered under `fastq`.

```swift
let command = try FastqSavontClusterSubcommand.parse([
    "/tmp/reads.fastq", "--output", "/tmp/clusters.fasta",
    "--threads", "4", "--min-read-length", "500", "--max-read-length", "5000",
])
XCTAssertEqual(command.minimumReadLength, 500)
```

- [ ] **Step 2: Run CLI tests and confirm RED**

Run: `swift test --filter FastqSavontClusterCommandTests`

Expected: compile failure because the command does not exist.

- [ ] **Step 3: Implement and register the command**

Use Argument Parser options from the approved contract. Construct `SavontClusteringRunRequest`, invoke the pipeline, and encode sorted, pretty JSON:

```swift
struct FastqSavontClusterPayload: Encodable {
    let outputFASTAPath: String
    let provenancePath: String
    let clusterCount: Int
    let totalSupportingReads: Int
    let usedSingleThreadFallback: Bool
    let usedSingleStrandFallback: Bool
}
```

Progress/warnings go to stderr; stdout contains only the payload.

- [ ] **Step 4: Run CLI tests and command help smoke test**

Run: `swift test --filter FastqSavontClusterCommandTests && swift run lungfish-cli fastq savont-cluster --help`

Expected: tests pass and help lists all typed options.

- [ ] **Step 5: Commit Task 3**

```bash
git add Sources/LungfishCLI/Commands/FastqSavontClusterSubcommand.swift Sources/LungfishCLI/Commands/FastqCommand.swift Tests/LungfishCLITests/FastqSavontClusterCommandTests.swift
git commit -m "feat: expose Savont clustering in the CLI"
```

### Task 4: FASTQ Operations GUI and independent multi-input plans

**Files:**
- Create: `Sources/LungfishApp/Services/FASTQSavontClusteringRequest.swift`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift`
- Modify: `Sources/LungfishApp/Services/FASTQOperationPlanner.swift`
- Modify: `Sources/LungfishApp/Services/FASTQOperationCLIInvocationBuilder.swift`
- Modify: `Sources/LungfishApp/Services/FASTQOperationOutputImporter.swift`
- Modify: `Sources/LungfishApp/Services/WorkflowLibrary.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `Tests/LungfishAppTests/FASTQOperationDialogRoutingTests.swift`
- Modify: `Tests/LungfishAppTests/FASTQOperationExecutionServiceTests.swift`
- Modify: `Tests/LungfishAppTests/FASTQOperationsCatalogTests.swift`
- Modify: `Tests/LungfishAppTests/FASTQOperationToolPanesSourceTests.swift`
- Modify: `Tests/LungfishAppTests/ScientificFASTQProvenancePolicyTests.swift`
- Modify: `Tests/LungfishAppWorkflowTests/WorkflowLibraryTests.swift`

- [ ] **Step 1: Write failing catalog and dialog tests**

Assert clustering contains Savont beside pbAA, Savont requires only FASTQ, does not support FASTA, uses per-input output, requires provenance, defaults to QV 90/minimum cluster 3/no length limits, validates entered bounds, and builds `.savont(request:)` with every selected input retained.

- [ ] **Step 2: Run dialog tests and confirm RED**

Run: `swift test --filter 'FASTQOperationDialogRoutingTests|FASTQOperationsCatalogTests'`

Expected: failures because `.savont` is absent.

- [ ] **Step 3: Add tool identity, state, and native pane**

Add `.savont` to `FASTQOperationToolID`, title it `Savont Clustering`, assign `.clustering`, require only `.fastqDataset`, and add:

```swift
struct FASTQSavontClusteringRequest: Sendable, Equatable {
    let inputURLs: [URL]
    let outputDirectoryURL: URL
    let singleInputOutputName: String?
    let threads: Int
    let qualityValueCutoff: Int
    let minimumClusterSize: Int
    let minimumReadLength: Int?
    let maximumReadLength: Int?
    let singleStrand: Bool
}

case savont(request: FASTQSavontClusteringRequest)
```

State fields mirror the typed request. The pane shows output name for a single selection, threads, quality cutoff, and minimum cluster size, with optional min/max length and single-strand under the existing Advanced Options disclosure. For multiple inputs, `singleInputOutputName` is nil and each output derives from that input's compound-extension-free basename. Do not add raw extra arguments. Special-case the Savont workflow-library item so enabling it requires the existing `full-length-mhc-genotyping` pack that installs Savont; the pipeline's managed-tool lookup remains the final preflight and produces a precise runtime error if that installation is damaged.

- [ ] **Step 4: Run dialog tests and confirm GREEN**

Run: `swift test --filter 'FASTQOperationDialogRoutingTests|FASTQOperationsCatalogTests|FASTQOperationToolPanesSourceTests|WorkflowLibraryTests'`

Expected: all selected tests pass.

- [ ] **Step 5: Write failing planner/invocation/import tests**

Assert two selected inputs become two plans and two CLI invocations, each output ends in its own `-savont-clusters.fasta`, optional length arguments are omitted when nil, collisions are made unique, final FASTAs are discovered, and canonical provenance sidecars remain beside them.

- [ ] **Step 6: Run execution tests and confirm RED**

Run: `swift test --filter FASTQOperationExecutionServiceTests`

Expected: failures in Savont routing expectations.

- [ ] **Step 7: Implement planner, CLI invocation, and output routing**

Extend every exhaustive `FASTQOperationLaunchRequest` switch: inputs, provenance inputs, input replacement, manifest label/kind/parameters, output stem, resolution policy, output kind, display title, operation details, and import. Add a `splitExecutionRequestsIfNeeded` case that zips original and resolved Savont inputs and creates one single-input batch request per pair. Use `.fastqFile` output, name it from the single-input override or `SavontClusteringRunRequest.defaultOutputBaseName(for:)`, and preserve the CLI-authored final sidecar; do not wrap the FASTA as a `.lungfishref`.

- [ ] **Step 8: Run all FASTQ-operation tests**

Run: `swift test --filter FASTQOperation`

Expected: the baseline 215 tests plus new Savont tests pass.

- [ ] **Step 9: Commit Task 4**

```bash
git add Sources/LungfishApp Tests/LungfishAppTests
git commit -m "feat: add Savont to FASTQ clustering tools"
```

### Task 5: Bounded integration, documentation check, and full verification

**Files:**
- Create or Modify: `Tests/LungfishIntegrationTests/SavontClusteringIntegrationTests.swift`

- [ ] **Step 1: Add an opt-in real-data integration test**

Guard the test with `LUNGFISH_SAVONT_TEST_INPUT`. It resolves the supplied FASTQ bundle, deterministically materializes the first 1,000 reads into a temporary FASTQ, runs the installed managed Savont, and verifies every record has `ReadCount-N`, the summary matches a fresh parse, final provenance points at the durable output, and scratch paths no longer exist.

- [ ] **Step 2: Run the integration test against barcode12**

Run:

```bash
LUNGFISH_SAVONT_TEST_INPUT=/Volumes/iWES_WNPRC/32500/32500.lungfish/barcode12.lungfishfastq \
swift test --filter SavontClusteringIntegrationTests
```

Expected: pass, or a clearly reported missing managed Savont runtime. If 1,000 reads legitimately produce no nonempty clusters, repeat with a deterministic 10,000-read subset and record that reason in the test fixture comments.

- [ ] **Step 3: Run focused regression suites**

Run:

```bash
swift test --filter 'Savont|FASTQOperation|FullLengthONTMHCGenotypingPipelineTests/testSavont'
```

Expected: all selected tests pass.

- [ ] **Step 4: Run full build and test verification**

Run:

```bash
swift build
swift test
git diff --check
```

Expected: build succeeds, tests report zero failures, and the diff check is clean.

- [ ] **Step 5: Review the specification line by line**

Re-read `docs/superpowers/specs/2026-08-04-standalone-savont-clustering-design.md` and verify each acceptance criterion against code and test evidence. Fix any uncovered gap test-first.

- [ ] **Step 6: Commit verification additions or fixes**

```bash
git add Tests Sources
git commit -m "test: verify standalone Savont clustering"
```

- [ ] **Step 7: Request final spec and code-quality reviews**

Provide reviewers the committed specification, this plan, base SHA `92e73eb1^`, and current head SHA. Resolve every Critical or Important issue and rerun affected tests before completion.
