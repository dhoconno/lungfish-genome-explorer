// RNASeqSmokeFixtureTests.swift - The RNA-seq result of the release smoke, read back by the leaf's own reader
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The view-switch smoke (ReleaseCandidateSmokeXCUITests) opens an RNA-seq result that it writes by hand, because the smoke
// gate stages no Tests/Fixtures/rnaseq folder for `lungfish-cli import rnaseq` to read. A result the app cannot read costs a
// repackage of the candidate, since `swift build` does not compile the XCUI target. That target belongs to Lungfish.xcodeproj
// and has no SwiftPM target, so this class cannot call its helper. RNASeqSmokeFixtureBytes writes the same bytes. A change to
// the fixture of the smoke goes to this file, and the other way, as it does for SmokeFixtureReadTests in LungfishAppTests.

import Foundation
import LungfishIO
import LungfishRNASeqUI
import XCTest

/// The bytes of `ReleaseSmokeFixtures.addRNASeqResult` (Tests/LungfishXCUITests).
enum RNASeqSmokeFixtureBytes {
    static let row = "Smoke RNA-seq"
    static let tables = ["samples.tsv": "sample_id\tanimal\tspecies\torigin\tgroup\truns\tsource_folder\nS1\t\t\t\t\tS1\t\nS2\t\t\t\t\tS2\t\n",
                         "genes.tsv": "gene_id\tname\tbiotype\tcontig\tlength\tnot_host\tmask\tunreliable\nG1\t\t\t\t\t\t\t\nG2\t\t\t\t\t\t\t\n",
                         "counts/genes.counts.tsv": "feature_id\tS1\tS2\nG1\t10\t20\nG2\t0\t5\n"]

    @discardableResult
    static func result(in project: URL) throws -> URL {
        let bundle = project.appendingPathComponent("\(row).lungfishrnaseq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("counts", isDirectory: true),
                                                withIntermediateDirectories: true)
        var digests: [String: String] = [:]
        for (path, text) in tables {
            let data = Data(text.utf8)
            try data.write(to: bundle.appendingPathComponent(path))
            digests[path] = RNASeqResultBundle.sha256Hex(data)
        }
        func entry(_ path: String) -> [String: Any] { ["path": path, "sha256": digests[path] ?? ""] }
        var counts = entry("counts/genes.counts.tsv")
        counts.merge(["rows": "gene", "unit": "reads", "column": "default"]) { _, new in new }
        let route: [String: Any] = ["id": "salmon-selective-alignment", "tool": "salmon", "toolVersion": "1.10.0",
                                    "settings": ["unit": "NumReads"]]
        let manifest: [String: Any] = ["schemaVersion": 1, "kind": "rnaseq-result", "modality": "bulk", "name": row,
                                       "createdAt": "2026-11-18T00:00:00Z",
                                       "origin": ["kind": "imported", "tool": "salmon", "toolVersion": "1.10.0"],
                                       "route": route, "referenceSet": NSNull(), "samples": entry("samples.tsv"),
                                       "genes": entry("genes.tsv"), "counts": [counts], "sourceFiles": [Any](),
                                       "notHost": [String]()]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: bundle.appendingPathComponent("rnaseq-result.json"))
        return bundle
    }
}

final class RNASeqSmokeFixtureTests: XCTestCase {
    private var project: URL!

    override func setUpWithError() throws {
        project = FileManager.default.temporaryDirectory.appendingPathComponent("rnaseq-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let project { try? FileManager.default.removeItem(at: project) }
    }

    /// The three tables are the bytes the one printer of LungfishIO gives, which the writer uses, so no tab is missing.
    func testTheTablesAreTheBytesTheWriterPrints() throws {
        let samples = try RNASeqSampleRecord.tsvData(["S1", "S2"].map { RNASeqSampleRecord(id: $0, runs: [$0]) })
        let genes = try RNASeqGeneRecord.tsvData(["G1", "G2"].map { RNASeqGeneRecord(id: $0) })
        let counts = try RNASeqCountTable(sampleIDs: ["S1", "S2"], rows: [
            RNASeqCountTable.Row(id: "G1", counts: [10, 20]),
            RNASeqCountTable.Row(id: "G2", counts: [0, 5]),
        ]).tsvData()
        XCTAssertEqual(RNASeqSmokeFixtureBytes.tables["samples.tsv"], String(decoding: samples, as: UTF8.self))
        XCTAssertEqual(RNASeqSmokeFixtureBytes.tables["genes.tsv"], String(decoding: genes, as: UTF8.self))
        XCTAssertEqual(RNASeqSmokeFixtureBytes.tables["counts/genes.counts.tsv"], String(decoding: counts, as: UTF8.self))
    }

    /// The sidebar lists the folder as the RNA-seq kind and the leaf's reader loads it with the facts the viewer shows.
    func testTheFolderIsTheKindAndLoadsWithItsFacts() throws {
        let bundle = try RNASeqSmokeFixtureBytes.result(in: project)
        let kind = try XCTUnwrap(SidebarKindRegistry.bundleKind(ofFolder: bundle))
        XCTAssertEqual(kind.id, "bundle:\(BundleKindID.rnaseqResult.rawValue)")
        guard case .loaded(let result) = RNASeqResultSurface.read(bundle) else {
            return XCTFail("The reader refuses the smoke's RNA-seq result: \(RNASeqResultSurface.read(bundle))")
        }
        XCTAssertEqual(RNASeqResultFacts(result: result),
                       RNASeqResultFacts(name: RNASeqSmokeFixtureBytes.row, modality: "bulk", origin: "imported, salmon 1.10.0",
                                         route: "salmon-selective-alignment, salmon 1.10.0", sampleCount: 2))
        XCTAssertEqual(result.counts.count, 1)
        XCTAssertEqual(try RNASeqResultBundle.verifyChecksums(of: bundle), [], "The sha256 values of the manifest hold")
    }

    /// The smoke finds the viewer by this identifier (`kinds` of testReleaseCandidateViewSwitchPerKind).
    @MainActor
    func testTheViewerCarriesTheIdentifierTheSmokeLooksFor() {
        XCTAssertEqual(RNASeqResultViewController.accessibilityID, "rnaseq-result-view")
    }
}
