# Viral Recon Phase 1: Reference Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make MN908947.3 a hard-coded, automatically acquired reference bundle that Viral Recon hands to the pipeline, replacing the user-chosen reference.

**Architecture:** A new `ViralReconReferenceCatalog` holds the fixed accession as a constant. A new `ViralReconReferenceAcquisition` returns the project's `Downloads/MN908947.3.lungfishref` when it exists and otherwise downloads it by invoking the existing `lungfish-cli fetch genome` through `LungfishCLIRunner.run`, which already builds an indexed bundle with annotations. Both tracks consume this.

**Tech Stack:** Swift 6.2, SwiftPM, XCTest, `@MainActor` and strict concurrency, `LungfishCLIRunner` (in `LungfishKit`), `AdvancedCommandLineOptions` (in `LungfishWorkflow`).

**Spec:** `docs/superpowers/specs/2026-09-02-viral-recon-results-integration-design.md`

## Global Constraints

- Viral Recon is SARS-CoV-2 only. The reference is always MN908947.3.
- No reference is ever selected by the user, matched by accession, or substituted from another project bundle. A project holding only NC_045512.2 gets a download.
- Docker is the only supported executor. `conda` and `local` enum cases stay in the type for compatibility but are refused at launch.
- `skip_freyja` and `skip_freyja_boot` remain forced and unreachable from any user input.
- Build and test with `--package-path` and `--skip-update`. Never `-C`.
- SwiftPM holds one `.build/.lock` per checkout. Never run a swift command while another is running in this worktree.
- No em dashes in any prose, comment, or committed document.

---

### Task 1: Reference catalog constant

**Files:**
- Create: `Sources/LungfishWorkflow/ViralRecon/ViralReconReferenceCatalog.swift`
- Test: `Tests/LungfishWorkflowTests/ViralRecon/ViralReconReferenceCatalogTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ViralReconReferenceCatalog.canonicalAccession -> String`, `ViralReconReferenceCatalog.bundleFilename -> String`, `ViralReconReferenceCatalog.bundleURL(inProject: URL) -> URL`, `ViralReconReferenceCatalog.equivalentAccessions -> Set<String>`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LungfishWorkflow

final class ViralReconReferenceCatalogTests: XCTestCase {
    func testCanonicalAccessionIsMN908947_3() {
        XCTAssertEqual(ViralReconReferenceCatalog.canonicalAccession, "MN908947.3")
    }

    func testBundleFilenameMatchesAccession() {
        XCTAssertEqual(ViralReconReferenceCatalog.bundleFilename, "MN908947.3.lungfishref")
    }

    func testBundleURLIsInProjectDownloads() {
        let project = URL(fileURLWithPath: "/tmp/My Project.lungfish")
        let url = ViralReconReferenceCatalog.bundleURL(inProject: project)
        XCTAssertEqual(url.path, "/tmp/My Project.lungfish/Downloads/MN908947.3.lungfishref")
    }

    // NC_045512.2 is the same genome under a different accession. It is recorded
    // so callers can explain why it is refused, never so it can be substituted.
    func testEquivalentAccessionsAreRecordedButNotCanonical() {
        XCTAssertTrue(ViralReconReferenceCatalog.equivalentAccessions.contains("NC_045512.2"))
        XCTAssertFalse(ViralReconReferenceCatalog.equivalentAccessions.contains(
            ViralReconReferenceCatalog.canonicalAccession))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --skip-update --filter ViralReconReferenceCatalogTests`
Expected: FAIL, cannot find `ViralReconReferenceCatalog` in scope.

- [ ] **Step 3: Write minimal implementation**

```swift
// ViralReconReferenceCatalog.swift - The fixed SARS-CoV-2 reference for Viral Recon
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The reference Viral Recon always uses.
///
/// Viral Recon is a SARS-CoV-2 tool. Every bundled primer scheme declares that
/// organism and names MN908947.3 as canonical, so a primer scheme cannot apply
/// to any other genome. The reference is therefore fixed here rather than
/// chosen by the user or matched against project bundles.
public enum ViralReconReferenceCatalog {
    /// The only accession Viral Recon runs against.
    public static let canonicalAccession = "MN908947.3"

    /// Bundle directory name for the canonical accession.
    public static var bundleFilename: String { "\(canonicalAccession).lungfishref" }

    /// Where the canonical bundle lives inside a project.
    public static func bundleURL(inProject projectURL: URL) -> URL {
        projectURL
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(bundleFilename, isDirectory: true)
    }

    /// Accessions that are the same genome but carry a different sequence
    /// identifier. Recorded so a caller can explain why one is refused. These
    /// are never substituted for the canonical accession: the primer BED is
    /// written against MN908947.3, so an alignment against another identifier
    /// leaves the trimming step with nothing to match.
    public static let equivalentAccessions: Set<String> = ["NC_045512.2", "NC_045512"]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --skip-update --filter ViralReconReferenceCatalogTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/ViralRecon/ViralReconReferenceCatalog.swift Tests/LungfishWorkflowTests/ViralRecon/ViralReconReferenceCatalogTests.swift
git commit -m "Add the fixed SARS-CoV-2 reference catalog for Viral Recon"
```

---

### Task 2: Reference acquisition service

**Files:**
- Create: `Sources/LungfishWorkflow/ViralRecon/ViralReconReferenceAcquisition.swift`
- Test: `Tests/LungfishWorkflowTests/ViralRecon/ViralReconReferenceAcquisitionTests.swift`

**Interfaces:**
- Consumes: `ViralReconReferenceCatalog` from Task 1.
- Produces: `ViralReconReferenceAcquisition.Outcome` (enum with cases `alreadyPresent(URL)` and `downloaded(URL)`, each carrying the bundle URL), `ViralReconReferenceAcquisition.AcquisitionError`, and `ViralReconReferenceAcquisition.acquire(projectURL:downloader:fileManager:) throws -> Outcome`. The `downloader` is a closure `(String, URL) throws -> Void` taking accession and destination directory, so tests inject a stub and production injects the CLI call.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LungfishWorkflow

final class ViralReconReferenceAcquisitionTests: XCTestCase {
    private var projectURL: URL!

    override func setUpWithError() throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vr-ref-\(UUID().uuidString).lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    func testUsesExistingBundleWithoutDownloading() throws {
        let expected = ViralReconReferenceCatalog.bundleURL(inProject: projectURL)
        try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
        var downloadCalls = 0

        let outcome = try ViralReconReferenceAcquisition.acquire(
            projectURL: projectURL,
            downloader: { _, _ in downloadCalls += 1 }
        )

        XCTAssertEqual(outcome, .alreadyPresent(expected))
        XCTAssertEqual(downloadCalls, 0)
    }

    func testDownloadsWhenAbsent() throws {
        let expected = ViralReconReferenceCatalog.bundleURL(inProject: projectURL)
        var requested: [String] = []

        let outcome = try ViralReconReferenceAcquisition.acquire(
            projectURL: projectURL,
            downloader: { accession, destination in
                requested.append(accession)
                try FileManager.default.createDirectory(
                    at: destination.appendingPathComponent(ViralReconReferenceCatalog.bundleFilename,
                                                          isDirectory: true),
                    withIntermediateDirectories: true)
            }
        )

        XCTAssertEqual(outcome, .downloaded(expected))
        XCTAssertEqual(requested, ["MN908947.3"])
    }

    // A project holding only the equivalent accession must still download the
    // canonical one. Substituting it would leave the primer BED unmatched.
    func testEquivalentAccessionBundleIsNotSubstituted() throws {
        let equivalent = projectURL
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("NC_045512.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: equivalent, withIntermediateDirectories: true)
        var downloadCalls = 0

        let outcome = try ViralReconReferenceAcquisition.acquire(
            projectURL: projectURL,
            downloader: { _, destination in
                downloadCalls += 1
                try FileManager.default.createDirectory(
                    at: destination.appendingPathComponent(ViralReconReferenceCatalog.bundleFilename,
                                                          isDirectory: true),
                    withIntermediateDirectories: true)
            }
        )

        XCTAssertEqual(downloadCalls, 1)
        XCTAssertEqual(outcome, .downloaded(ViralReconReferenceCatalog.bundleURL(inProject: projectURL)))
    }

    func testDownloaderThatProducesNoBundleThrows() throws {
        XCTAssertThrowsError(
            try ViralReconReferenceAcquisition.acquire(
                projectURL: projectURL,
                downloader: { _, _ in }
            )
        ) { error in
            XCTAssertEqual(error as? ViralReconReferenceAcquisition.AcquisitionError,
                           .downloadProducedNoBundle(ViralReconReferenceCatalog.canonicalAccession))
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --skip-update --filter ViralReconReferenceAcquisitionTests`
Expected: FAIL, cannot find `ViralReconReferenceAcquisition` in scope.

- [ ] **Step 3: Write minimal implementation**

```swift
// ViralReconReferenceAcquisition.swift - Acquire the fixed Viral Recon reference
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Obtains the canonical SARS-CoV-2 reference bundle for a Viral Recon run.
///
/// There are exactly two outcomes: the project already holds
/// `Downloads/MN908947.3.lungfishref`, or it is downloaded. No other bundle in
/// the project is inspected, matched or substituted.
public enum ViralReconReferenceAcquisition {
    public enum Outcome: Equatable, Sendable {
        case alreadyPresent(URL)
        case downloaded(URL)

        /// The bundle to hand to the pipeline, whichever way it was obtained.
        public var bundleURL: URL {
            switch self {
            case .alreadyPresent(let url), .downloaded(let url): return url
            }
        }
    }

    public enum AcquisitionError: Error, LocalizedError, Equatable {
        case downloadProducedNoBundle(String)

        public var errorDescription: String? {
            switch self {
            case .downloadProducedNoBundle(let accession):
                return "Downloading \(accession) did not produce a reference bundle."
            }
        }
    }

    /// Downloads `accession` into `destinationDirectory`.
    public typealias Downloader = (_ accession: String, _ destinationDirectory: URL) throws -> Void

    public static func acquire(
        projectURL: URL,
        downloader: Downloader,
        fileManager: FileManager = .default
    ) throws -> Outcome {
        let bundleURL = ViralReconReferenceCatalog.bundleURL(inProject: projectURL)
        if fileManager.fileExists(atPath: bundleURL.path) {
            return .alreadyPresent(bundleURL)
        }

        let downloadsURL = bundleURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: downloadsURL, withIntermediateDirectories: true)
        try downloader(ViralReconReferenceCatalog.canonicalAccession, downloadsURL)

        guard fileManager.fileExists(atPath: bundleURL.path) else {
            throw AcquisitionError.downloadProducedNoBundle(
                ViralReconReferenceCatalog.canonicalAccession)
        }
        return .downloaded(bundleURL)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --skip-update --filter ViralReconReferenceAcquisitionTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/ViralRecon/ViralReconReferenceAcquisition.swift Tests/LungfishWorkflowTests/ViralRecon/ViralReconReferenceAcquisitionTests.swift
git commit -m "Acquire the Viral Recon reference, downloading it when absent"
```

---

### Task 3: Production downloader backed by the CLI

**Files:**
- Create: `Sources/LungfishApp/Services/ViralReconReferenceDownloader.swift`
- Test: `Tests/LungfishAppTests/ViralReconReferenceDownloaderTests.swift`

**Interfaces:**
- Consumes: `ViralReconReferenceAcquisition.Downloader` from Task 2, `LungfishCLIRunner.run(arguments:executableURL:cancellation:)` from `LungfishKit`.
- Produces: `ViralReconReferenceDownloader.arguments(accession:destinationDirectory:) -> [String]` and `ViralReconReferenceDownloader.live() -> ViralReconReferenceAcquisition.Downloader`.

The argument builder is separated from process execution so it can be tested without spawning the CLI.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LungfishApp

final class ViralReconReferenceDownloaderTests: XCTestCase {
    func testArgumentsInvokeFetchGenomeWithAccessionAndOutputDirectory() {
        let destination = URL(fileURLWithPath: "/tmp/My Project.lungfish/Downloads")

        let args = ViralReconReferenceDownloader.arguments(
            accession: "MN908947.3",
            destinationDirectory: destination)

        XCTAssertEqual(args.prefix(2).map(String.init), ["fetch", "genome"])
        XCTAssertTrue(args.contains("--accession"))
        XCTAssertTrue(args.contains("MN908947.3"))
        XCTAssertTrue(args.contains("--output-dir"))
        XCTAssertTrue(args.contains(destination.path))
    }

    func testArgumentsDoNotSuppressBundleCreation() {
        let args = ViralReconReferenceDownloader.arguments(
            accession: "MN908947.3",
            destinationDirectory: URL(fileURLWithPath: "/tmp/d"))

        // The bundle is the whole point of the download.
        XCTAssertFalse(args.contains("--no-bundle"))
        XCTAssertFalse(args.contains("--fasta-only"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --skip-update --filter ViralReconReferenceDownloaderTests`
Expected: FAIL, cannot find `ViralReconReferenceDownloader` in scope.

- [ ] **Step 3: Write minimal implementation**

```swift
// ViralReconReferenceDownloader.swift - CLI-backed reference download
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

/// Downloads the canonical Viral Recon reference through the CLI.
///
/// `lungfish-cli fetch genome` already retrieves the sequence and its GFF3
/// annotations and builds an indexed `.lungfishref`, so this wraps that rather
/// than reimplementing bundle construction.
enum ViralReconReferenceDownloader {
    static func arguments(accession: String, destinationDirectory: URL) -> [String] {
        [
            "fetch", "genome",
            "--accession", accession,
            "--output-dir", destinationDirectory.path,
            "--name", accession,
        ]
    }

    static func live() -> ViralReconReferenceAcquisition.Downloader {
        { accession, destinationDirectory in
            _ = try LungfishCLIRunner.run(
                arguments: arguments(accession: accession,
                                     destinationDirectory: destinationDirectory))
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --skip-update --filter ViralReconReferenceDownloaderTests`
Expected: PASS, 2 tests.

- [ ] **Step 5: Verify the CLI actually accepts these arguments**

Run: `swift build --package-path . --skip-update --product lungfish-cli && .build/debug/lungfish-cli fetch genome --help`
Expected: help text listing `--accession`, `--output-dir` and `--name`. If any flag name differs, correct `arguments(accession:destinationDirectory:)` and its test to match the real interface rather than assuming.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Services/ViralReconReferenceDownloader.swift Tests/LungfishAppTests/ViralReconReferenceDownloaderTests.swift
git commit -m "Back Viral Recon reference download with the fetch genome CLI"
```

---

### Task 4: Refuse unsupported executors at launch

**Files:**
- Modify: `Sources/LungfishWorkflow/nf-core/NFCoreRunRequest.swift`
- Test: `Tests/LungfishWorkflowTests/NFCoreRunRequestTests.swift`

**Interfaces:**
- Consumes: `NFCoreExecutor` from `NFCoreRunBundleManifest.swift`.
- Produces: `NFCoreRunRequest.UnsupportedExecutorError` and a `validateExecutorSupported()` method that throws for `.conda` and `.local`.

The enum cases stay. Four existing tests assert those values and saved run bundles may record them, so deleting the cases would break decoding of existing data.

- [ ] **Step 1: Write the failing test**

Append to `Tests/LungfishWorkflowTests/NFCoreRunRequestTests.swift`:

```swift
    func testCondaAndLocalExecutorsAreRefused() throws {
        // viralrecon 3.0.0 defines no `local` profile at all, and Lungfish never
        // enables Nextflow's conda support for this workflow, so both abort
        // after the user has waited. Refuse them at the point of launch instead.
        for executor in [NFCoreExecutor.conda, NFCoreExecutor.local] {
            let workflow = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "viralrecon"))
            let request = NFCoreRunRequest(
                workflow: workflow,
                version: "3.0.0",
                executor: executor,
                inputURLs: [URL(fileURLWithPath: "/tmp/samplesheet.csv")],
                outputDirectory: URL(fileURLWithPath: "/tmp/results"),
                params: [:]
            )
            XCTAssertThrowsError(try request.validateExecutorSupported()) { error in
                XCTAssertEqual(error as? NFCoreRunRequest.UnsupportedExecutorError,
                               .unsupported(executor))
            }
        }
    }

    func testDockerExecutorIsAccepted() throws {
        let workflow = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "viralrecon"))
        let request = NFCoreRunRequest(
            workflow: workflow,
            version: "3.0.0",
            executor: .docker,
            inputURLs: [URL(fileURLWithPath: "/tmp/samplesheet.csv")],
            outputDirectory: URL(fileURLWithPath: "/tmp/results"),
            params: [:]
        )
        XCTAssertNoThrow(try request.validateExecutorSupported())
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --skip-update --filter NFCoreRunRequestTests`
Expected: FAIL, value of type `NFCoreRunRequest` has no member `validateExecutorSupported`.

- [ ] **Step 3: Write minimal implementation**

Add to `NFCoreRunRequest`:

```swift
    /// Executors that reach a working pipeline run.
    ///
    /// Only Docker does. The executor is passed straight through as
    /// `-profile`, and viralrecon 3.0.0 defines no `local` profile, so that
    /// value aborts before any work happens. `conda` names a real profile but
    /// Lungfish never enables Nextflow's conda support for this workflow, so it
    /// can only succeed by accident on a user-provisioned machine.
    ///
    /// The cases remain in `NFCoreExecutor` because saved run bundles may record
    /// them and removing the cases would break decoding.
    public enum UnsupportedExecutorError: Error, LocalizedError, Equatable {
        case unsupported(NFCoreExecutor)

        public var errorDescription: String? {
            switch self {
            case .unsupported(let executor):
                return "The \(executor.rawValue) executor is not supported. Use Docker."
            }
        }
    }

    public func validateExecutorSupported() throws {
        guard executor == .docker else {
            throw UnsupportedExecutorError.unsupported(executor)
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --skip-update --filter NFCoreRunRequestTests`
Expected: PASS. The four pre-existing tests asserting `.conda` and `.local` values must still pass, because the cases were not removed.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/nf-core/NFCoreRunRequest.swift Tests/LungfishWorkflowTests/NFCoreRunRequestTests.swift
git commit -m "Refuse the conda and local executors instead of failing mid-run"
```

---

### Task 5: Turn the advanced-parameter reject list into an override list

**Files:**
- Modify: `Sources/LungfishWorkflow/ViralRecon/ViralReconRunRequest.swift` (`validateAdvancedParams`, currently near line 225)
- Test: `Tests/LungfishWorkflowTests/ViralRecon/ViralReconRunRequestTests.swift`

**Interfaces:**
- Consumes: `ViralReconSkipOption` and `ViralReconRunRequest.ValidationError` from the same file.
- Produces: unchanged signature `ViralReconRunRequest.validateAdvancedParams(_:) throws`, with new behaviour. Adds `ViralReconRunRequest.overridableAdvancedKeys -> Set<String>` and `ViralReconRunRequest.structuralAdvancedKeys -> Set<String>`.

Today the method throws on every `skip_*` key plus `variant_caller`, `consensus_caller` and `min_mapped_reads`. Those are exactly the keys the advanced field exists to reach, so the escape hatch cannot currently work. Structural keys the wizard owns, and the two forced Freyja skips, stay refused.

- [ ] **Step 1: Write the failing test**

Append to `Tests/LungfishWorkflowTests/ViralRecon/ViralReconRunRequestTests.swift`:

```swift
    func testTuningKeysAreAcceptedAsOverrides() throws {
        for key in ["variant_caller", "consensus_caller", "min_mapped_reads",
                    "skip_assembly", "skip_kraken2", "skip_fastqc"] {
            XCTAssertNoThrow(
                try ViralReconRunRequest.validateAdvancedParams([key: "true"]),
                "expected \(key) to be overridable")
        }
    }

    func testStructuralKeysRemainRefused() throws {
        for key in ["input", "outdir", "platform", "protocol", "primer_bed",
                    "primer_fasta", "genome", "fasta"] {
            XCTAssertThrowsError(
                try ViralReconRunRequest.validateAdvancedParams([key: "x"]),
                "expected \(key) to be refused") { error in
                XCTAssertEqual(error as? ViralReconRunRequest.ValidationError,
                               .conflictingAdvancedParam(key))
            }
        }
    }

    func testForcedFreyjaSkipsRemainRefused() throws {
        // These are forced because viralrecon pins Freyja to an amd64-only
        // container whose bootstrap workers are killed under Rosetta. No user
        // input may re-enable them.
        for key in ["skip_freyja", "skip_freyja_boot"] {
            XCTAssertThrowsError(
                try ViralReconRunRequest.validateAdvancedParams([key: "false"])) { error in
                XCTAssertEqual(error as? ViralReconRunRequest.ValidationError,
                               .conflictingAdvancedParam(key))
            }
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --skip-update --filter ViralReconRunRequestTests`
Expected: FAIL on `testTuningKeysAreAcceptedAsOverrides`, because every listed key currently throws.

- [ ] **Step 3: Write minimal implementation**

Replace the body of `validateAdvancedParams` and add the two key sets:

```swift
    /// Keys an advanced user may override. These change how the pipeline runs
    /// without changing what the wizard is describing.
    public static var overridableAdvancedKeys: Set<String> {
        var keys: Set<String> = ["variant_caller", "consensus_caller", "min_mapped_reads",
                                 "max_cpus", "max_memory"]
        for option in ViralReconSkipOption.allCases
        where !ViralReconSkipOption.alwaysSkipped.contains(option) {
            keys.insert(option.rawValue)
        }
        return keys
    }

    /// Keys the wizard owns. Overriding these would contradict the inputs the
    /// user selected, so they are refused with the owning control named.
    public static var structuralAdvancedKeys: Set<String> {
        var keys: Set<String> = ["input", "outdir", "platform", "protocol",
                                 "primer_bed", "primer_fasta", "primer_left_suffix",
                                 "primer_right_suffix", "genome", "fasta", "gff",
                                 "fastq_dir", "sequencing_summary"]
        for option in ViralReconSkipOption.alwaysSkipped {
            keys.insert(option.rawValue)
        }
        return keys
    }

    public static func validateAdvancedParams(_ params: [String: String]) throws {
        for key in params.keys.sorted() where structuralAdvancedKeys.contains(key) {
            throw ValidationError.conflictingAdvancedParam(key)
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --skip-update --filter ViralReconRunRequestTests`
Expected: PASS. The pre-existing `testAdvancedParamsRejectGeneratedKeys` must still pass, since `input` remains structural.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/ViralRecon/ViralReconRunRequest.swift Tests/LungfishWorkflowTests/ViralRecon/ViralReconRunRequestTests.swift
git commit -m "Let advanced parameters override tuning keys, keep structural keys refused"
```

---

### Task 6: Phase gate

- [ ] **Step 1: Run the unit tier**

Run: `bash scripts/full-suite-gate.sh --tier unit`
Expected: `GATE PASS`. Flaky classes that pass on isolated serial retry are acceptable, as the script reports.

- [ ] **Step 2: Confirm no regression in the four pre-existing executor tests**

Run: `swift test --package-path . --skip-update --filter 'NFCoreRunRequestTests|NFCoreRunBundleManifestTests|CLIRegressionTests'`
Expected: PASS. These assert `.conda` and `.local` values and prove the enum cases survived.

- [ ] **Step 3: Commit any gate fixes**

```bash
git add -A
git commit -m "Phase 1 gate: reference foundation"
```
