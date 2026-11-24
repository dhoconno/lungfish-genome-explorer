// SampleMetadataImportKeepsRunRecordTests.swift - A metadata import adds its run to the record that stands in a bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// S1 sweep lane RECORDS, TWELVES-IMPORT-REPLACES-RUN-RECORD (BIO review of STALE12S, Q1). The app's metadata import wrote
// its own record over `.lungfish-provenance.json`, so after an import the 12S run's argv, times and tool versions were no
// longer in the file, and anything that reads the bundle record as the run's found the import. The import now joins the
// record that stands there as a later step, as an Inspector edit does, and writes its own record only when the bundle has
// none. These pins use no tool run, so no number changes.

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class SampleMetadataImportKeepsRunRecordTests: XCTestCase {
    private var root: URL!
    private var bundleURL: URL!

    private let started = Date(timeIntervalSince1970: 1_800_000_000)
    private let runArgv = [
        "lungfish-cli", "fastq", "12s-match", "reads.fastq", "--reference", "ref.fa", "--output", "run.lungfish12s",
    ]

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "metadata-import-keeps-record")
        bundleURL = root.appendingPathComponent("run.lungfish12s", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// The defect. The record the 12S run wrote holds its argv, its times and the tool versions of its steps, and a
    /// metadata import left only the import in the file.
    func testAMetadataImportKeepsTheRunRecordAndAddsItselfAsALaterStep() throws {
        try writeTwelveSBundle()
        try writeRunRecord()
        let before = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundleURL))
        XCTAssertEqual(before.workflowName, "lungfish fastq 12s-match", "the fixture holds the run's record")
        XCTAssertEqual(before.steps.count, 2)

        let metadataURL = try importMetadata()

        let after = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundleURL))
        XCTAssertEqual(after.workflowName, "lungfish fastq 12s-match", "the record is still the run's")
        XCTAssertEqual(after.argv, runArgv)
        XCTAssertEqual(after.toolName, before.toolName)
        XCTAssertEqual(after.toolVersion, before.toolVersion)
        XCTAssertEqual(after.exitStatus, before.exitStatus)
        XCTAssertEqual(after.options.explicit, before.options.explicit)
        XCTAssertEqual(after.options.defaults, before.options.defaults)
        XCTAssertEqual(after.options.resolvedDefaults, before.options.resolvedDefaults)
        XCTAssertEqual(after.createdAt.timeIntervalSince1970, started.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(after.steps.prefix(2).map(\.toolName), ["lungfish-cli", "vsearch"])
        XCTAssertEqual(after.steps.prefix(2).map(\.toolVersion), ["2026.11.16", "2.30.0"])
        XCTAssertEqual(after.steps.prefix(2).map(\.id), before.steps.map(\.id), "the run's steps are the ones that stood")
        XCTAssertEqual(
            try XCTUnwrap(after.steps.first?.startedAt).timeIntervalSince1970,
            started.timeIntervalSince1970,
            accuracy: 1
        )

        let importStep = try XCTUnwrap(after.steps.last)
        XCTAssertEqual(after.steps.count, 3, "the import is one later step")
        XCTAssertEqual(importStep.toolName, "Sample metadata import")
        XCTAssertEqual(importStep.exitStatus, 0)
        XCTAssertEqual(importStep.dependsOn, [try XCTUnwrap(before.steps.last).id])
        XCTAssertNotNil(importStep.startedAt)
        XCTAssertTrue(importStep.argv.contains("import-sample-metadata"))
        XCTAssertTrue(importStep.inputs.contains { $0.path == root.appendingPathComponent("metadata.tsv").path })
        XCTAssertTrue(importStep.outputs.contains { $0.path == metadataURL.path })
        XCTAssertTrue(after.outputs.contains { $0.path == metadataURL.path }, "the record's outputs gain the import's")
    }

    /// Guard. A bundle with no record gets the import's own record, as before.
    func testABundleWithNoRecordGetsTheImportsOwnRecord() throws {
        try writeTwelveSBundle()
        XCTAssertNil(try ProvenanceEnvelopeReader.load(from: bundleURL))

        _ = try importMetadata()

        let after = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundleURL))
        XCTAssertEqual(after.workflowName, "Sample metadata import")
        XCTAssertEqual(after.steps.count, 0)
    }

    /// A run record that exists and cannot be read stops the import with words that say what happened, and the bundle is as it
    /// was: the old import overwrote the record, and the new one must not lose it (BIO review of RECORDS, SF2).
    func testAnUnreadableRunRecordStopsTheImportAndLeavesTheBundleAsItWas() throws {
        try writeTwelveSBundle()
        let recordURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try Data("{".utf8).write(to: recordURL)

        XCTAssertThrowsError(try importMetadata()) {
            XCTAssertEqual($0 as? SampleMetadataBundleImportError, .unreadableRecord(recordURL.path))
        }

        XCTAssertEqual(try Data(contentsOf: recordURL), Data("{".utf8), "the record is as it was")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("metadata/sample_metadata.tsv").path),
            "the metadata the import wrote is gone"
        )
    }

    // MARK: - Fixtures

    /// A 12S result bundle with its manifest and sample table, and no run record yet.
    private func writeTwelveSBundle() throws {
        let manifest = TwelveSAmpliconResultBundleManifest(
            outputName: "run",
            analysisName: "run",
            referencePath: "reference.fa",
            targetTablePath: "targets.tsv",
            countMatrixPath: "sample-target-counts.tsv",
            sampleTablePath: "samples.tsv",
            readFatePath: "read-fate.json",
            provenancePath: ProvenanceWriter.provenanceFilename
        )
        try TwelveSAmpliconResultBundle.writeManifest(manifest, to: bundleURL)
        try """
        sample\tsample_name\tinput_reads\texact_match_reads\tunresolved_reads\tambiguous_exact_reads\tchimera_candidate_reads\texact_match_percent\tunresolved_percent
        SampleA\tSample A\t10\t8\t2\t0\t0\t80.0\t20.0
        """.write(to: bundleURL.appendingPathComponent("samples.tsv"), atomically: true, encoding: .utf8)
    }

    /// The record the 12S run writes: its argv, its times and a matching step and a vsearch step with their versions.
    private func writeRunRecord() throws {
        let matching = ProvenanceStep(
            toolName: "lungfish-cli",
            toolVersion: "2026.11.16",
            argv: runArgv,
            durableReplayArgv: runArgv,
            exitStatus: 0,
            wallTimeSeconds: 42,
            startedAt: started,
            completedAt: started.addingTimeInterval(42)
        )
        let vsearch = ProvenanceStep(
            toolName: "vsearch",
            toolVersion: "2.30.0",
            argv: ["vsearch", "--uchime_denovo", "unresolved.fasta"],
            exitStatus: 0,
            wallTimeSeconds: 5,
            dependsOn: [matching.id],
            startedAt: started.addingTimeInterval(37),
            completedAt: started.addingTimeInterval(42)
        )
        let record = try ProvenanceRunBuilder(
            workflowName: "lungfish fastq 12s-match",
            workflowVersion: "2026.11.16",
            toolName: "lungfish-cli",
            toolVersion: "2026.11.16"
        )
        .argv(runArgv)
        .durableReplayArgv(runArgv)
        .options(explicit: [:], defaults: [:], resolved: [:])
        .runtime(ProvenanceRuntimeIdentity())
        .step(matching)
        .step(vsearch)
        .output(bundleURL.appendingPathComponent("samples.tsv"), format: .text, role: .output)
        .complete(exitStatus: 0, startedAt: started, endedAt: started.addingTimeInterval(42))
        try ProvenanceWriter(signingProvider: nil).write(record, to: bundleURL)
    }

    /// The import the Inspector and the 12S viewer run, with a one-row metadata file. Returns the metadata the bundle keeps.
    private func importMetadata() throws -> URL {
        let sourceURL = root.appendingPathComponent("metadata.tsv")
        let metadata = Data("sample\tsite\nSampleA\tHilo\n".utf8)
        try metadata.write(to: sourceURL)
        let knownSampleIds = try ResultBundleSampleMetadataResolver.knownSampleIDs(in: bundleURL)
        let scanResult = try SampleMetadataStore.scanForSampleColumn(csvData: metadata, knownSampleIds: knownSampleIds)
        let result = try SampleMetadataBundleImportService().importMetadata(
            data: metadata,
            sourceURL: sourceURL,
            scanResult: scanResult,
            sampleColumnIndex: try XCTUnwrap(scanResult.bestColumn).index,
            knownSampleIds: knownSampleIds,
            bundleURL: bundleURL
        )
        return try XCTUnwrap(result.metadataURL)
    }
}
