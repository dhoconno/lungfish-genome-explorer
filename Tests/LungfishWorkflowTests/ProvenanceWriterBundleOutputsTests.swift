// ProvenanceWriterBundleOutputsTests.swift - Which files of a bundle get a record of their own
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishWorkflow

/// `ProvenanceWriter.writeBundleProvenanceLayout` writes a roll-up record and, for each output of
/// the envelope that sits inside the bundle, one record under `provenance/` at the output's own
/// relative path. This suite names the files such a bundle can hold and pins which of them get a
/// record (plan decisions V10 and P6, Phase 2.7 lane S7).
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

    // MARK: - Today

    func testEveryOutputInsideTheBundleGetsARecordToday() throws {
        let layout = try writeLayout(bundleNamed: "genome.lungfishref", files: Self.referenceFiles)

        XCTAssertEqual(layout.records, [
            ".lungfish-provenance.json.lungfish-provenance.json",
            ".lungfish-provenance.json.pub.lungfish-provenance.json",
            ".lungfish-provenance.json.signature.json.lungfish-provenance.json",
            ".viewstate.json.lungfish-provenance.json",
            "bundle.lungfish-provenance.json",
            "manifest.json.lungfish-provenance.json",
            "report.xlsx.provenance.json.lungfish-provenance.json",
            "retained-demux-genotyping-provenance.json.lungfish-provenance.json",
            "sequence.fa.lungfish-provenance.json",
            "sequence.fa.lungfish-provenance.json.lungfish-provenance.json",
            "tracks/.viewstate.json.lungfish-provenance.json",
            "tracks/variants.vcf.lungfish-provenance.json",
            "tracks/variants.vcf.lungfish-provenance.json.lungfish-provenance.json",
        ])
        XCTAssertEqual(layout.written.count, 13, "the roll-up and one record for each of the 12 outputs")
        XCTAssertEqual(layout.rollupOutputs, Self.referenceFiles.map { ($0 as NSString).lastPathComponent }.sorted())
    }

    // MARK: - Helpers

    private struct Layout {
        /// What `writeBundleProvenanceLayout` returned.
        let written: [URL]
        /// Every file under `provenance/`, relative to it and sorted, the roll-up included.
        let records: [String]
        /// The file names the roll-up cites as outputs, sorted.
        let rollupOutputs: [String]
    }

    /// Creates the files in a bundle folder, names each as an output of one step and writes the
    /// bundle's record layout.
    private func writeLayout(bundleNamed name: String, files: [String]) throws -> Layout {
        let bundle = root.appendingPathComponent("P.lungfish/Analyses/run-1/\(name)", isDirectory: true)
        var outputs: [ProvenanceFileDescriptor] = []
        for relative in files {
            let url = bundle.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("content of \(relative)\n".utf8).write(to: url)
            outputs.append(try ProvenanceFileDescriptor.file(url: url, format: .text, role: .output))
        }
        let envelope = try ProvenanceRunBuilder(
            workflowName: "bundle",
            workflowVersion: "2026.10",
            toolName: "lungfish-cli",
            toolVersion: "2026.10"
        )
        .argv(["lungfish-cli", "bundle"])
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .step(ProvenanceStep(toolName: "lungfish-cli", toolVersion: "2026.10", argv: ["lungfish-cli"], outputs: outputs, exitStatus: 0))
        .complete(exitStatus: 0, startedAt: Date(timeIntervalSince1970: 20), endedAt: Date(timeIntervalSince1970: 22))

        let written = try ProvenanceWriter(signingProvider: nil).writeBundleProvenanceLayout(envelope, toBundleRoot: bundle)

        let provenance = bundle.appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
        let records = try FileManager.default.subpathsOfDirectory(atPath: provenance.path).filter { path in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: provenance.appendingPathComponent(path).path, isDirectory: &isDirectory)
            return !isDirectory.boolValue
        }.sorted()
        let rollup = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: provenance.appendingPathComponent(ProvenanceWriter.bundleRollupFilename)
        ))
        return Layout(
            written: written,
            records: records,
            rollupOutputs: rollup.outputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }.sorted()
        )
    }
}
