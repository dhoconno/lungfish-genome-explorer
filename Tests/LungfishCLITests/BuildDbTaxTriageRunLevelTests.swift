// BuildDbTaxTriageRunLevelTests.swift - The build-db taxtriage record names no bytes that markdup replaced
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane Q32, BIO's ruling on window 1's X1 run, fix F1. `build-db taxtriage` hashes its inputs first,
// then its unique-read pass marks duplicates, replaces each BAM in place and replaces its index, and a removal
// step names the old bytes (`BuildDbSamtoolsProvenanceTracker.markdup`). Every step was right, but the run level
// of the record and of each sidecar named the BAM with the digest of the bytes that went, on the real engine
// 159f27b0 at 6107 bytes, which no file holds. The run level now drops the bytes a removal step names, as the
// esviritu and kraken2 records do (`BuildDbEsVirituRunLevelTests`). It keeps the names that the legacy GUI
// route's cleanup removed, the top reports among them, because that cleanup records no removal step and side A's
// parity entries declare it (TaxTriageParityKnownDifferences).

import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

/// The stand-in form. The BAM, its index and the top report are placeholders, so no samtools runs, while the
/// input records, the record and the sidecars are the command's own. `EsVirituRunLevel` names and reads them.
final class BuildDbTaxTriageRunLevelTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "BuildDbTaxTriageRunLevel")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// A markdup rewrites the BAM in place and replaces its index, and its removal step names the bytes that went.
    /// The run level of the returned record and of every record in the folder names none of them, a step keeps
    /// the bytes it read, and the run level still names the top report that the legacy cleanup removed.
    func testTheTaxTriageRunLevelNamesNoBytesTheMarkdupReplaced() async throws {
        let result = root.appendingPathComponent("taxtriage-batch", isDirectory: true)
        for folder in ["minimap2", "top"] {
            try FileManager.default.createDirectory(
                at: result.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true
            )
        }
        let bam = result.appendingPathComponent("minimap2/S1.S1.dwnld.references.bam")
        let index = result.appendingPathComponent("minimap2/S1.S1.dwnld.references.bam.bai")
        let topReport = result.appendingPathComponent("top/S1.top_report.tsv")
        let database = result.appendingPathComponent("taxtriage.sqlite")
        try Data("BAM before markdup\n".utf8).write(to: bam)
        try Data("index before markdup\n".utf8).write(to: index)
        try Data("top report of S1\n".utf8).write(to: topReport)
        try Data("taxtriage database\n".utf8).write(to: database)

        // The build hashes its inputs before anything runs (`buildDatabase`), the BAM, its index and the top report.
        let inputs = BuildDbCommand.buildDbInputRecords(tool: .taxTriage, resultURL: result)
        XCTAssertEqual(inputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }, [
            "S1.S1.dwnld.references.bam", "S1.S1.dwnld.references.bam.bai", "S1.top_report.tsv",
        ])
        let topDigest = try XCTUnwrap(ProvenanceRecorder.sha256(of: topReport))

        let clock = ProvenanceRunClock()
        let read = try ProvenanceFileDescriptor.file(url: bam, format: .bam, role: .input)
        let oldIndex = try ProvenanceFileDescriptor.file(url: index, role: .index)
        let header = Self.standInStep(["samtools", "view", "-H", bam.path], inputs: [read], outputs: [], clock: clock)
        try Data("BAM after markdup\n".utf8).write(to: bam)
        try Data("index after markdup\n".utf8).write(to: index)
        let markedBAM = try ProvenanceFileDescriptor.file(url: bam, format: .bam, role: .output)
        let newIndex = try ProvenanceFileDescriptor.file(url: index, role: .index)
        let markdup = Self.standInStep(["samtools", "markdup", bam.path], inputs: [read], outputs: [markedBAM], clock: clock)
        let indexing = Self.standInStep(["samtools", "index", bam.path], inputs: [markedBAM], outputs: [newIndex], clock: clock)
        let replacement = try XCTUnwrap(RecordedRemovalStep.step(
            toolName: "Lungfish Markdup Replacement", api: "FileManager.replaceItemAt(_:withItemAt:)", removing: [read, oldIndex], clock: clock
        ))
        // The legacy cleanup deletes top/ and records no removal step for it.
        try FileManager.default.removeItem(at: topReport)

        let record = try await BuildDbCommand.recordBuildDbProvenance(
            tool: .taxTriage, resultURL: result, dbURL: database, force: true, noCleanup: false,
            globalOptions: try GlobalOptions.parse([]), runClock: clock, inputRecords: inputs,
            additionalSteps: [header, markdup, indexing, replacement],
            events: BuildDbEventSink(progress: { _, _ in }, text: { _ in }, textWarning: { _ in }, warning: { _ in })
        )

        let records = try EsVirituRunLevel.records(in: result)
        XCTAssertEqual(records.map(\.name), [
            ".lungfish-provenance.json",
            "minimap2/S1.S1.dwnld.references.bam.bai.lungfish-provenance.json",
            "minimap2/S1.S1.dwnld.references.bam.lungfish-provenance.json",
            "taxtriage.sqlite.lungfish-provenance.json",
        ], "the folder's record and the sidecars of the BAM, its index and the database")
        let replaced = Set(EsVirituRunLevel.named([read, oldIndex]))
        for (name, envelope) in records + [("the returned record", record)] {
            let runLevel = EsVirituRunLevel.named(envelope.files + envelope.outputs + [envelope.output].compactMap { $0 })
            XCTAssertTrue(replaced.isDisjoint(with: runLevel), "\(name) names the replaced bytes at its run level, \(runLevel)")
            XCTAssertFalse(runLevel.isEmpty, name)
        }
        let top = EsVirituRunLevel.Named(path: EsVirituRunLevel.resolved(topReport.path), digest: topDigest)
        XCTAssertTrue(
            EsVirituRunLevel.named(record.files).contains(top),
            "the run level keeps the top report that the legacy cleanup removed, \(EsVirituRunLevel.named(record.files))"
        )
        let removal = try XCTUnwrap(record.steps.first { $0.resolvedOptions["operation"] == .string(RecordedRemovalStep.operation) })
        XCTAssertTrue(removal.inputs.contains(read), "the removal step names the bytes the markdup replaced")
        XCTAssertEqual(record.steps.last?.toolName, "lungfish build-db taxtriage", "the run's own step comes last")
    }

    /// A stand-in step of samtools that exited 0.
    private static func standInStep(
        _ argv: [String], inputs: [ProvenanceFileDescriptor], outputs: [ProvenanceFileDescriptor], clock: ProvenanceRunClock
    ) -> ProvenanceStep {
        ProvenanceStep(
            toolName: "samtools", toolVersion: "stand-in", argv: argv, inputs: inputs, outputs: outputs,
            exitStatus: 0, wallTimeSeconds: 0, stderr: nil, startedAt: clock.startedAt, completedAt: clock.now
        )
    }
}
