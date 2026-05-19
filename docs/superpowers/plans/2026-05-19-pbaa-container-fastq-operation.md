# pbAA Container FASTQ Operation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a container-backed pbAA FASTQ clustering operation that writes the passed consensus FASTA as a provenance-rich `.lungfishref` bundle.

**Architecture:** Add a typed pbAA request/result model in `LungfishWorkflow`, implement a focused Nextflow runner that uses pinned BioContainers, expose it through `lungfish fastq pbaa-cluster`, then route FASTQ Operations to that CLI command. The GUI keeps only guide, output prefix/name, threads, and seed in the main pane; all other pbAA flags go through the existing `AdvancedCommandLineOptions` path.

**Tech Stack:** Swift 6.2, SwiftUI, ArgumentParser, Nextflow, Docker-compatible BioContainers, Lungfish provenance envelope APIs, existing FASTQ Operations execution/import services.

---

## Worktree Note

The current checkout has unrelated dirty files from prior completed work. Do not run destructive git commands and do not revert those edits. When committing implementation slices, stage only the files listed in that task.

## File Structure

- Create `Sources/LungfishWorkflow/PBAA/PBAAContainerPins.swift`: versioned image references, expected digests, workflow schema version, and default pbAA options.
- Create `Sources/LungfishWorkflow/PBAA/PBAAClusteringRunRequest.swift`: typed request and validation for one FASTQ input plus one guide source.
- Create `Sources/LungfishWorkflow/PBAA/PBAANextflowWorkflowWriter.swift`: deterministic `main.nf`, `nextflow.config`, and params JSON generation.
- Create `Sources/LungfishWorkflow/PBAA/PBAAClusteringPipeline.swift`: staging, Nextflow launch, output validation, reference bundle import, and provenance rehydration.
- Create `Sources/LungfishCLI/Commands/FastqPBAAClusterSubcommand.swift`: CLI entry point.
- Modify `Sources/LungfishCLI/Commands/FastqCommand.swift`: register the new subcommand.
- Modify `Sources/LungfishApp/Views/FASTQ/FASTQOperationsCatalog.swift`: add `clustering` category.
- Modify `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift`: add pbAA tool, UI state, validation, and launch request.
- Modify `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift`: add simple pbAA controls and Advanced Options field.
- Modify `Sources/LungfishApp/Services/FASTQOperationCLIInvocationBuilder.swift`: build `lungfish fastq pbaa-cluster`.
- Modify `Sources/LungfishApp/Services/FASTQOperationPlanner.swift`: discover `.lungfishref` outputs for pbAA.
- Modify `Sources/LungfishApp/Services/FASTQOperationOutputImporter.swift`: pass through pbAA reference bundle outputs.
- Modify `Sources/LungfishWorkflow/Conda/PluginPack.swift` and related tests: remove the pbAA/Amplicon Genotyping conda pack from release-visible catalogs.
- Test files:
  - `Tests/LungfishWorkflowTests/PBAAClusteringRequestTests.swift`
  - `Tests/LungfishWorkflowTests/PBAANextflowWorkflowWriterTests.swift`
  - `Tests/LungfishWorkflowTests/PBAAClusteringPipelineTests.swift`
  - `Tests/LungfishCLITests/FastqPBAAClusterCommandTests.swift`
  - `Tests/LungfishAppTests/FASTQOperationDialogRoutingTests.swift`
  - `Tests/LungfishAppTests/FASTQOperationsCatalogTests.swift`
  - existing plugin-pack visibility tests.

---

### Task 1: Add pbAA Workflow Models And Pins

**Files:**
- Create: `Sources/LungfishWorkflow/PBAA/PBAAContainerPins.swift`
- Create: `Sources/LungfishWorkflow/PBAA/PBAAClusteringRunRequest.swift`
- Test: `Tests/LungfishWorkflowTests/PBAAClusteringRequestTests.swift`

- [ ] **Step 1: Write failing tests for container pins and request defaults**

Create `Tests/LungfishWorkflowTests/PBAAClusteringRequestTests.swift`:

```swift
import XCTest
@testable import LungfishWorkflow

final class PBAAClusteringRequestTests: XCTestCase {
    func testContainerPinsAreVersionedAndDigestPinned() {
        XCTAssertEqual(PBAAContainerPins.workflowSchemaVersion, "pbaa-cluster/1")
        XCTAssertEqual(PBAAContainerPins.pbaa.reference, "quay.io/biocontainers/pbaa:1.2.0--h9ee0642_0")
        XCTAssertEqual(PBAAContainerPins.pbaa.expectedDigest, "sha256:fa48bd65b2e429af09eaf06541030e812e5bb0de440059b9b34a6e49c87edd04")
        XCTAssertEqual(PBAAContainerPins.samtools.reference, "quay.io/biocontainers/samtools:1.23.1--ha83d96e_0")
        XCTAssertEqual(PBAAContainerPins.samtools.expectedDigest, "sha256:23cda33a3a42125872766df9aaf1d2db67cdb8c85314b793465188435af31ba6")
    }

    func testRequestDefaultsKeepGuiSimple() throws {
        let request = try PBAAClusteringRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/tmp/reads.fastq"),
            guideSourceURL: URL(fileURLWithPath: "/tmp/guide.fasta"),
            outputDirectory: URL(fileURLWithPath: "/tmp/out", isDirectory: true),
            outputName: "sample-pbaa"
        )

        XCTAssertEqual(request.prefix, "sample-pbaa")
        XCTAssertEqual(request.threads, max(1, ProcessInfo.processInfo.activeProcessorCount))
        XCTAssertEqual(request.seed, 1984)
        XCTAssertEqual(request.extraArguments, [])
        XCTAssertEqual(request.containerPins, .current)
    }

    func testRequestParsesAdvancedOptions() throws {
        let request = try PBAAClusteringRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/tmp/reads.fastq"),
            guideSourceURL: URL(fileURLWithPath: "/tmp/guide.fasta"),
            outputDirectory: URL(fileURLWithPath: "/tmp/out", isDirectory: true),
            outputName: "sample-pbaa",
            extraArgumentsText: #"--min-cluster-read-count 2 --off-target-groups "off targets.txt""#
        )

        XCTAssertEqual(request.extraArguments, [
            "--min-cluster-read-count", "2",
            "--off-target-groups", "off targets.txt",
        ])
        XCTAssertEqual(request.extraArgumentsText, #"--min-cluster-read-count 2 --off-target-groups "off targets.txt""#)
    }
}
```

- [ ] **Step 2: Run tests and confirm failure**

Run:

```bash
swift test --filter PBAAClusteringRequestTests
```

Expected: compile failure because `PBAAContainerPins` and `PBAAClusteringRunRequest` do not exist.

- [ ] **Step 3: Add the model implementation**

Create `Sources/LungfishWorkflow/PBAA/PBAAContainerPins.swift`:

```swift
import Foundation

public struct PBAAContainerImagePin: Sendable, Codable, Equatable {
    public let id: String
    public let reference: String
    public let expectedDigest: String
    public let toolVersion: String

    public var pinnedReference: String {
        "\(reference)@\(expectedDigest)"
    }

    public init(id: String, reference: String, expectedDigest: String, toolVersion: String) {
        self.id = id
        self.reference = reference
        self.expectedDigest = expectedDigest
        self.toolVersion = toolVersion
    }
}

public struct PBAAContainerPins: Sendable, Codable, Equatable {
    public static let workflowSchemaVersion = "pbaa-cluster/1"

    public static let pbaa = PBAAContainerImagePin(
        id: "pbaa",
        reference: "quay.io/biocontainers/pbaa:1.2.0--h9ee0642_0",
        expectedDigest: "sha256:fa48bd65b2e429af09eaf06541030e812e5bb0de440059b9b34a6e49c87edd04",
        toolVersion: "1.2.0"
    )

    public static let samtools = PBAAContainerImagePin(
        id: "samtools",
        reference: "quay.io/biocontainers/samtools:1.23.1--ha83d96e_0",
        expectedDigest: "sha256:23cda33a3a42125872766df9aaf1d2db67cdb8c85314b793465188435af31ba6",
        toolVersion: "1.23.1"
    )

    public static let current = PBAAContainerPins(pbaa: pbaa, samtools: samtools)

    public let pbaa: PBAAContainerImagePin
    public let samtools: PBAAContainerImagePin

    public init(pbaa: PBAAContainerImagePin, samtools: PBAAContainerImagePin) {
        self.pbaa = pbaa
        self.samtools = samtools
    }
}
```

Create `Sources/LungfishWorkflow/PBAA/PBAAClusteringRunRequest.swift`:

```swift
import Foundation

public struct PBAAClusteringRunRequest: Sendable, Codable, Equatable {
    public let inputFASTQURL: URL
    public let guideSourceURL: URL
    public let outputDirectory: URL
    public let outputName: String
    public let prefix: String
    public let threads: Int
    public let seed: Int
    public let extraArgumentsText: String
    public let extraArguments: [String]
    public let containerPins: PBAAContainerPins

    public var rawPBAAOutputDirectory: URL {
        outputDirectory.appendingPathComponent("raw-pbaa", isDirectory: true)
    }

    public init(
        inputFASTQURL: URL,
        guideSourceURL: URL,
        outputDirectory: URL,
        outputName: String,
        threads: Int = max(1, ProcessInfo.processInfo.activeProcessorCount),
        seed: Int = 1984,
        extraArgumentsText: String = "",
        containerPins: PBAAContainerPins = .current
    ) throws {
        let sanitizedName = Self.sanitizePrefix(outputName)
        self.inputFASTQURL = inputFASTQURL.standardizedFileURL
        self.guideSourceURL = guideSourceURL.standardizedFileURL
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.outputName = sanitizedName
        self.prefix = sanitizedName
        self.threads = max(1, threads)
        self.seed = seed
        self.extraArgumentsText = extraArgumentsText
        self.extraArguments = try AdvancedCommandLineOptions.parse(extraArgumentsText)
        self.containerPins = containerPins
    }

    static func sanitizePrefix(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = trimmed.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        let collapsed = String(replaced).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return collapsed.isEmpty ? "pbaa-clusters" : collapsed
    }
}
```

- [ ] **Step 4: Run tests and confirm pass**

Run:

```bash
swift test --filter PBAAClusteringRequestTests
```

Expected: all tests in `PBAAClusteringRequestTests` pass.

- [ ] **Step 5: Commit Task 1**

```bash
git add Sources/LungfishWorkflow/PBAA/PBAAContainerPins.swift \
        Sources/LungfishWorkflow/PBAA/PBAAClusteringRunRequest.swift \
        Tests/LungfishWorkflowTests/PBAAClusteringRequestTests.swift
git commit -m "Add pbAA clustering request model"
```

---

### Task 2: Generate The Focused Nextflow Workflow

**Files:**
- Create: `Sources/LungfishWorkflow/PBAA/PBAANextflowWorkflowWriter.swift`
- Test: `Tests/LungfishWorkflowTests/PBAANextflowWorkflowWriterTests.swift`

- [ ] **Step 1: Write failing workflow writer tests**

Create `Tests/LungfishWorkflowTests/PBAANextflowWorkflowWriterTests.swift`:

```swift
import XCTest
@testable import LungfishWorkflow

final class PBAANextflowWorkflowWriterTests: XCTestCase {
    func testWriterCreatesMainConfigAndParams() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pbaa-writer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let request = try PBAAClusteringRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/data/reads.fastq"),
            guideSourceURL: URL(fileURLWithPath: "/data/guide.fasta"),
            outputDirectory: root.appendingPathComponent("result", isDirectory: true),
            outputName: "sample",
            threads: 4,
            seed: 7,
            extraArgumentsText: "--min-cluster-read-count 2"
        )

        let files = try PBAANextflowWorkflowWriter().writeWorkflow(for: request, to: root)
        let main = try String(contentsOf: files.mainNFURL, encoding: .utf8)
        let config = try String(contentsOf: files.configURL, encoding: .utf8)
        let params = try JSONDecoder().decode(PBAANextflowParameters.self, from: Data(contentsOf: files.paramsURL))

        XCTAssertTrue(main.contains("process INDEX_GUIDE"))
        XCTAssertTrue(main.contains("process INDEX_READS"))
        XCTAssertTrue(main.contains("process PBAA_CLUSTER"))
        XCTAssertTrue(main.contains("pbaa cluster"))
        XCTAssertTrue(config.contains("quay.io/biocontainers/pbaa:1.2.0--h9ee0642_0"))
        XCTAssertTrue(config.contains("@sha256:fa48bd65b2e429af09eaf06541030e812e5bb0de440059b9b34a6e49c87edd04"))
        XCTAssertTrue(config.contains("quay.io/biocontainers/samtools:1.23.1--ha83d96e_0"))
        XCTAssertTrue(config.contains("@sha256:23cda33a3a42125872766df9aaf1d2db67cdb8c85314b793465188435af31ba6"))
        XCTAssertEqual(params.outdir, request.rawPBAAOutputDirectory.path)
        XCTAssertEqual(params.prefix, "sample")
        XCTAssertEqual(params.threads, 4)
        XCTAssertEqual(params.seed, 7)
        XCTAssertEqual(params.extraArguments, ["--min-cluster-read-count", "2"])
    }
}
```

- [ ] **Step 2: Run tests and confirm failure**

Run:

```bash
swift test --filter PBAANextflowWorkflowWriterTests
```

Expected: compile failure because the writer types do not exist.

- [ ] **Step 3: Implement deterministic workflow file generation**

Create `Sources/LungfishWorkflow/PBAA/PBAANextflowWorkflowWriter.swift` with:

```swift
import Foundation

public struct PBAANextflowWorkflowFiles: Sendable, Equatable {
    public let mainNFURL: URL
    public let configURL: URL
    public let paramsURL: URL
}

public struct PBAANextflowParameters: Codable, Sendable, Equatable {
    public let guide: String
    public let reads: String
    public let outdir: String
    public let prefix: String
    public let threads: Int
    public let seed: Int
    public let extraArguments: [String]
}

public struct PBAANextflowWorkflowWriter: Sendable {
    public init() {}

    public func writeWorkflow(
        for request: PBAAClusteringRunRequest,
        to directory: URL
    ) throws -> PBAANextflowWorkflowFiles {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mainURL = directory.appendingPathComponent("main.nf")
        let configURL = directory.appendingPathComponent("nextflow.config")
        let paramsURL = directory.appendingPathComponent("params.json")

        try mainNF().write(to: mainURL, atomically: true, encoding: .utf8)
        try config(pins: request.containerPins).write(to: configURL, atomically: true, encoding: .utf8)

        let params = PBAANextflowParameters(
            guide: request.guideSourceURL.path,
            reads: request.inputFASTQURL.path,
            outdir: request.rawPBAAOutputDirectory.path,
            prefix: request.prefix,
            threads: request.threads,
            seed: request.seed,
            extraArguments: request.extraArguments
        )
        let data = try JSONEncoder.lungfishPrettyPrinted.encode(params)
        try data.write(to: paramsURL, options: .atomic)
        return PBAANextflowWorkflowFiles(mainNFURL: mainURL, configURL: configURL, paramsURL: paramsURL)
    }

    private func mainNF() -> String {
        """
        nextflow.enable.dsl = 2

        process INDEX_GUIDE {
          tag "guide"
          container params.samtools_container
          input:
          path guide
          output:
          tuple path("guide.fasta"), path("guide.fasta.fai")
          script:
          '''
          cp "${guide}" guide.fasta
          samtools faidx guide.fasta
          '''
        }

        process INDEX_READS {
          tag "reads"
          container params.samtools_container
          input:
          path reads
          output:
          tuple path("reads.fastq"), path("reads.fastq.fai")
          script:
          '''
          cp "${reads}" reads.fastq
          samtools fqidx reads.fastq
          '''
        }

        process PBAA_CLUSTER {
          tag params.prefix
          container params.pbaa_container
          publishDir params.outdir, mode: 'copy', overwrite: true
          input:
          tuple path(guide), path(guide_index)
          tuple path(reads), path(reads_index)
          output:
          path "${params.prefix}_*"
          script:
          def shellQuote = { value -> "'" + value.toString().replace("'", "'\\\\''") + "'" }
          def extra = (params.extraArguments ?: []).collect { shellQuote(it) }.join(' ')
          '''
          pbaa cluster -j ${params.threads} --seed ${params.seed} ${extra} guide.fasta reads.fastq ${params.prefix}
          '''
        }

        workflow {
          guide_ch = Channel.fromPath(params.guide)
          reads_ch = Channel.fromPath(params.reads)
          indexed_guide = INDEX_GUIDE(guide_ch)
          indexed_reads = INDEX_READS(reads_ch)
          PBAA_CLUSTER(indexed_guide, indexed_reads)
        }
        """
    }

    private func config(pins: PBAAContainerPins) -> String {
        """
        process.executor = 'local'
        docker.enabled = true
        process.containerOptions = '--platform linux/amd64'
        params.pbaa_container = '\(pins.pbaa.pinnedReference)'
        params.samtools_container = '\(pins.samtools.pinnedReference)'
        params.extraArguments = []
        """
    }
}
```

If `JSONEncoder.lungfishPrettyPrinted` does not exist, add a private helper in this file:

```swift
private extension JSONEncoder {
    static var lungfishPrettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
```

- [ ] **Step 4: Run tests and confirm pass**

Run:

```bash
swift test --filter PBAANextflowWorkflowWriterTests
```

Expected: writer tests pass.

- [ ] **Step 5: Commit Task 2**

```bash
git add Sources/LungfishWorkflow/PBAA/PBAANextflowWorkflowWriter.swift \
        Tests/LungfishWorkflowTests/PBAANextflowWorkflowWriterTests.swift
git commit -m "Generate pbAA Nextflow workflow files"
```

---

### Task 3: Implement pbAA Pipeline, Output Validation, And Provenance

**Files:**
- Create: `Sources/LungfishWorkflow/PBAA/PBAAClusteringPipeline.swift`
- Test: `Tests/LungfishWorkflowTests/PBAAClusteringPipelineTests.swift`

- [ ] **Step 1: Write failing pipeline tests with a stub Nextflow runner**

Create `Tests/LungfishWorkflowTests/PBAAClusteringPipelineTests.swift`:

```swift
import XCTest
@testable import LungfishWorkflow

final class PBAAClusteringPipelineTests: XCTestCase {
    func testPipelineImportsPassedFastaAsReferenceBundle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pbaa-pipeline-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reads = root.appendingPathComponent("reads.fastq")
        let guide = root.appendingPathComponent("guide.fasta")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "@r1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        try ">g1|target\nACGT\n".write(to: guide, atomically: true, encoding: .utf8)

        let runner = StubPBAANextflowRunner { request, _ in
            let raw = request.outputDirectory.appendingPathComponent("raw-pbaa", isDirectory: true)
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            let passed = raw.appendingPathComponent("\(request.prefix)_passed_cluster_sequences.fasta")
            try ">cluster1\nACGT\n".write(to: passed, atomically: true, encoding: .utf8)
            return PBAANextflowRunResult(exitCode: 0, stdout: "ok", stderr: "", rawOutputDirectory: raw)
        }

        let output = root.appendingPathComponent("out", isDirectory: true)
        let request = try PBAAClusteringRunRequest(
            inputFASTQURL: reads,
            guideSourceURL: guide,
            outputDirectory: output,
            outputName: "sample"
        )

        let result = try await PBAAClusteringPipeline(nextflowRunner: runner).run(request)

        XCTAssertEqual(result.referenceBundleURL.pathExtension, "lungfishref")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.referenceBundleURL.path))
        XCTAssertEqual(result.passedConsensusFASTAURL.lastPathComponent, "sample_passed_cluster_sequences.fasta")
        XCTAssertNotNil(ProvenanceRecorder.loadEnvelope(from: result.referenceBundleURL))
    }

    func testPipelineFailsWhenPassedFastaIsEmpty() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pbaa-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let reads = root.appendingPathComponent("reads.fastq")
        let guide = root.appendingPathComponent("guide.fasta")
        try "@r1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        try ">g1|target\nACGT\n".write(to: guide, atomically: true, encoding: .utf8)

        let runner = StubPBAANextflowRunner { request, _ in
            let raw = request.outputDirectory.appendingPathComponent("raw-pbaa", isDirectory: true)
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: raw.appendingPathComponent("\(request.prefix)_passed_cluster_sequences.fasta").path, contents: Data())
            return PBAANextflowRunResult(exitCode: 0, stdout: "ok", stderr: "", rawOutputDirectory: raw)
        }

        let request = try PBAAClusteringRunRequest(
            inputFASTQURL: reads,
            guideSourceURL: guide,
            outputDirectory: root.appendingPathComponent("out", isDirectory: true),
            outputName: "sample"
        )

        do {
            _ = try await PBAAClusteringPipeline(nextflowRunner: runner).run(request)
            XCTFail("Expected empty passed FASTA failure")
        } catch PBAAClusteringError.emptyPassedConsensusFASTA(let url) {
            XCTAssertEqual(url.lastPathComponent, "sample_passed_cluster_sequences.fasta")
        }
    }
}

private struct StubPBAANextflowRunner: PBAANextflowRunning {
    let handler: @Sendable (PBAAClusteringRunRequest, URL) async throws -> PBAANextflowRunResult

    func run(request: PBAAClusteringRunRequest, workflowDirectory: URL) async throws -> PBAANextflowRunResult {
        try await handler(request, workflowDirectory)
    }
}
```

- [ ] **Step 2: Run tests and confirm failure**

Run:

```bash
swift test --filter PBAAClusteringPipelineTests
```

Expected: compile failure because pipeline types do not exist.

- [ ] **Step 3: Implement pipeline and injectable Nextflow runner**

Create `Sources/LungfishWorkflow/PBAA/PBAAClusteringPipeline.swift` with these public types:

```swift
import Foundation

public struct PBAANextflowRunResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let rawOutputDirectory: URL
}

public struct PBAAClusteringResult: Sendable, Equatable {
    public let referenceBundleURL: URL
    public let rawOutputDirectory: URL
    public let passedConsensusFASTAURL: URL
}

public enum PBAAClusteringError: Error, LocalizedError, Equatable {
    case nextflowUnavailable
    case nextflowFailed(status: Int32, stderr: String)
    case missingPassedConsensusFASTA(URL)
    case emptyPassedConsensusFASTA(URL)

    public var errorDescription: String? {
        switch self {
        case .nextflowUnavailable:
            return "Nextflow is not available. Install or provision Nextflow before running pbAA clustering."
        case .nextflowFailed(let status, let stderr):
            return "pbAA Nextflow workflow failed with exit status \(status): \(stderr)"
        case .missingPassedConsensusFASTA(let url):
            return "pbAA did not produce the passed cluster FASTA: \(url.lastPathComponent)"
        case .emptyPassedConsensusFASTA(let url):
            return "pbAA produced an empty passed cluster FASTA: \(url.lastPathComponent)"
        }
    }
}

public protocol PBAANextflowRunning: Sendable {
    func run(request: PBAAClusteringRunRequest, workflowDirectory: URL) async throws -> PBAANextflowRunResult
}

public struct PBAAClusteringPipeline: Sendable {
    private let workflowWriter: PBAANextflowWorkflowWriter
    private let nextflowRunner: any PBAANextflowRunning
    private let referenceImporter: ReferenceBundleImportService

    public init(
        workflowWriter: PBAANextflowWorkflowWriter = PBAANextflowWorkflowWriter(),
        nextflowRunner: any PBAANextflowRunning = ProcessPBAANextflowRunner(),
        referenceImporter: ReferenceBundleImportService = .shared
    ) {
        self.workflowWriter = workflowWriter
        self.nextflowRunner = nextflowRunner
        self.referenceImporter = referenceImporter
    }

    public func run(_ request: PBAAClusteringRunRequest) async throws -> PBAAClusteringResult {
        try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        let workflowDirectory = request.outputDirectory.appendingPathComponent("nextflow", isDirectory: true)
        _ = try workflowWriter.writeWorkflow(for: request, to: workflowDirectory)

        let rawOutputDirectory = request.outputDirectory.appendingPathComponent("raw-pbaa", isDirectory: true)
        try FileManager.default.createDirectory(at: rawOutputDirectory, withIntermediateDirectories: true)
        let startedAt = Date()
        let runResult = try await nextflowRunner.run(request: request, workflowDirectory: workflowDirectory)
        let completedAt = Date()
        guard runResult.exitCode == 0 else {
            throw PBAAClusteringError.nextflowFailed(status: runResult.exitCode, stderr: runResult.stderr)
        }

        let passedFASTA = runResult.rawOutputDirectory
            .appendingPathComponent("\(request.prefix)_passed_cluster_sequences.fasta")
        guard FileManager.default.fileExists(atPath: passedFASTA.path) else {
            throw PBAAClusteringError.missingPassedConsensusFASTA(passedFASTA)
        }
        let size = (try FileManager.default.attributesOfItem(atPath: passedFASTA.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard size > 0 else {
            throw PBAAClusteringError.emptyPassedConsensusFASTA(passedFASTA)
        }

        let importResult = try await referenceImporter.importAsReferenceBundle(
            sourceURL: passedFASTA,
            outputDirectory: request.outputDirectory,
            preferredBundleName: request.outputName
        )
        try writePBAAProvenance(
            request: request,
            runResult: runResult,
            referenceBundleURL: importResult.bundleURL,
            passedFASTA: passedFASTA,
            startedAt: startedAt,
            completedAt: completedAt
        )
        return PBAAClusteringResult(
            referenceBundleURL: importResult.bundleURL,
            rawOutputDirectory: runResult.rawOutputDirectory,
            passedConsensusFASTAURL: passedFASTA
        )
    }

    private func writePBAAProvenance(
        request: PBAAClusteringRunRequest,
        runResult: PBAANextflowRunResult,
        referenceBundleURL: URL,
        passedFASTA: URL,
        startedAt: Date,
        completedAt: Date
    ) throws {
        let argv = [
            "lungfish", "fastq", "pbaa-cluster",
            request.inputFASTQURL.path,
            "--guide", request.guideSourceURL.path,
            "--output-dir", request.outputDirectory.path,
            "--output-name", request.outputName,
            "--threads", String(request.threads),
            "--seed", String(request.seed),
        ] + (request.extraArgumentsText.isEmpty ? [] : ["--extra-args", request.extraArgumentsText])

        let options = ProvenanceOptions(
            explicit: [
                "inputFASTQ": .file(request.inputFASTQURL),
                "guide": .file(request.guideSourceURL),
                "outputDirectory": .file(request.outputDirectory),
                "outputName": .string(request.outputName),
                "prefix": .string(request.prefix),
                "threads": .integer(request.threads),
                "seed": .integer(request.seed),
                "extraArgs": .string(request.extraArgumentsText),
                "extraArguments": .array(request.extraArguments.map(ParameterValue.string)),
                "pbaaContainer": .string(request.containerPins.pbaa.reference),
                "pbaaContainerExpectedDigest": .string(request.containerPins.pbaa.expectedDigest),
                "samtoolsContainer": .string(request.containerPins.samtools.reference),
                "samtoolsContainerExpectedDigest": .string(request.containerPins.samtools.expectedDigest),
                "workflowSchemaVersion": .string(PBAAContainerPins.workflowSchemaVersion),
            ],
            defaults: [
                "threads": .integer(max(1, ProcessInfo.processInfo.activeProcessorCount)),
                "seed": .integer(1984),
                "extraArguments": .array([]),
            ],
            resolvedDefaults: [:]
        )

        let envelope = try ProvenanceRunBuilder(
            workflowName: "pbAA Amplicon Clustering",
            workflowVersion: PBAAContainerPins.workflowSchemaVersion,
            toolName: "pbaa",
            toolVersion: request.containerPins.pbaa.toolVersion
        )
        .argv(argv)
        .reproducibleCommand(argv.map(shellEscape).joined(separator: " "))
        .options(explicit: options.explicit, defaults: options.defaults, resolved: options.resolvedDefaults)
        .runtime(ProvenanceRuntimeIdentity(
            containerImage: request.containerPins.pbaa.reference,
            containerDigest: request.containerPins.pbaa.expectedDigest
        ))
        .output(referenceBundleURL)
        .step(ProvenanceStep(
            toolName: "pbaa",
            toolVersion: request.containerPins.pbaa.toolVersion,
            argv: ["pbaa", "cluster", "-j", String(request.threads), "--seed", String(request.seed)] + request.extraArguments + ["guide.fasta", "reads.fastq", request.prefix],
            inputs: [
                try ProvenanceFileDescriptor.file(url: request.inputFASTQURL, role: .input),
                try ProvenanceFileDescriptor.file(url: request.guideSourceURL, role: .input),
            ],
            outputs: [try ProvenanceFileDescriptor.file(url: passedFASTA, role: .output)],
            exitStatus: Int(runResult.exitCode),
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: runResult.stderr.isEmpty ? nil : runResult.stderr,
            startedAt: startedAt,
            completedAt: completedAt
        ))
        .complete(
            exitStatus: Int(runResult.exitCode),
            stderr: runResult.stderr.isEmpty ? nil : runResult.stderr,
            startedAt: startedAt,
            endedAt: completedAt
        )

        try ProvenanceWriter(signingProvider: nil).write(envelope, to: referenceBundleURL)
    }
}
```

Add `ProcessPBAANextflowRunner` in the same file. It should run `/usr/bin/env nextflow run main.nf -c nextflow.config -params-file params.json -work-dir <workflowDirectory>/work -with-trace <workflowDirectory>/trace.txt` in `workflowDirectory` and return stdout/stderr. If `nextflow` is missing, throw `PBAAClusteringError.nextflowUnavailable`.

- [ ] **Step 4: Run pipeline tests and fix compile mismatches**

Run:

```bash
swift test --filter PBAAClusteringPipelineTests
```

Expected: tests pass without Docker or Nextflow because they use the stub runner.

- [ ] **Step 5: Commit Task 3**

```bash
git add Sources/LungfishWorkflow/PBAA/PBAAClusteringPipeline.swift \
        Tests/LungfishWorkflowTests/PBAAClusteringPipelineTests.swift
git commit -m "Run pbAA clustering pipeline into reference bundles"
```

---

### Task 4: Add The CLI Command

**Files:**
- Create: `Sources/LungfishCLI/Commands/FastqPBAAClusterSubcommand.swift`
- Modify: `Sources/LungfishCLI/Commands/FastqCommand.swift`
- Test: `Tests/LungfishCLITests/FastqPBAAClusterCommandTests.swift`

- [ ] **Step 1: Write failing CLI parse tests**

Create `Tests/LungfishCLITests/FastqPBAAClusterCommandTests.swift`:

```swift
import XCTest
@testable import LungfishCLI

final class FastqPBAAClusterCommandTests: XCTestCase {
    func testFastqCommandRegistersPBAACluster() {
        let names = FastqCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("pbaa-cluster"))
    }

    func testPBAAClusterParsesSimpleGuiOptionsAndAdvancedOptions() throws {
        let command = try FastqPBAAClusterSubcommand.parse([
            "/tmp/reads.fastq",
            "--guide", "/tmp/guide.fasta",
            "--output-dir", "/tmp/out",
            "--output-name", "sample",
            "--threads", "4",
            "--seed", "7",
            "--extra-args", "--min-cluster-read-count 2",
        ])

        XCTAssertEqual(command.input, "/tmp/reads.fastq")
        XCTAssertEqual(command.guide, "/tmp/guide.fasta")
        XCTAssertEqual(command.outputDir, "/tmp/out")
        XCTAssertEqual(command.outputName, "sample")
        XCTAssertEqual(command.threads, 4)
        XCTAssertEqual(command.seed, 7)
        XCTAssertEqual(command.extraArgs, "--min-cluster-read-count 2")
    }
}
```

- [ ] **Step 2: Run tests and confirm failure**

Run:

```bash
swift test --filter FastqPBAAClusterCommandTests
```

Expected: compile failure because the command is not registered.

- [ ] **Step 3: Implement command and register it**

Create `Sources/LungfishCLI/Commands/FastqPBAAClusterSubcommand.swift`:

```swift
import ArgumentParser
import Foundation
import LungfishWorkflow

struct FastqPBAAClusterSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pbaa-cluster",
        abstract: "Cluster PacBio HiFi amplicon reads with pbAA in pinned containers"
    )

    @Argument(help: "Input FASTQ file or .lungfishfastq bundle")
    var input: String

    @Option(name: .customLong("guide"), help: "Guide FASTA file or .lungfishref bundle")
    var guide: String

    @Option(name: .customLong("output-dir"), help: "Directory for raw outputs and the .lungfishref result")
    var outputDir: String

    @Option(name: .customLong("output-name"), help: "Output bundle name and pbAA prefix")
    var outputName: String = "pbaa-clusters"

    @Option(name: .customLong("threads"), help: "Threads for pbAA")
    var threads: Int = max(1, ProcessInfo.processInfo.activeProcessorCount)

    @Option(name: .customLong("seed"), help: "pbAA random seed")
    var seed: Int = 1984

    @Option(name: .customLong("extra-args"), parsing: .unconditional, help: "Advanced pbAA arguments")
    var extraArgs: String = ""

    func run() async throws {
        let request = try PBAAClusteringRunRequest(
            inputFASTQURL: URL(fileURLWithPath: input),
            guideSourceURL: URL(fileURLWithPath: guide),
            outputDirectory: URL(fileURLWithPath: outputDir, isDirectory: true),
            outputName: outputName,
            threads: threads,
            seed: seed,
            extraArgumentsText: extraArgs
        )
        let result = try await PBAAClusteringPipeline().run(request)
        let payload = [
            "referenceBundlePath": result.referenceBundleURL.path,
            "rawOutputDirectory": result.rawOutputDirectory.path,
            "passedConsensusFASTAPath": result.passedConsensusFASTAURL.path,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
```

Modify `Sources/LungfishCLI/Commands/FastqCommand.swift` by adding `FastqPBAAClusterSubcommand.self` to the `subcommands` array after `FastqQCSummarySubcommand.self`.

- [ ] **Step 4: Run CLI tests and command help**

Run:

```bash
swift test --filter FastqPBAAClusterCommandTests
swift run lungfish-cli fastq pbaa-cluster --help
```

Expected: tests pass; help includes `--guide`, `--output-dir`, `--output-name`, `--threads`, `--seed`, and `--extra-args`.

- [ ] **Step 5: Commit Task 4**

```bash
git add Sources/LungfishCLI/Commands/FastqPBAAClusterSubcommand.swift \
        Sources/LungfishCLI/Commands/FastqCommand.swift \
        Tests/LungfishCLITests/FastqPBAAClusterCommandTests.swift
git commit -m "Expose pbAA clustering in fastq CLI"
```

---

### Task 5: Add FASTQ Operations UI And Routing

**Files:**
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationsCatalog.swift`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift`
- Modify: `Sources/LungfishApp/Services/FASTQOperationCLIInvocationBuilder.swift`
- Modify: `Sources/LungfishApp/Services/FASTQOperationPlanner.swift`
- Modify: `Sources/LungfishApp/Services/FASTQOperationOutputImporter.swift`
- Test: `Tests/LungfishAppTests/FASTQOperationsCatalogTests.swift`
- Test: `Tests/LungfishAppTests/FASTQOperationDialogRoutingTests.swift`
- Test: `Tests/LungfishAppTests/FASTQOperationExecutionServiceTests.swift`

- [ ] **Step 1: Write failing app routing tests**

Add to `Tests/LungfishAppTests/FASTQOperationsCatalogTests.swift`:

```swift
func testCatalogIncludesClusteringCategory() {
    XCTAssertTrue(FASTQOperationCategoryID.allCases.contains(.clustering))
    XCTAssertEqual(FASTQOperationCategoryID.clustering.title, "CLUSTERING")
    XCTAssertEqual(FASTQOperationCategoryID.clustering.requiredPackIDs, [])
}
```

Add to `Tests/LungfishAppTests/FASTQOperationDialogRoutingTests.swift`:

```swift
@MainActor
func testPBAABuildsLaunchRequestWithSimpleAndAdvancedOptions() throws {
    let input = URL(fileURLWithPath: "/tmp/reads.fastq")
    let guide = URL(fileURLWithPath: "/tmp/guide.fasta")
    let state = FASTQOperationDialogState(
        initialCategory: .clustering,
        selectedInputURLs: [input],
        projectURL: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
    )

    state.selectTool(.pbaa)
    state.setAuxiliaryInput(guide, for: .referenceSequence)
    state.pbaaOutputName = "sample clusters"
    state.pbaaThreads = 4
    state.pbaaSeed = 7
    state.pbaaExtraArguments = "--min-cluster-read-count 2"
    state.prepareForRun()

    guard case .pbaa(let request)? = state.pendingLaunchRequest else {
        return XCTFail("Expected pbaa launch request")
    }

    XCTAssertEqual(request.inputFASTQURL, input)
    XCTAssertEqual(request.guideSourceURL, guide)
    XCTAssertEqual(request.outputName, "sample-clusters")
    XCTAssertEqual(request.threads, 4)
    XCTAssertEqual(request.seed, 7)
    XCTAssertEqual(request.extraArguments, ["--min-cluster-read-count", "2"])
}
```

Add to `Tests/LungfishAppTests/FASTQOperationExecutionServiceTests.swift`:

```swift
func testPBAAInvocationUsesFastqPBAAClusterCLI() throws {
    let request = try PBAAClusteringRunRequest(
        inputFASTQURL: URL(fileURLWithPath: "/tmp/reads.fastq"),
        guideSourceURL: URL(fileURLWithPath: "/tmp/guide.fasta"),
        outputDirectory: URL(fileURLWithPath: "/tmp/out", isDirectory: true),
        outputName: "sample",
        threads: 4,
        seed: 7,
        extraArgumentsText: "--min-cluster-read-count 2"
    )

    let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(for: .pbaa(request: request))

    XCTAssertEqual(invocation.subcommand, "fastq")
    XCTAssertEqual(invocation.arguments.prefix(2), ["pbaa-cluster", "/tmp/reads.fastq"])
    XCTAssertTrue(invocation.arguments.contains("--guide"))
    XCTAssertTrue(invocation.arguments.contains("/tmp/guide.fasta"))
    XCTAssertTrue(invocation.arguments.contains("--extra-args"))
}
```

- [ ] **Step 2: Run focused tests and confirm failure**

Run:

```bash
swift test --filter 'FASTQOperationsCatalogTests|FASTQOperationDialogRoutingTests|FASTQOperationExecutionServiceTests/testPBAAInvocationUsesFastqPBAAClusterCLI'
```

Expected: compile failures for `.clustering`, `.pbaa`, and pbAA state properties.

- [ ] **Step 3: Implement catalog and dialog state**

Modify `FASTQOperationCategoryID`:

```swift
case clustering
```

Return title and no pack requirement:

```swift
case .clustering: return "CLUSTERING"
```

Add `case .pbaa` to `FASTQOperationToolID` with:

```swift
case .pbaa: return "pbAA Amplicon Clustering"
case .pbaa: return "Cluster PacBio HiFi amplicon reads and emit passed consensus sequences as a reference bundle."
case .pbaa: return .clustering
case .pbaa: return [.fastqDataset, .referenceSequence]
case .pbaa: return .perInput
case .pbaa: return false
case .pbaa: return false
```

Add state properties initialized in `FASTQOperationDialogState.init`:

```swift
var pbaaOutputName: String
var pbaaThreads: Int
var pbaaSeed: Int
var pbaaExtraArguments: String
```

Initialize:

```swift
self.pbaaOutputName = selectedInputURLs.first?.deletingPathExtension().lastPathComponent.appending("-pbaa") ?? "pbaa-clusters"
self.pbaaThreads = max(1, ProcessInfo.processInfo.activeProcessorCount)
self.pbaaSeed = 1984
self.pbaaExtraArguments = ""
```

Add launch request:

```swift
case .pbaa:
    guard selectedInputURLs.count == 1,
          let inputURL = selectedInputURLs.first,
          let guideURL = auxiliaryInputURL(for: .referenceSequence),
          let outputDirectoryURL else { return nil }
    guard let request = try? PBAAClusteringRunRequest(
        inputFASTQURL: inputURL,
        guideSourceURL: guideURL,
        outputDirectory: outputDirectoryURL,
        outputName: pbaaOutputName,
        threads: pbaaThreads,
        seed: pbaaSeed,
        extraArgumentsText: pbaaExtraArguments
    ) else { return nil }
    return .pbaa(request: request)
```

Add `case .pbaa(request: PBAAClusteringRunRequest)` to `FASTQOperationLaunchRequest`.

- [ ] **Step 4: Implement UI controls**

In `FASTQOperationInputsSection.usesProjectReferencePicker(for:)`, change:

```swift
kind == .referenceSequence && state.selectedToolID == .orientReads
```

to:

```swift
kind == .referenceSequence && (state.selectedToolID == .orientReads || state.selectedToolID == .pbaa)
```

In `FASTQOperationPrimarySettingsSection`, add:

```swift
case .pbaa:
    labeledTextField("Output Name", text: $state.pbaaOutputName)
    HStack(spacing: 12) {
        labeledCompactTextField("Threads", text: Self.intBinding(state, \.pbaaThreads))
        labeledCompactTextField("Seed", text: Self.intBinding(state, \.pbaaSeed))
    }
    Text("Select the guide sequence in the Inputs section.")
        .font(.caption)
        .foregroundStyle(.secondary)
```

In `FASTQOperationAdvancedSettingsSection`, add:

```swift
case .pbaa:
    DisclosureGroup("Advanced Options") {
        VStack(alignment: .leading, spacing: 8) {
            labeledTextField("pbAA arguments", text: $state.pbaaExtraArguments)
            Text("Arguments are passed to `pbaa cluster` after the simple settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }
```

Add readiness validation:

```swift
case .pbaa:
    if selectedInputURLs.count != 1 {
        return "pbAA clustering runs one demultiplexed HiFi FASTQ dataset at a time."
    }
    if auxiliaryInputURL(for: .referenceSequence) == nil {
        return "Select a guide sequence to continue."
    }
    if pbaaThreads <= 0 {
        return "Enter a positive thread count."
    }
    do {
        _ = try AdvancedCommandLineOptions.parse(pbaaExtraArguments)
        return nil
    } catch {
        return error.localizedDescription
    }
```

- [ ] **Step 5: Implement CLI invocation and output discovery**

In `FASTQOperationCLIInvocationBuilder`, add:

```swift
case .pbaa(let request):
    var arguments = [
        "pbaa-cluster",
        request.inputFASTQURL.path,
        "--guide", request.guideSourceURL.path,
        "--output-dir", request.outputDirectory.path,
        "--output-name", request.outputName,
        "--threads", String(request.threads),
        "--seed", String(request.seed),
    ]
    if !request.extraArgumentsText.isEmpty {
        arguments += ["--extra-args", request.extraArgumentsText]
    }
    return CLIInvocation(subcommand: "fastq", arguments: arguments)
```

In `FASTQOperationPlanner`, make `.pbaa` output mode `.perInput`, output kind `.directory`, output name stem `"pbaa"`, and add reference bundle discovery:

```swift
static func discoverReferenceBundles(in directory: URL) -> [URL] {
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }
    return contents.filter { $0.pathExtension.lowercased() == "lungfishref" }
}
```

Return discovered reference bundles for `.pbaa` plans.

- [ ] **Step 6: Run app tests and fix compile mismatches**

Run:

```bash
swift test --filter 'FASTQOperationsCatalogTests|FASTQOperationDialogRoutingTests|FASTQOperationExecutionServiceTests/testPBAAInvocationUsesFastqPBAAClusterCLI'
```

Expected: focused tests pass.

- [ ] **Step 7: Commit Task 5**

```bash
git add Sources/LungfishApp/Views/FASTQ/FASTQOperationsCatalog.swift \
        Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift \
        Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift \
        Sources/LungfishApp/Services/FASTQOperationCLIInvocationBuilder.swift \
        Sources/LungfishApp/Services/FASTQOperationPlanner.swift \
        Sources/LungfishApp/Services/FASTQOperationOutputImporter.swift \
        Tests/LungfishAppTests/FASTQOperationsCatalogTests.swift \
        Tests/LungfishAppTests/FASTQOperationDialogRoutingTests.swift \
        Tests/LungfishAppTests/FASTQOperationExecutionServiceTests.swift
git commit -m "Add pbAA to FASTQ clustering operations"
```

---

### Task 6: Remove pbAA Conda Plugin Pack

**Files:**
- Modify: `Sources/LungfishWorkflow/Conda/PluginPack.swift`
- Modify: `Sources/LungfishWorkflow/Conda/PluginPackStatusService.swift` if smoke-test helpers have pbAA-specific expectations.
- Modify tests that currently expect the Amplicon Genotyping pack.

- [ ] **Step 1: Add failing absence tests**

In `Tests/LungfishWorkflowTests/PluginPackRegistryTests.swift`, add:

```swift
func testAmpliconGenotypingPackIsNotBuiltIn() {
    XCTAssertNil(PluginPack.builtInPack(id: "amplicon-genotyping"))
    XCTAssertFalse(PluginPack.builtIn.contains { $0.id == "amplicon-genotyping" })
}
```

In `Tests/LungfishAppTests/PluginPackVisibilityTests.swift`, add:

```swift
func testPBAAIsNotShownAsPluginPack() {
    let visiblePackIDs = PluginPack.builtInReleaseVisible.map(\.id)
    XCTAssertFalse(visiblePackIDs.contains("amplicon-genotyping"))
}
```

- [ ] **Step 2: Run tests and confirm failure if pack is still present**

Run:

```bash
swift test --filter 'PluginPackRegistryTests|PluginPackVisibilityTests'
```

Expected: new tests fail while the pbAA pack is still registered.

- [ ] **Step 3: Remove pack registration**

Remove the `amplicon-genotyping` `PluginPack` entry from `PluginPack.builtIn` in `Sources/LungfishWorkflow/Conda/PluginPack.swift`. Remove pbAA-specific smoke test metadata from `PluginPackStatusService` only if it is reachable exclusively through the removed pack. Keep historical operation log rendering unchanged.

- [ ] **Step 4: Update existing tests that counted the old pack**

Adjust expected pack counts and pack ID lists in:

```text
Tests/LungfishAppTests/PluginPackVisibilityTests.swift
Tests/LungfishCLITests/CondaPacksCommandTests.swift
Tests/LungfishWorkflowTests/PluginPackRegistryTests.swift
```

Do not change unrelated experimental-pack expectations from previous work.

- [ ] **Step 5: Run plugin pack tests**

Run:

```bash
swift test --filter 'PluginPackRegistryTests|PluginPackVisibilityTests|CondaPacksCommandTests'
```

Expected: all targeted plugin-pack tests pass.

- [ ] **Step 6: Commit Task 6**

```bash
git add Sources/LungfishWorkflow/Conda/PluginPack.swift \
        Sources/LungfishWorkflow/Conda/PluginPackStatusService.swift \
        Tests/LungfishAppTests/PluginPackVisibilityTests.swift \
        Tests/LungfishCLITests/CondaPacksCommandTests.swift \
        Tests/LungfishWorkflowTests/PluginPackRegistryTests.swift
git commit -m "Remove pbAA conda plugin pack"
```

---

### Task 7: Add Optional Runtime Smoke And Final Verification

**Files:**
- Test: `Tests/LungfishCLITests/FastqPBAAClusterCommandTests.swift`
- No production file required unless the smoke exposes a runtime bug.

- [ ] **Step 1: Add a skipped runtime smoke test**

In `FastqPBAAClusterCommandTests`, add a test that exits early unless both `docker` and `nextflow` are available:

```swift
func testPBAAClusterRuntimeSmokeWhenDockerAndNextflowAreAvailable() async throws {
    try XCTSkipUnless(Self.executableExists("docker"), "Docker is not installed")
    try XCTSkipUnless(Self.executableExists("nextflow"), "Nextflow is not installed")
    try XCTSkipUnless(Self.commandSucceeds("docker", ["info"]), "Docker daemon is not running")

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pbaa-cli-smoke-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let guide = root.appendingPathComponent("guide.fasta")
    let reads = root.appendingPathComponent("reads.fastq")
    try ">guide1|target\nACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGT\n".write(to: guide, atomically: true, encoding: .utf8)
    try "@read1\nACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGT\n+\nIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII\n".write(to: reads, atomically: true, encoding: .utf8)

    let output = root.appendingPathComponent("out", isDirectory: true)
    let request = try PBAAClusteringRunRequest(
        inputFASTQURL: reads,
        guideSourceURL: guide,
        outputDirectory: output,
        outputName: "smoke",
        threads: 1,
        extraArgumentsText: "--min-read-qv 0 --min-cluster-read-count 1 --min-cluster-frequency 0.0 --max-reads-per-guide 1 --max-consensus-reads 1 --max-amplicon-size 1000"
    )

    let result = try await PBAAClusteringPipeline().run(request)
    XCTAssertEqual(result.referenceBundleURL.pathExtension, "lungfishref")
}
```

Add helper methods in the same test class:

```swift
private static func executableExists(_ name: String) -> Bool {
    (try? Process.run(URL(fileURLWithPath: "/usr/bin/env"), arguments: ["which", name])) != nil
}

private static func commandSucceeds(_ name: String, _ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [name] + arguments
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}
```

- [ ] **Step 2: Run focused test suite**

Run:

```bash
swift test --filter 'PBAA|FastqPBAACluster|FASTQOperationsCatalogTests|FASTQOperationDialogRoutingTests|PluginPackRegistryTests|PluginPackVisibilityTests|CondaPacksCommandTests'
```

Expected: all focused tests pass; runtime smoke may skip if Nextflow or Docker is unavailable.

- [ ] **Step 3: Run a broad build**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 4: Run a debug app build**

Run:

```bash
scripts/build-app.sh --configuration debug --log-dir build/logs
```

Expected: debug app build succeeds.

- [ ] **Step 5: Launch debug app for manual testing**

Run:

```bash
pkill -f '/build/Debug/Lungfish.app' || true
open /Users/dho/Documents/lungfish-genome-explorer/build/Debug/Lungfish.app
```

Expected: `/Users/dho/Documents/lungfish-genome-explorer/build/Debug/Lungfish.app` opens. In FASTQ Operations, `CLUSTERING` contains `pbAA Amplicon Clustering`, the main pane is simple, and advanced pbAA flags are in `Advanced Options`.

- [ ] **Step 6: Commit Task 7**

```bash
git add Tests/LungfishCLITests/FastqPBAAClusterCommandTests.swift
git commit -m "Verify pbAA clustering runtime smoke"
```

---

## Self-Review Checklist

- Spec coverage: tasks cover container pins, simple GUI, Advanced Options, Nextflow workflow generation, CLI command, FASTQ Operations routing, `.lungfishref` output, provenance, Operations Panel visibility through execution logs/artifacts, and pbAA plugin-pack removal.
- Testability: tasks isolate command construction and provenance contracts from Docker/Nextflow; runtime smoke skips when dependencies are unavailable.
- Risk focus: provenance and output import are tested before app routing is considered complete.
- Dirty worktree safety: every commit command stages explicit paths only.
