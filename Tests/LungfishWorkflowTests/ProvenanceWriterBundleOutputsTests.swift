// ProvenanceWriterBundleOutputsTests.swift - Which files of a bundle get a record of their own
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishWorkflow

/// `ProvenanceWriter.writeBundleProvenanceLayout` writes a roll-up record and, for each output of
/// the envelope that sits inside the bundle, one record under `provenance/` at the output's own
/// relative path. A record file, the signature or key file of a record and the app state file that
/// the bundle's kind declares are never outputs, so none of them gets a record or a line in the
/// roll-up. A manifest and a typed record stay outputs, because recorded digests cite them (plan
/// decisions V10 and P6, Phase 2.7 lane S7).
final class ProvenanceWriterBundleOutputsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bundle-outputs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// What a reference bundle can hold, as the outputs of one step. The scientific files come
    /// first, then the files the standard rule never records as outputs, then the typed records.
    private static let referenceFiles = [
        "sequence.fa",
        "manifest.json",
        "tracks/variants.vcf",
        // Record files, a root record and the records written beside a file.
        ".lungfish-provenance.json",
        "sequence.fa.lungfish-provenance.json",
        "tracks/variants.vcf.lungfish-provenance.json",
        // The signature and the key of the root record.
        ".lungfish-provenance.json.signature.json",
        ".lungfish-provenance.json.pub",
        // App state at the root of a reference bundle, and a file of that name one level down.
        ".viewstate.json",
        "tracks/.viewstate.json",
        // Typed records whose digests the genotype roll-up cites.
        "retained-demux-genotyping-provenance.json",
        "report.xlsx.provenance.json",
    ]

    // MARK: - Which outputs get a record

    func testRecordSigningAndAppStateFilesGetNoRecordWhileTypedRecordsAndManifestsKeepTheirs() throws {
        let layout = try writeLayout(bundleNamed: "genome.lungfishref", files: Self.referenceFiles)

        XCTAssertEqual(layout.records, [
            "bundle.lungfish-provenance.json",
            "manifest.json.lungfish-provenance.json",
            "report.xlsx.provenance.json.lungfish-provenance.json",
            "retained-demux-genotyping-provenance.json.lungfish-provenance.json",
            "sequence.fa.lungfish-provenance.json",
            "tracks/.viewstate.json.lungfish-provenance.json",
            "tracks/variants.vcf.lungfish-provenance.json",
        ])
        XCTAssertEqual(layout.written.count, 7, "the roll-up and one record for each of the 6 outputs")
        XCTAssertEqual(layout.rollupOutputs, [
            ".viewstate.json",
            "manifest.json",
            "report.xlsx.provenance.json",
            "retained-demux-genotyping-provenance.json",
            "sequence.fa",
            "variants.vcf",
        ], "the roll-up cites the same outputs, and no record, signature, key or root app state file")
    }

    func testAppStateIsDroppedOnlyForTheKindThatDeclaresIt() throws {
        let files = ["data.txt", ".viewstate.json", ".genotype-viewstate.json"]
        let dropped: [(bundle: String, file: String?)] = [
            ("genome.lungfishref", ".viewstate.json"),
            ("result.lungfishgenotype", ".genotype-viewstate.json"),
            ("reads.lungfishfastq", nil),
            ("later.lungfishfuture", nil),
        ]
        for (bundle, file) in dropped {
            let layout = try writeLayout(bundleNamed: bundle, files: files)
            let recorded = files.filter { $0 != file }.map { "\($0).lungfish-provenance.json" }
            XCTAssertEqual(layout.records, (["bundle.lungfish-provenance.json"] + recorded).sorted(), bundle)
        }
    }

    func testAFrozenFormatKeepsEveryRecord() throws {
        // An alignment keeps its own record names, so the writer-wide rule never applies to it.
        let files = ["alignment.fasta", ".lungfish-provenance.json", ".viewstate.json"]
        let layout = try writeLayout(bundleNamed: "aln.lungfishmsa", files: files)
        XCTAssertEqual(layout.records, (["bundle.lungfish-provenance.json"] + files.map { "\($0).lungfish-provenance.json" }).sorted())
        XCTAssertEqual(layout.rollupOutputs, files.sorted())
    }

    func testABundleWhoseOnlyOutputsAreDroppedWritesOnlyTheRollUp() throws {
        let layout = try writeLayout(bundleNamed: "genome.lungfishref", files: [
            ".lungfish-provenance.json",
            ".lungfish-provenance.json.signature.json",
            ".lungfish-provenance.json.pub",
            ".viewstate.json",
        ])
        XCTAssertEqual(layout.records, ["bundle.lungfish-provenance.json"])
        XCTAssertEqual(layout.written.count, 1)
    }

    func testTheLimitOf100RecordsCountsOnlyTheOutputsThatGetOne() throws {
        let scientific = (0..<ProvenanceWriter.maximumBundleOutputSidecars).map { "chunks/chunk-\($0).txt" }
        let dropped = [
            "chunks/chunk-0.txt.lungfish-provenance.json",
            "chunks/chunk-1.txt.lungfish-provenance.json",
            ".viewstate.json",
        ]
        let layout = try writeLayout(bundleNamed: "genome.lungfishref", files: scientific + dropped)
        XCTAssertEqual(layout.written.count, 1 + 100, "103 files are listed, 100 of them get a record, and 100 is the limit")
        XCTAssertEqual(layout.records.count, 1 + 100)
    }

    // MARK: - Records an earlier build wrote

    func testARewriteRemovesTheRecordOfARecordThatAnEarlierBuildWrote() throws {
        let fixture = try makeBundle(named: "genome.lungfishref", files: ["sequence.fa", "sequence.fa.lungfish-provenance.json"])
        let writer = ProvenanceWriter(signingProvider: nil)

        // A build before the rule recorded the record file as an output of its own.
        let recordFile = fixture.bundle.appendingPathComponent("sequence.fa.lungfish-provenance.json")
        let legacy = try XCTUnwrap(ProvenanceWriter.bundleOutputSidecarURL(for: recordFile, inBundle: fixture.bundle))
        let output = try XCTUnwrap(fixture.outputs["sequence.fa.lungfish-provenance.json"])
        _ = try writer.write(fixture.envelope.focusedOnOutput(output), toSidecar: legacy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))

        _ = try writer.writeBundleProvenanceLayout(fixture.envelope, toBundleRoot: fixture.bundle)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacy.path),
            "the next write of the layout prunes it, as it prunes the record of any output the envelope no longer lists"
        )
        XCTAssertEqual(try records(in: fixture.bundle), [
            "bundle.lungfish-provenance.json",
            "sequence.fa.lungfish-provenance.json",
        ])
    }

    // MARK: - Helpers

    private struct Fixture {
        let bundle: URL
        let envelope: ProvenanceEnvelope
        /// The descriptor of each file, by its path inside the bundle.
        let outputs: [String: ProvenanceFileDescriptor]
    }

    private struct Layout {
        /// What `writeBundleProvenanceLayout` returned.
        let written: [URL]
        /// Every file under `provenance/`, relative to it and sorted, the roll-up included.
        let records: [String]
        /// The file names the roll-up cites as outputs, sorted.
        let rollupOutputs: [String]
    }

    /// Creates the files in a bundle folder inside a project and names each as an output of one step.
    private func makeBundle(named name: String, files: [String]) throws -> Fixture {
        let bundle = root.appendingPathComponent("P.lungfish/Analyses/run-1/\(name)", isDirectory: true)
        var outputs: [String: ProvenanceFileDescriptor] = [:]
        for relative in files {
            let url = bundle.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("content of \(relative)\n".utf8).write(to: url)
            outputs[relative] = try ProvenanceFileDescriptor.file(url: url, format: .text, role: .output)
        }
        let envelope = try ProvenanceRunBuilder(
            workflowName: "bundle",
            workflowVersion: "2026.10",
            toolName: "lungfish-cli",
            toolVersion: "2026.10"
        )
        .argv(["lungfish-cli", "bundle"])
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .step(ProvenanceStep(
            toolName: "lungfish-cli",
            toolVersion: "2026.10",
            argv: ["lungfish-cli"],
            outputs: files.compactMap { outputs[$0] },
            exitStatus: 0
        ))
        .complete(exitStatus: 0, startedAt: Date(timeIntervalSince1970: 20), endedAt: Date(timeIntervalSince1970: 22))
        return Fixture(bundle: bundle, envelope: envelope, outputs: outputs)
    }

    /// Every file under `provenance/`, relative to it and sorted. Hidden names are included.
    private func records(in bundle: URL) throws -> [String] {
        let provenance = bundle.appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
        return try FileManager.default.subpathsOfDirectory(atPath: provenance.path).filter { path in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: provenance.appendingPathComponent(path).path, isDirectory: &isDirectory)
            return !isDirectory.boolValue
        }.sorted()
    }

    /// Makes the bundle and writes its record layout.
    private func writeLayout(bundleNamed name: String, files: [String]) throws -> Layout {
        let fixture = try makeBundle(named: name, files: files)
        let written = try ProvenanceWriter(signingProvider: nil)
            .writeBundleProvenanceLayout(fixture.envelope, toBundleRoot: fixture.bundle)
        let provenance = fixture.bundle.appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
        let rollup = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: provenance.appendingPathComponent(ProvenanceWriter.bundleRollupFilename)
        ))
        return Layout(
            written: written,
            records: try records(in: fixture.bundle),
            rollupOutputs: rollup.outputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }.sorted()
        )
    }
}
