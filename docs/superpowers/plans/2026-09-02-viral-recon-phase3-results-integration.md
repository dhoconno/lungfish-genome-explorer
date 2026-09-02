# Viral Recon Phase 3: Results Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a finished Viral Recon run into a sidebar bundle whose reference bundle carries the alignment, the variants and the consensus as layered tracks, with the remaining outputs catalogued in the Inspector.

**Architecture:** A new `ViralReconResultIngest` reads the nf-core output directory and assembles an analysis bundle in the shape `SidebarProjectScanner` already recognises. Alignment and variant registration reuse `MappingViewerBundlePublicationService`. The consensus becomes a track through a VCF-derived coordinate map, never by positional index.

**Tech Stack:** Swift 6.2, SwiftPM, XCTest, `MappingViewerBundlePublicationService`, `AnalysesFolder`.

**Spec:** `docs/superpowers/specs/2026-09-02-viral-recon-results-integration-design.md`

**Depends on:** `2026-09-02-viral-recon-phase1-reference-foundation.md` Tasks 1 to 3 complete.

## Global Constraints

- The reference bundle is the hard-coded MN908947.3 bundle from Phase 1. Ingest never sources a reference from the results directory or a Nextflow cache.
- The consensus is 3 bases shorter than the reference in the reference dataset. Never assume positional identity between them.
- Ingest failure must not present as a lost analysis. The run stays reported as completed and the raw output is left intact.
- Multi-sample runs use `AnalysesFolder.createAnalysisDirectory(tool:in:isBatch:)` with `isBatch: true`, one sanitized subdirectory per sample.
- Build and test with `--package-path` and `--skip-update`. Never `-C`.
- SwiftPM holds one `.build/.lock` per checkout. Never run a swift command while another is running in this worktree.
- No em dashes in any prose, comment, or committed document.

---

### Task 1: Discover outputs in an nf-core results directory

**Files:**
- Create: `Sources/LungfishWorkflow/ViralRecon/ViralReconResultInventory.swift`
- Test: `Tests/LungfishWorkflowTests/ViralRecon/ViralReconResultInventoryTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ViralReconResultInventory` struct with `sampleName: String`, `sortedBAM: URL?`, `bamIndex: URL?`, `variantVCF: URL?`, `consensusFASTA: URL?`, `lineageFiles: [URL]`, `reportFiles: [URL]`; and `ViralReconResultInventory.discover(in resultsDirectory: URL, sampleName: String) -> ViralReconResultInventory`.

Paths are taken from the layout the pipeline actually produces, verified against a real run: `variants/bowtie2/<sample>.sorted.bam`, `variants/ivar/<sample>.vcf.gz`, `variants/ivar/consensus/bcftools/<sample>.consensus.fa`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LungfishWorkflow

final class ViralReconResultInventoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vr-inv-\(UUID().uuidString)", isDirectory: true)
        try makeFile("variants/bowtie2/S1.sorted.bam")
        try makeFile("variants/bowtie2/S1.sorted.bam.bai")
        try makeFile("variants/ivar/S1.vcf.gz")
        try makeFile("variants/ivar/consensus/bcftools/S1.consensus.fa")
        try makeFile("variants/ivar/consensus/bcftools/pangolin/S1.pangolin.csv")
        try makeFile("variants/ivar/consensus/bcftools/nextclade/S1.csv")
        try makeFile("multiqc/multiqc_report.html")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFile(_ relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    func testFindsAlignmentVariantsAndConsensus() {
        let inventory = ViralReconResultInventory.discover(in: root, sampleName: "S1")
        XCTAssertEqual(inventory.sortedBAM?.lastPathComponent, "S1.sorted.bam")
        XCTAssertEqual(inventory.bamIndex?.lastPathComponent, "S1.sorted.bam.bai")
        XCTAssertEqual(inventory.variantVCF?.lastPathComponent, "S1.vcf.gz")
        XCTAssertEqual(inventory.consensusFASTA?.lastPathComponent, "S1.consensus.fa")
    }

    func testCollectsLineageAndReportFiles() {
        let inventory = ViralReconResultInventory.discover(in: root, sampleName: "S1")
        XCTAssertTrue(inventory.lineageFiles.contains { $0.lastPathComponent == "S1.pangolin.csv" })
        XCTAssertTrue(inventory.reportFiles.contains { $0.lastPathComponent == "multiqc_report.html" })
    }

    func testMissingOutputsAreNilRatherThanFatal() throws {
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let inventory = ViralReconResultInventory.discover(in: empty, sampleName: "S1")
        XCTAssertNil(inventory.sortedBAM)
        XCTAssertNil(inventory.variantVCF)
        XCTAssertTrue(inventory.lineageFiles.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --skip-update --filter ViralReconResultInventoryTests`
Expected: FAIL, cannot find `ViralReconResultInventory` in scope.

- [ ] **Step 3: Write minimal implementation**

```swift
// ViralReconResultInventory.swift - Locate outputs in an nf-core results tree
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The outputs of one sample in a Viral Recon results directory.
///
/// Every field is optional because a pipeline can complete with a step skipped
/// or failed. A missing output is a reduced result, not a fatal condition.
public struct ViralReconResultInventory: Sendable, Equatable {
    public let sampleName: String
    public let sortedBAM: URL?
    public let bamIndex: URL?
    public let variantVCF: URL?
    public let consensusFASTA: URL?
    public let lineageFiles: [URL]
    public let reportFiles: [URL]

    public static func discover(in resultsDirectory: URL, sampleName: String) -> ViralReconResultInventory {
        let fileManager = FileManager.default
        func existing(_ relative: String) -> URL? {
            let url = resultsDirectory.appendingPathComponent(relative)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }

        let bam = existing("variants/bowtie2/\(sampleName).sorted.bam")
        let bai = existing("variants/bowtie2/\(sampleName).sorted.bam.bai")
        let vcf = existing("variants/ivar/\(sampleName).vcf.gz")
        let consensusRoot = "variants/ivar/consensus/bcftools"
        let consensus = existing("\(consensusRoot)/\(sampleName).consensus.fa")

        var lineage: [URL] = []
        for relative in ["\(consensusRoot)/pangolin", "\(consensusRoot)/nextclade", "variants/freyja/demix"] {
            let directory = resultsDirectory.appendingPathComponent(relative, isDirectory: true)
            let contents = (try? fileManager.contentsOfDirectory(at: directory,
                                                                includingPropertiesForKeys: nil)) ?? []
            lineage.append(contentsOf: contents.filter { !$0.hasDirectoryPath })
        }

        var reports: [URL] = []
        for relative in ["multiqc/multiqc_report.html", "fastp/\(sampleName).fastp.html"] {
            if let url = existing(relative) { reports.append(url) }
        }

        return ViralReconResultInventory(
            sampleName: sampleName,
            sortedBAM: bam,
            bamIndex: bai,
            variantVCF: vcf,
            consensusFASTA: consensus,
            lineageFiles: lineage.sorted { $0.path < $1.path },
            reportFiles: reports)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --skip-update --filter ViralReconResultInventoryTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/ViralRecon/ViralReconResultInventory.swift Tests/LungfishWorkflowTests/ViralRecon/ViralReconResultInventoryTests.swift
git commit -m "Locate Viral Recon outputs in an nf-core results directory"
```

---

### Task 2: Reference-to-consensus coordinate map

**Files:**
- Create: `Sources/LungfishWorkflow/ViralRecon/ConsensusCoordinateMap.swift`
- Test: `Tests/LungfishWorkflowTests/ViralRecon/ConsensusCoordinateMapTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ConsensusCoordinateMap.Indel` struct (`position: Int`, `referenceLength: Int`, `alternateLength: Int`), `ConsensusCoordinateMap.init(indels: [Indel])`, and `ConsensusCoordinateMap.consensusPosition(forReference position: Int) -> Int?`.

This is the task most likely to ship a display that lies. The reference dataset's consensus is 29,900 bases against a 29,903 base reference because of indels including `AATT` to `A` at position 20,297. Positional identity would mis-place every feature after that point.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LungfishWorkflow

final class ConsensusCoordinateMapTests: XCTestCase {
    func testIdentityWhenNoIndels() {
        let map = ConsensusCoordinateMap(indels: [])
        XCTAssertEqual(map.consensusPosition(forReference: 1), 1)
        XCTAssertEqual(map.consensusPosition(forReference: 29_903), 29_903)
    }

    func testPositionsBeforeAnIndelAreUnshifted() {
        let map = ConsensusCoordinateMap(indels: [
            .init(position: 20_297, referenceLength: 4, alternateLength: 1)
        ])
        XCTAssertEqual(map.consensusPosition(forReference: 100), 100)
        XCTAssertEqual(map.consensusPosition(forReference: 20_297), 20_297)
    }

    // The real deletion from the reference dataset: AATT -> A at 20,297 removes
    // three bases, so everything after it shifts back by three.
    func testPositionsAfterADeletionShiftBack() {
        let map = ConsensusCoordinateMap(indels: [
            .init(position: 20_297, referenceLength: 4, alternateLength: 1)
        ])
        XCTAssertEqual(map.consensusPosition(forReference: 20_301), 20_298)
        XCTAssertEqual(map.consensusPosition(forReference: 29_903), 29_900)
    }

    func testDeletedBasesHaveNoConsensusPosition() {
        let map = ConsensusCoordinateMap(indels: [
            .init(position: 20_297, referenceLength: 4, alternateLength: 1)
        ])
        XCTAssertNil(map.consensusPosition(forReference: 20_298))
        XCTAssertNil(map.consensusPosition(forReference: 20_300))
    }

    func testInsertionShiftsForward() {
        let map = ConsensusCoordinateMap(indels: [
            .init(position: 100, referenceLength: 1, alternateLength: 3)
        ])
        XCTAssertEqual(map.consensusPosition(forReference: 101), 103)
    }

    func testMultipleIndelsAccumulate() {
        let map = ConsensusCoordinateMap(indels: [
            .init(position: 100, referenceLength: 4, alternateLength: 1),
            .init(position: 200, referenceLength: 4, alternateLength: 1),
        ])
        XCTAssertEqual(map.consensusPosition(forReference: 300), 294)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --skip-update --filter ConsensusCoordinateMapTests`
Expected: FAIL, cannot find `ConsensusCoordinateMap` in scope.

- [ ] **Step 3: Write minimal implementation**

```swift
// ConsensusCoordinateMap.swift - Map reference positions onto consensus positions
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Translates reference coordinates into consensus coordinates.
///
/// The consensus is not the same length as the reference: applying indels
/// changes it. In the reference dataset the consensus is 29,900 bases against a
/// 29,903 base reference. Laying one over the other by index would drift after
/// the first indel and mis-place every downstream feature, so every position is
/// translated through the indels the variant caller applied.
public struct ConsensusCoordinateMap: Sendable, Equatable {
    public struct Indel: Sendable, Equatable {
        public let position: Int
        public let referenceLength: Int
        public let alternateLength: Int

        public init(position: Int, referenceLength: Int, alternateLength: Int) {
            self.position = position
            self.referenceLength = referenceLength
            self.alternateLength = alternateLength
        }

        /// Bases gained (positive) or lost (negative) at this site.
        var lengthDelta: Int { alternateLength - referenceLength }

        /// Reference positions consumed but not represented in the consensus.
        /// For `AATT` to `A` at p, the anchor base p survives and p+1 through
        /// p+3 are deleted.
        var deletedReferenceRange: ClosedRange<Int>? {
            guard lengthDelta < 0 else { return nil }
            return (position + alternateLength)...(position + referenceLength - 1)
        }
    }

    private let indels: [Indel]

    public init(indels: [Indel]) {
        self.indels = indels.sorted { $0.position < $1.position }
    }

    /// The consensus position for a reference position, or nil when the base
    /// was deleted and therefore has no consensus counterpart.
    public func consensusPosition(forReference position: Int) -> Int? {
        var shift = 0
        for indel in indels {
            if let deleted = indel.deletedReferenceRange, deleted.contains(position) {
                return nil
            }
            if indel.position < position {
                shift += indel.lengthDelta
            }
        }
        return position + shift
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --skip-update --filter ConsensusCoordinateMapTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/ViralRecon/ConsensusCoordinateMap.swift Tests/LungfishWorkflowTests/ViralRecon/ConsensusCoordinateMapTests.swift
git commit -m "Map reference coordinates onto consensus coordinates through indels"
```

---

### Task 3: Build indels from a VCF

**Files:**
- Modify: `Sources/LungfishWorkflow/ViralRecon/ConsensusCoordinateMap.swift`
- Test: `Tests/LungfishWorkflowTests/ViralRecon/ConsensusCoordinateMapTests.swift`

**Interfaces:**
- Consumes: `ConsensusCoordinateMap.Indel` from Task 2.
- Produces: `ConsensusCoordinateMap.indels(fromVCFLines lines: [String]) -> [Indel]`.

Parsing takes lines rather than a URL so the test needs no gzip fixture. The caller decompresses.

- [ ] **Step 1: Write the failing test**

Append:

```swift
    func testBuildsIndelsFromVCFLinesIgnoringSubstitutionsAndHeaders() {
        let lines = [
            "##fileformat=VCFv4.2",
            "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO",
            "MN908947.3\t17373\t.\tC\tT\t.\tPASS\t.",
            "MN908947.3\t20297\t.\tAATT\tA\t.\tPASS\t.",
        ]

        let indels = ConsensusCoordinateMap.indels(fromVCFLines: lines)

        XCTAssertEqual(indels.count, 1, "a substitution is not an indel")
        XCTAssertEqual(indels.first?.position, 20_297)
        XCTAssertEqual(indels.first?.referenceLength, 4)
        XCTAssertEqual(indels.first?.alternateLength, 1)
    }

    func testMultiAllelicAlternateUsesFirstAllele() {
        let lines = ["MN908947.3\t500\t.\tAAA\tA,AA\t.\tPASS\t."]
        let indels = ConsensusCoordinateMap.indels(fromVCFLines: lines)
        XCTAssertEqual(indels.first?.alternateLength, 1)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --skip-update --filter ConsensusCoordinateMapTests`
Expected: FAIL, no member `indels(fromVCFLines:)`.

- [ ] **Step 3: Write minimal implementation**

Add to `ConsensusCoordinateMap`:

```swift
    /// Extracts length-changing variants from VCF body lines.
    ///
    /// Substitutions leave the coordinate system alone and are ignored. Only
    /// indels shift downstream positions.
    public static func indels(fromVCFLines lines: [String]) -> [Indel] {
        var result: [Indel] = []
        for line in lines {
            guard !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 5, let position = Int(fields[1]) else { continue }
            let reference = String(fields[3])
            guard let firstAlternate = fields[4].split(separator: ",").first else { continue }
            let alternate = String(firstAlternate)
            guard reference.count != alternate.count else { continue }
            result.append(Indel(position: position,
                                referenceLength: reference.count,
                                alternateLength: alternate.count))
        }
        return result
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --skip-update --filter ConsensusCoordinateMapTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/ViralRecon/ConsensusCoordinateMap.swift Tests/LungfishWorkflowTests/ViralRecon/ConsensusCoordinateMapTests.swift
git commit -m "Build consensus coordinate indels from VCF records"
```

---

### Task 4: Assemble the analysis bundle

**Files:**
- Create: `Sources/LungfishWorkflow/ViralRecon/ViralReconResultIngest.swift`
- Test: `Tests/LungfishWorkflowTests/ViralRecon/ViralReconResultIngestTests.swift`

**Interfaces:**
- Consumes: `ViralReconResultInventory` (Task 1), `ViralReconReferenceCatalog` (Phase 1 Task 1).
- Produces: `ViralReconResultIngest.Ingested` struct (`bundleDirectory: URL`, `referenceBundleURL: URL`, `inventory: ViralReconResultInventory`), `ViralReconResultIngest.IngestError`, and `ViralReconResultIngest.ingest(resultsDirectory:sampleName:referenceBundleURL:into:fileManager:) throws -> Ingested`.

This task assembles the directory and copies the reference bundle in. Alignment and variant registration is Task 5.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LungfishWorkflow

final class ViralReconResultIngestTests: XCTestCase {
    private var root: URL!
    private var results: URL!
    private var referenceBundle: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vr-ingest-\(UUID().uuidString)", isDirectory: true)
        results = root.appendingPathComponent("results", isDirectory: true)
        referenceBundle = root.appendingPathComponent("MN908947.3.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceBundle, withIntermediateDirectories: true)
        try Data().write(to: referenceBundle.appendingPathComponent("manifest.json"))
        for relative in ["variants/bowtie2/S1.sorted.bam",
                         "variants/bowtie2/S1.sorted.bam.bai",
                         "variants/ivar/S1.vcf.gz",
                         "variants/ivar/consensus/bcftools/S1.consensus.fa"] {
            let url = results.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data().write(to: url)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCreatesBundleContainingReferenceAndPreservesRawOutput() throws {
        let destination = root.appendingPathComponent("Analyses/Viral Recon", isDirectory: true)

        let ingested = try ViralReconResultIngest.ingest(
            resultsDirectory: results,
            sampleName: "S1",
            referenceBundleURL: referenceBundle,
            into: destination)

        let fileManager = FileManager.default
        XCTAssertTrue(fileManager.fileExists(atPath: ingested.referenceBundleURL.path))
        XCTAssertEqual(ingested.referenceBundleURL.lastPathComponent, "MN908947.3.lungfishref")
        // Raw nf-core output is preserved, not moved.
        XCTAssertTrue(fileManager.fileExists(
            atPath: results.appendingPathComponent("variants/bowtie2/S1.sorted.bam").path))
    }

    func testWritesAnalysisMetadataIdentifyingTheTool() throws {
        let destination = root.appendingPathComponent("Analyses/Viral Recon", isDirectory: true)
        let ingested = try ViralReconResultIngest.ingest(
            resultsDirectory: results, sampleName: "S1",
            referenceBundleURL: referenceBundle, into: destination)

        let metadataURL = ingested.bundleDirectory.appendingPathComponent("analysis-metadata.json")
        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: metadataURL)) as? [String: Any]
        XCTAssertEqual(json?["tool"] as? String, "viralrecon")
    }

    func testMissingReferenceBundleThrows() {
        let destination = root.appendingPathComponent("Analyses/Viral Recon", isDirectory: true)
        XCTAssertThrowsError(
            try ViralReconResultIngest.ingest(
                resultsDirectory: results, sampleName: "S1",
                referenceBundleURL: root.appendingPathComponent("absent.lungfishref"),
                into: destination)
        ) { error in
            XCTAssertEqual(error as? ViralReconResultIngest.IngestError, .referenceBundleMissing)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --skip-update --filter ViralReconResultIngestTests`
Expected: FAIL, cannot find `ViralReconResultIngest` in scope.

- [ ] **Step 3: Write minimal implementation**

```swift
// ViralReconResultIngest.swift - Assemble a viewable bundle from a finished run
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Builds the analysis bundle the sidebar and viewport consume.
///
/// The raw nf-core output is preserved rather than moved, so provenance stays
/// verifiable against what the pipeline actually wrote.
public enum ViralReconResultIngest {
    public struct Ingested: Sendable, Equatable {
        public let bundleDirectory: URL
        public let referenceBundleURL: URL
        public let inventory: ViralReconResultInventory
    }

    public enum IngestError: Error, LocalizedError, Equatable {
        case referenceBundleMissing

        public var errorDescription: String? {
            switch self {
            case .referenceBundleMissing:
                return "The Viral Recon reference bundle is missing."
            }
        }
    }

    public static func ingest(
        resultsDirectory: URL,
        sampleName: String,
        referenceBundleURL: URL,
        into bundleDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> Ingested {
        guard fileManager.fileExists(atPath: referenceBundleURL.path) else {
            throw IngestError.referenceBundleMissing
        }

        try fileManager.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)

        let destinationReference = bundleDirectory
            .appendingPathComponent(referenceBundleURL.lastPathComponent, isDirectory: true)
        if !fileManager.fileExists(atPath: destinationReference.path) {
            try fileManager.copyItem(at: referenceBundleURL, to: destinationReference)
        }

        let metadata: [String: Any] = [
            "tool": "viralrecon",
            "isBatch": false,
            "created": ISO8601DateFormatter().string(from: Date()),
        ]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: bundleDirectory.appendingPathComponent("analysis-metadata.json"))

        let inventory = ViralReconResultInventory.discover(in: resultsDirectory,
                                                          sampleName: sampleName)
        return Ingested(bundleDirectory: bundleDirectory,
                        referenceBundleURL: destinationReference,
                        inventory: inventory)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --skip-update --filter ViralReconResultIngestTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/ViralRecon/ViralReconResultIngest.swift Tests/LungfishWorkflowTests/ViralRecon/ViralReconResultIngestTests.swift
git commit -m "Assemble a Viral Recon analysis bundle from a finished run"
```

---

### Task 5: Register alignment and variants into the reference bundle

**Files:**
- Create: `Sources/LungfishApp/Services/ViralReconViewerPublication.swift`
- Test: `Tests/LungfishAppTests/ViralReconViewerPublicationTests.swift`

**Interfaces:**
- Consumes: `ViralReconResultIngest.Ingested` (Task 4), `MappingViewerBundlePublicationService`.
- Produces: `ViralReconViewerPublication.publish(ingested:) throws -> URL` returning the reference bundle URL whose manifest now registers the alignment and the variant track.

Read `MappingViewerBundlePublicationService` before writing this. It already publishes alignments and variants into a reference bundle manifest and handles index paths and sidecar databases. Add a Viral Recon caller for it. Do not write a second publication path.

- [ ] **Step 1: Read the existing service**

Run: `grep -n 'func publish\|manifest.alignments\|manifest.variants' Sources/LungfishApp/Services/MappingViewerBundlePublicationService.swift | head -20`

Record the entry point signature before writing the test, and shape the test around the real API rather than an assumed one.

- [ ] **Step 2: Write the failing test**

Write a test asserting that after `publish(ingested:)`, the reference bundle's `manifest.json` contains one alignment entry whose `source_path` ends in `.sorted.bam` and one variant entry whose path ends in `.vcf.gz`. Build the fixture the same way `ViralReconResultIngestTests` does. Use the real manifest type the service consumes rather than hand-written JSON if one exists.

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --package-path . --skip-update --filter ViralReconViewerPublicationTests`
Expected: FAIL, cannot find `ViralReconViewerPublication` in scope.

- [ ] **Step 4: Implement using the existing service**

Call `MappingViewerBundlePublicationService` with the alignment and variant paths from the inventory. If the service's entry point requires a mapping-specific request type, construct it. If it cannot be reused without modification, stop and report that finding rather than duplicating the publication logic.

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --package-path . --skip-update --filter ViralReconViewerPublicationTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Services/ViralReconViewerPublication.swift Tests/LungfishAppTests/ViralReconViewerPublicationTests.swift
git commit -m "Register the Viral Recon alignment and variants for the viewport"
```

---

### Task 6: Ingest failure leaves the run intact

**Files:**
- Modify: `Sources/LungfishApp/Services/ViralReconWorkflowExecutionService.swift`
- Test: `Tests/LungfishAppTests/ViralReconWorkflowExecutionServiceTests.swift`

**Interfaces:**
- Consumes: `ViralReconResultIngest`, `ViralReconViewerPublication`.
- Produces: no new public type. The completion path gains ingest, wrapped so failure is recorded and not propagated as run failure.

A visualisation problem must never present as a lost analysis.

- [ ] **Step 1: Write the failing test**

Write a test that runs the completion path with an ingest step that throws, and asserts the run is still reported completed, the raw results directory still exists with its files, and the failure reason is recorded for the Inspector.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --skip-update --filter ViralReconWorkflowExecutionServiceTests`
Expected: FAIL.

- [ ] **Step 3: Implement**

Wrap the ingest call so a thrown error is captured into the run record rather than rethrown, and log it through `OperationCenter.shared.log()` as well as `update()`, per the project rule that pipeline operations do both.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --skip-update --filter ViralReconWorkflowExecutionServiceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Services/ViralReconWorkflowExecutionService.swift Tests/LungfishAppTests/ViralReconWorkflowExecutionServiceTests.swift
git commit -m "Keep a Viral Recon run intact when results ingest fails"
```

---

### Task 7: Multi-sample batch layout

**Files:**
- Modify: `Sources/LungfishWorkflow/ViralRecon/ViralReconResultIngest.swift`
- Test: `Tests/LungfishWorkflowTests/ViralRecon/ViralReconResultIngestTests.swift`

**Interfaces:**
- Consumes: `AnalysesFolder.createAnalysisDirectory(tool:in:isBatch:date:)`.
- Produces: `ViralReconResultIngest.ingestBatch(resultsDirectory:sampleNames:referenceBundleURL:projectURL:) throws -> [Ingested]`.

Samples run one per sample on the contract other batch tools already use. `SidebarProjectScanner` already renders batch nodes, so no new node type is needed. The reference is acquired once for the batch.

- [ ] **Step 1: Write the failing test**

```swift
    func testBatchCreatesOneSanitizedSubdirectoryPerSample() throws {
        for sample in ["S1", "S 2"] {
            for relative in ["variants/bowtie2/\(sample).sorted.bam"] {
                let url = results.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data().write(to: url)
            }
        }
        let project = root.appendingPathComponent("P.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let ingested = try ViralReconResultIngest.ingestBatch(
            resultsDirectory: results,
            sampleNames: ["S1", "S 2"],
            referenceBundleURL: referenceBundle,
            projectURL: project)

        XCTAssertEqual(ingested.count, 2)
        let parents = Set(ingested.map { $0.bundleDirectory.deletingLastPathComponent().path })
        XCTAssertEqual(parents.count, 1, "all samples share one batch directory")
        for entry in ingested {
            XCTAssertFalse(entry.bundleDirectory.lastPathComponent.contains(" "),
                           "sample directory names are sanitized")
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --skip-update --filter ViralReconResultIngestTests`
Expected: FAIL, no member `ingestBatch`.

- [ ] **Step 3: Implement**

Create the batch directory with `AnalysesFolder.createAnalysisDirectory(tool: "viralrecon", in: projectURL, isBatch: true)`, then call `ingest` once per sample into a sanitized subdirectory. Reuse the sanitizing rule `TaxTriageSerialBatchRunner.sanitizedDirectoryName(for:)` applies rather than inventing a second one.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --skip-update --filter ViralReconResultIngestTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/ViralRecon/ViralReconResultIngest.swift Tests/LungfishWorkflowTests/ViralRecon/ViralReconResultIngestTests.swift
git commit -m "Ingest multi-sample Viral Recon runs one bundle per sample"
```

---

### Task 8: Inspector catalogue

**Files:**
- Create: `Sources/LungfishApp/Views/Inspector/ViralReconDocumentStateBuilder.swift`
- Test: `Tests/LungfishAppTests/ViralReconDocumentStateBuilderTests.swift`

**Interfaces:**
- Consumes: `ViralReconResultInventory` (Task 1).
- Produces: `ViralReconDocumentStateBuilder.rows(for inventory: ViralReconResultInventory) -> [ViralReconDocumentRow]` where `ViralReconDocumentRow` has `section: String`, `label: String`, `fileURL: URL`.

Follow `MappingDocumentStateBuilder` for structure. Files are grouped by scientific role: Consensus, Lineage, Variants, Quality, Provenance.

- [ ] **Step 1: Read the existing builder**

Run: `sed -n '150,200p' Sources/LungfishApp/Views/Inspector/MappingDocumentStateBuilder.swift`

Match its row type and section conventions rather than inventing new ones.

- [ ] **Step 2: Write the failing test**

Assert that an inventory with a consensus, a pangolin CSV and a MultiQC report produces rows in the Consensus, Lineage and Quality sections respectively, and that an inventory with nothing produces no rows rather than empty sections.

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --package-path . --skip-update --filter ViralReconDocumentStateBuilderTests`
Expected: FAIL.

- [ ] **Step 4: Implement**

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --package-path . --skip-update --filter ViralReconDocumentStateBuilderTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/Inspector/ViralReconDocumentStateBuilder.swift Tests/LungfishAppTests/ViralReconDocumentStateBuilderTests.swift
git commit -m "Catalogue Viral Recon outputs in the Inspector by role"
```

---

### Task 9: Phase gate and end-to-end verification

- [ ] **Step 1: Run the unit tier**

Run: `bash scripts/full-suite-gate.sh --tier unit`
Expected: `GATE PASS`.

- [ ] **Step 2: Build the debug app**

Run: `swift build --package-path . --skip-update && bash scripts/build-app.sh --debug --skip-build`
Expected: build succeeds.

- [ ] **Step 3: Run Viral Recon end to end and confirm the bundle**

Run a real pipeline run through the shipped debug CLI against the demo project's SRR11140748_1 import. Then confirm:

```bash
# a bundle exists under Analyses with the tool recorded
find '/Users/dho/Desktop/demo/My Genome Project.lungfish/Analyses' -name 'analysis-metadata.json' -newermt '-1 hour' -exec grep -l viralrecon {} \;
# its reference bundle registers an alignment and a variant track
python3 -c "import json,sys,glob; m=glob.glob('<bundle>/MN908947.3.lungfishref/manifest.json')[0]; d=json.load(open(m)); print('alignments',len(d['alignments']),'variants',len(d['variants']))"
```

Expected: one bundle, with at least one alignment and one variant entry.

- [ ] **Step 4: Commit any gate fixes**

```bash
git add -A
git commit -m "Phase 3 gate: results integration"
```
