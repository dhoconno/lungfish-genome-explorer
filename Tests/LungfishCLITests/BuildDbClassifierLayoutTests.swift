// BuildDbClassifierLayoutTests.swift - How build-db esviritu reads the folders EsViritu leaves
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

/// How `build-db esviritu` reads the folders that EsViritu runs and imports leave, pinned at base
/// `18e422c4f` by lane A7 of Phase 2.7 (risks R4 to R6 of the architecture inventory). A test whose name
/// ends in `KnownDefect` asserts a defect as it is today, and the commit that fixes the defect changes it.
/// The fixtures copy the tables of one `Tests/Fixtures/esviritu-mini` sample and hold no BAM, so no row
/// names a BAM and no samtools runs.
final class BuildDbClassifierLayoutTests: XCTestCase {
    /// The esviritu-mini sample whose tables the fixtures copy. Its detection table holds two
    /// detections, OR708245.1 and MF094130.1, and its coverage table 100 windows for each of seven
    /// accessions.
    private static let fixtureSample = "SRR35517705"

    /// R5. `esviritu detect --output` and an EsViritu import leave one sample's tables at the folder root,
    /// named by the sample, with the run's record beside them (`Tests/Fixtures/golden/classifiers/esviritu`).
    /// `build-db esviritu` reads such a root when no sample folder holds a detection table, as
    /// `build-db kraken2` reads a root that holds one run. It was a known defect at base `18e422c4f`, where
    /// the index of such a folder was empty.
    func testOneFolderResultIsReadFromTheFolderRoot() async throws {
        let root = try TestTempDirectory.make(prefix: "BuildDbOneFolder")
        defer { TestTempDirectory.cleanup(root) }
        let result = root.appendingPathComponent("esviritu-detect", isDirectory: true)
        let tables = try writeTables(as: "sample-A", into: result)
        try writeSampleRecord(naming: tables, in: result)

        try await BuildDbCommand.EsVirituSubcommand.parse([result.path, "--quiet"]).run()

        let database = try EsVirituDatabase(at: result.appendingPathComponent("esviritu.sqlite"))
        XCTAssertEqual(try database.fetchSamples().map(\.sample), ["sample-A"], "R5: the root tables are read")
        XCTAssertEqual(try database.fetchRows(samples: ["sample-A"]).map(\.accession).sorted(), ["MF094130.1", "OR708245.1"])
        XCTAssertEqual(try database.fetchCoverageWindows(sample: "sample-A", accession: "OR708245.1").count, 100)
        XCTAssertEqual(
            ProvenanceRecorder.loadEnvelope(from: result)?.workflowName,
            "EsViritu",
            "The folder keeps the record of the run that made it"
        )
    }

    /// A one-folder result keeps its BAM in `<root>/<sample>_temp/`. Its rows name the BAM under the root's
    /// `bams`, the run moves it there before samtools counts its reads, and the cleanup removes `_temp`. The
    /// record of the run holds the move as its first step (plan decision E7), from the old path to the new one
    /// with one digest. A stand-in samtools reports the BAM as marked and counts two reads, so no real tool runs.
    func testOneFolderResultMovesItsBAMToTheRootBamsAsARecordedStep() async throws {
        let root = try TestTempDirectory.make(prefix: "BuildDbOneFolderBAM")
        defer { TestTempDirectory.cleanup(root) }
        let samtools = try ManagedSamtoolsHome.makeStub(rootURL: root, namePrefix: "Home", script: Self.markedSamtools)
        let result = root.appendingPathComponent("esviritu-detect", isDirectory: true)
        try writeTables(as: "sample-A", into: result)
        let temp = result.appendingPathComponent("sample-A_temp", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try Data("BAM".utf8).write(to: temp.appendingPathComponent("sample-A.third.filt.sorted.bam"))
        try Data("BAI".utf8).write(to: temp.appendingPathComponent("sample-A.third.filt.sorted.bam.bai"))

        try await withHome(samtools.homeURL) {
            try await BuildDbCommand.EsVirituSubcommand.parse([result.path, "--quiet"]).run()
        }

        let database = try EsVirituDatabase(at: result.appendingPathComponent("esviritu.sqlite"))
        let rows = try database.fetchRows(samples: ["sample-A"])
        XCTAssertEqual(Set(rows.map(\.bamPath)), ["bams/sample-A.third.filt.sorted.bam"])
        XCTAssertEqual(Set(rows.map(\.uniqueReads)), [2])
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.appendingPathComponent("bams/sample-A.third.filt.sorted.bam").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path), "The cleanup removes _temp")

        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: result), "No other record was there")
        XCTAssertEqual(record.workflowName, "lungfish build-db esviritu")
        let move = try XCTUnwrap(record.steps.first)
        XCTAssertEqual(move.toolName, "Lungfish EsViritu BAM Relocation")
        XCTAssertEqual(move.inputs.map(\.path), ["bam", "bam.bai"].map { temp.appendingPathComponent("sample-A.third.filt.sorted.\($0)").path })
        let bams = result.appendingPathComponent("bams", isDirectory: true)
        XCTAssertEqual(move.outputs.map(\.path), ["bam", "bam.bai"].map { bams.appendingPathComponent("sample-A.third.filt.sorted.\($0)").path })
        XCTAssertEqual(move.outputs.map(\.originPath), move.inputs.map(\.path))
        XCTAssertEqual(move.outputs.map(\.checksumSHA256), move.inputs.map(\.checksumSHA256), "A move changes no byte")
        XCTAssertEqual(move.outputs.map(\.role), [.output, .index])
        XCTAssertTrue(record.steps.dropFirst().contains { $0.toolName == "samtools" }, "samtools runs after the move")
        for output in record.outputs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "The record names \(output.path)")
        }
    }

    /// R4. A batch sample folder takes the sanitized id (`Patient_07`), while EsViritu names its tables by
    /// the raw id it was given (`Patient.07`). Known defect: build-db reads a sample folder only through
    /// `<folder>/<folder>.detected_virus.info.tsv`, so every detection of that sample is dropped. Lane A9
    /// fixes it with one sanitizer for the folder and EsViritu's `-s`, so this pin stays as it is in A7.
    func testDottedBatchSampleIsDroppedKnownDefect() async throws {
        let root = try TestTempDirectory.make(prefix: "BuildDbDottedSample")
        defer { TestTempDirectory.cleanup(root) }
        let batch = root.appendingPathComponent("esviritu-batch-2026-10-11T10-00-00", isDirectory: true)
        try writeTables(as: "Patient.07", into: batch.appendingPathComponent("Patient_07", isDirectory: true))
        try writeTables(as: "Patient_08", into: batch.appendingPathComponent("Patient_08", isDirectory: true))

        try await BuildDbCommand.EsVirituSubcommand.parse([batch.path, "--quiet"]).run()

        let database = try EsVirituDatabase(at: batch.appendingPathComponent("esviritu.sqlite"))
        XCTAssertEqual(try database.fetchSamples().map(\.sample), ["Patient_08"], "R4: Patient.07 is dropped")
        XCTAssertEqual(try database.fetchRows(samples: ["Patient_08"]).count, 2)
        XCTAssertEqual(try database.fetchRows(samples: ["Patient.07", "Patient_07"]).count, 0)
    }

    /// R6. The sample record lists the coverage windows and the assembly summary as outputs, as
    /// `EsVirituPipeline` records them, and the cleanup keeps both (plan decision E7). It was a known defect
    /// at base `18e422c4f`, where the cleanup deleted both tables and the record named files that were gone.
    func testCleanupKeepsEveryTableTheSampleRecordNames() async throws {
        let root = try TestTempDirectory.make(prefix: "BuildDbCleanup")
        defer { TestTempDirectory.cleanup(root) }
        let batch = root.appendingPathComponent("esviritu-batch-2026-10-11T10-00-00", isDirectory: true)
        let sampleFolder = batch.appendingPathComponent("S1", isDirectory: true)
        let tables = try writeTables(as: "S1", into: sampleFolder)
        try writeSampleRecord(naming: tables, in: sampleFolder)

        try await BuildDbCommand.EsVirituSubcommand.parse([batch.path, "--quiet"]).run()

        let named = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: sampleFolder)).outputs.map(\.path).sorted()
        XCTAssertEqual(named, tables.map(\.path).sorted(), "The sample record still names the three tables")
        let missing = named.filter { !FileManager.default.fileExists(atPath: $0) }
        XCTAssertEqual(missing, [], "R6: every table the sample record names is still there")
        let database = try EsVirituDatabase(at: batch.appendingPathComponent("esviritu.sqlite"))
        XCTAssertEqual(try database.fetchCoverageWindows(sample: "S1", accession: "OR708245.1").count, 100)
    }

    // MARK: Fixtures

    /// A stand-in samtools that reports every BAM as marked by `samtools markdup` and counts two reads, so
    /// `build-db` keeps the BAM and its index as they are.
    private static let markedSamtools = """
    #!/bin/sh
    case "$1" in
      --version) echo "samtools 1.21" ;;
      view)
        case "$2" in
          -H) printf '@HD\\tVN:1.6\\n@PG\\tID:samtools.markdup\\tPN:samtools\\tCL:samtools markdup in.bam out.bam\\n' ;;
          -c) echo 2 ;;
        esac ;;
    esac
    exit 0
    """

    /// Runs `body` with `HOME` at `home`, where `build-db` finds its managed samtools.
    private func withHome(_ home: URL, _ body: () async throws -> Void) async throws {
        let original = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", home.path, 1)
        defer {
            if let original { setenv("HOME", original, 1) } else { unsetenv("HOME") }
        }
        try await body()
    }

    /// Copies the detection, coverage windows and assembly summary tables of the fixture sample into
    /// `directory`, named by `prefix` as EsViritu names them by its `-s` sample id.
    @discardableResult
    private func writeTables(as prefix: String, into directory: URL) throws -> [URL] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = BuildDbStreamCapture.fixturesFolder
            .appendingPathComponent("esviritu-mini/\(Self.fixtureSample)", isDirectory: true)
        return try ["detected_virus.info.tsv", "virus_coverage_windows.tsv", "detected_virus.assembly_summary.tsv"].map { suffix in
            let destination = directory.appendingPathComponent("\(prefix).\(suffix)")
            try fileManager.copyItem(at: source.appendingPathComponent("\(Self.fixtureSample).\(suffix)"), to: destination)
            return destination
        }
    }

    /// A record of an EsViritu run in `directory` that names `outputs`, as the pipeline writes one.
    private func writeSampleRecord(naming outputs: [URL], in directory: URL) throws {
        var builder = ProvenanceRunBuilder(
            workflowName: "EsViritu",
            workflowVersion: "1.2.3",
            toolName: "EsViritu",
            toolVersion: "1.2.3"
        )
        .argv(["EsViritu", "-r", "reads.fastq", "-s", "sample", "-o", directory.path])
        .runtime(ProvenanceRuntimeIdentity())
        for output in outputs {
            builder = try builder.output(output, format: .text)
        }
        let now = Date()
        _ = try ProvenanceWriter().write(try builder.complete(exitStatus: 0, startedAt: now, endedAt: now), to: directory)
    }
}
