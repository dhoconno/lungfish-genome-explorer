// RNASeqResultBundleTests.swift - The reader of an RNA-seq result (Phase 5.1 lane RS-KIND)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
import LungfishTestSupport

final class RNASeqResultBundleTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("rnaseq-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func makeBundle(manifest: String?) throws -> URL {
        let bundle = folder.appendingPathComponent("x.lungfishrnaseq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        if let manifest { try Data(manifest.utf8).write(to: RNASeqResultBundle.manifestURL(in: bundle)) }
        try Data("sample_id\tanimal\tspecies\torigin\tgroup\truns\tsource_folder\npbmc\t\t\t\t\t\t\n".utf8)
            .write(to: bundle.appendingPathComponent("samples.tsv"))
        try Data("gene_id\tname\tbiotype\tcontig\tlength\tnot_host\tmask\tunreliable\nG1\t\t\t\t\t\t\t\n".utf8)
            .write(to: bundle.appendingPathComponent("genes.tsv"))
        return bundle
    }

    /// A single-cell manifest naming the files of STARsolo's filtered folder, with no `source/` folder behind it.
    private func manifestJSON(samplesPath: String = "samples.tsv") -> String {
        let filtered = "source/pbmc/Solo.out/Gene/filtered"
        func file(_ name: String) -> String { #"{"path": "\#(filtered)/\#(name)", "sha256": "0"}"# }
        return #"""
        {"schemaVersion": 1, "kind": "rnaseq-result", "modality": "single-cell", "name": "pbmc_1k_v3",
         "createdAt": "2026-11-14T12:00:00Z", "origin": {"kind": "imported", "tool": "STARsolo", "toolVersion": "2.7.11b"},
         "route": {"id": "starsolo-gene", "tool": "STAR", "toolVersion": "2.7.11b", "settings": {"soloFeatures": "Gene"}},
         "referenceSet": null, "samples": {"path": "\#(samplesPath)", "sha256": "0"}, "genes": {"path": "genes.tsv", "sha256": "0"},
         "counts": [], "sourceFiles": [], "notHost": [],
         "matrices": [{"sample": "pbmc", "matrix": \#(file("matrix.mtx")), "features": \#(file("features.tsv")),
                       "barcodes": \#(file("barcodes.tsv")), "format": "matrix-market", "isGzip": false,
                       "cellCount": 200, "featureCount": 1353, "entryCount": 17692}]}
        """#
    }

    private func listing(of bundle: URL) throws -> [String] {
        let walker = try XCTUnwrap(FileManager.default.enumerator(
            at: bundle, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]))
        return try walker.compactMap { $0 as? URL }.map { url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "\(url.path)|\(values.fileSize ?? -1)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }.sorted()
    }

    func testANewerSchemaIsRefusedInWordsAndTheFolderIsUnchanged() throws {
        // Schema 2 is the cell map's (5.5 L2), so the first newer schema is 3.
        let bundle = try makeBundle(manifest: #"{"schemaVersion": 3, "kind": "rnaseq-result", "modality": 7, "later": [1]}"#)
        let before = try listing(of: bundle)
        let words = "This RNA-seq result was written by a newer LGE (schema 3). Open it with that version or a later one."
        XCTAssertThrowsError(try RNASeqResultBundle.load(from: bundle)) { XCTAssertEqual($0.localizedDescription, words) }
        XCTAssertThrowsError(try RNASeqResultBundle.loadManifest(from: bundle)) { XCTAssertEqual($0.localizedDescription, words) }
        XCTAssertEqual(try listing(of: bundle), before, "a read writes nothing")
    }

    func testAMissingOrUnreadableManifestGivesTheNoManifestWords() throws {
        for text in [nil, "{ not json"] as [String?] {
            let bundle = try makeBundle(manifest: text)
            XCTAssertThrowsError(try RNASeqResultBundle.load(from: bundle)) {
                XCTAssertEqual($0.localizedDescription, "The RNA-seq result has no readable manifest.")
            }
            try FileManager.default.removeItem(at: bundle)
        }
    }

    func testASingleCellManifestDecodesAndLoadingOpensNoFileUnderSource() throws {
        let bundle = try makeBundle(manifest: manifestJSON())
        let result = try RNASeqResultBundle.load(from: bundle) // no source/ folder exists, so any open under it would throw
        let matrix = try XCTUnwrap(result.manifest.matrices?.first)
        XCTAssertEqual(result.manifest.modality, .singleCell)
        XCTAssertNil(result.manifest.referenceSet)
        XCTAssertNil(result.manifest.cellsSummary)
        XCTAssertEqual(matrix.matrix.path, "source/pbmc/Solo.out/Gene/filtered/matrix.mtx")
        for name in ["matrix.mtx", "features.tsv", "barcodes.tsv"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: RNASeqFixtures.starsoloFiltered.appendingPathComponent(name).path))
        }
        XCTAssertFalse(OpenFileProbe.process(getpid(), holdsOpen: bundle.appendingPathComponent(matrix.matrix.path).path))
        XCTAssertEqual(result.samples.map(\.id), ["pbmc"])
        XCTAssertEqual(result.genes.map(\.id), ["G1"])
        XCTAssertTrue(result.counts.isEmpty)
    }

    func testAManifestPathOutsideTheBundleIsRefused() throws {
        let bundle = try makeBundle(manifest: manifestJSON(samplesPath: "../outside.tsv"))
        XCTAssertThrowsError(try RNASeqResultBundle.load(from: bundle)) { error in
            guard case .unreadableFile(let path, _)? = error as? RNASeqResultError else { return XCTFail("\(error)") }
            XCTAssertEqual(path, "../outside.tsv")
        }
    }

    func testAMatrixListedUnderSourceFilesAndMatricesIsReportedOnce() throws {
        let filtered = "source/pbmc/Solo.out/Gene/filtered"
        let names = ["matrix.mtx", "features.tsv", "barcodes.tsv"]
        let listed = names.map { #"{"path": "\#(filtered)/\#($0)", "sha256": "0", "size": 1, "sample": "pbmc", "tool": "STARsolo"}"# }
            .joined(separator: ", ")
        let manifest = manifestJSON().replacingOccurrences(of: #""sourceFiles": []"#, with: #""sourceFiles": [\#(listed)]"#)
        XCTAssertNotEqual(manifest, manifestJSON())
        let bundle = try makeBundle(manifest: manifest)
        let directory = bundle.appendingPathComponent(filtered, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in names { try Data("x".utf8).write(to: directory.appendingPathComponent(name)) }
        let mismatches = try RNASeqResultBundle.verifyChecksums(of: bundle)
        for name in names { XCTAssertEqual(mismatches.filter { $0.path.hasSuffix("/" + name) }.count, 1, name) }
    }

    func testAGeneTableWithAnUnknownNotHostWordIsRefused() throws {
        let bundle = try makeBundle(manifest: manifestJSON())
        let genes = bundle.appendingPathComponent("genes.tsv")
        for word in ["yes", "1", "T"] {
            try Data("gene_id\tnot_host\nG1\t\(word)\n".utf8).write(to: genes)
            XCTAssertThrowsError(try RNASeqResultBundle.load(from: bundle), word) { error in
                guard case .invalidTable(let path, _)? = error as? RNASeqResultError else { return XCTFail("\(error)") }
                XCTAssertEqual(path, "genes.tsv")
                XCTAssertTrue(error.localizedDescription.contains("not_host"), error.localizedDescription)
            }
        }
        try Data("gene_id\tnot_host\nG1\ttrue\nG2\tfalse\nG3\t\n".utf8).write(to: genes)
        XCTAssertEqual(try RNASeqResultBundle.load(from: bundle).genes.map(\.notHost), [true, false, nil])
    }

    func testAResultWithNoQualityKeyReadsQualityAsNotRecorded() throws {
        let bundle = try makeBundle(manifest: manifestJSON())
        let result = try RNASeqResultBundle.load(from: bundle)
        XCTAssertNil(result.manifest.quality)
        XCTAssertNil(result.quality)
    }
}
