// FASTQDerivedBundleManifestPlaceholderMarkTests.swift - The mark that says a bundle's quality scores were never measured
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 5.6 S1 sweep, lane QUALITY-2 (ONT-FLUIDIGM-INVENTED-Q, ruling BIO-QUALITY F1). Reads built from sequence counts
// carry a written Q40 on every base that no instrument measured. The manifest holds `qualityScoresArePlaceholders`,
// written only when true, and `FASTQQualityScoreOrigin` is the one reader of it. Bundles the Fluidigm materializers
// wrote before the field existed are recognized by their operation and library prep.

import XCTest
@testable import LungfishIO

final class FASTQDerivedBundleManifestPlaceholderMarkTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("placeholder-mark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func manifest(
        kind: FASTQDerivativeOperationKind = .demultiplex,
        libraryPrep: String? = nil,
        mark: Bool? = nil
    ) -> FASTQDerivedBundleManifest {
        let operation = FASTQDerivativeOperation(kind: kind)
        return FASTQDerivedBundleManifest(
            name: "LF2871",
            parentBundleRelativePath: ".",
            rootBundleRelativePath: ".",
            rootFASTQFilename: "reads.fastq.gz",
            payload: .full(fastqFilename: "reads.fastq.gz"),
            lineage: [operation],
            operation: operation,
            cachedStatistics: .empty,
            pairingMode: nil,
            provenance: libraryPrep.map { SampleProvenance(libraryPrep: $0) },
            qualityScoresArePlaceholders: mark
        )
    }

    /// Saves `manifest` in a new bundle that holds an empty payload file, and returns both.
    private func bundle(holding manifest: FASTQDerivedBundleManifest) throws -> (bundle: URL, reads: URL) {
        let bundle = root.appendingPathComponent("\(UUID().uuidString).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let reads = bundle.appendingPathComponent("reads.fastq.gz")
        try Data().write(to: reads)
        try FASTQBundle.saveDerivedManifest(manifest, in: bundle)
        return (bundle, reads)
    }

    private func writtenKeys(of bundle: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: FASTQBundle.derivedManifestURL(in: bundle))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTheMarkIsWrittenOnlyWhenTrue() throws {
        let marked = try bundle(holding: manifest(mark: true))
        XCTAssertEqual(try writtenKeys(of: marked.bundle)["qualityScoresArePlaceholders"] as? Bool, true)
        XCTAssertEqual(FASTQBundle.loadDerivedManifest(in: marked.bundle)?.qualityScoresArePlaceholders, true)

        for mark in [nil, false] as [Bool?] {
            let plain = try bundle(holding: manifest(mark: mark))
            XCTAssertNil(
                try writtenKeys(of: plain.bundle)["qualityScoresArePlaceholders"],
                "mark \(String(describing: mark)) writes no key"
            )
            XCTAssertNil(FASTQBundle.loadDerivedManifest(in: plain.bundle)?.qualityScoresArePlaceholders)
        }

        // A manifest from a file that says false reads as no mark, so only a true mark is ever carried.
        var keys = try writtenKeys(of: marked.bundle)
        keys["qualityScoresArePlaceholders"] = false
        try JSONSerialization.data(withJSONObject: keys).write(to: FASTQBundle.derivedManifestURL(in: marked.bundle))
        XCTAssertNil(FASTQBundle.loadDerivedManifest(in: marked.bundle)?.qualityScoresArePlaceholders)
    }

    func testTheReaderReadsTheMarkForTheBundleAndForTheFileInsideIt() throws {
        let marked = try bundle(holding: manifest(kind: .subsampleCount, mark: true))
        XCTAssertTrue(FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: marked.reads))
        XCTAssertTrue(FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: marked.bundle))
    }

    /// Bundles the Fluidigm materializers wrote before the field existed hold a demultiplex operation and a library
    /// prep that begins "Fluidigm Access Array", and read as placeholder all the same.
    func testTheReaderRecognizesBundlesMadeBeforeTheMark() throws {
        for libraryPrep in ["Fluidigm Access Array", "Fluidigm Access Array MHC amplicon"] {
            let legacy = try bundle(holding: manifest(libraryPrep: libraryPrep))
            XCTAssertTrue(
                FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: legacy.reads),
                "\(libraryPrep) with no mark"
            )
        }
    }

    func testTheReaderIsFalseForScoredReadsAndForFilesOutsideABundle() throws {
        for scored in [
            manifest(libraryPrep: nil),
            manifest(libraryPrep: "Illumina DNA Prep"),
            manifest(kind: .subsampleCount, libraryPrep: "Fluidigm Access Array"),
        ] {
            let held = try bundle(holding: scored)
            XCTAssertFalse(
                FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: held.reads),
                "\(scored.operation.kind) with library prep \(String(describing: scored.provenance?.libraryPrep))"
            )
        }

        let noManifest = root.appendingPathComponent("bare.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: noManifest, withIntermediateDirectories: true)
        XCTAssertFalse(FASTQQualityScoreOrigin.readsCarryPlaceholderScores(
            fastqURL: noManifest.appendingPathComponent("reads.fastq.gz")
        ), "a bundle with no derived manifest")

        let loose = root.appendingPathComponent("loose.fastq")
        try Data().write(to: loose)
        XCTAssertFalse(FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: loose), "a file in no bundle")
    }

    // MARK: - Datasets made from a Fluidigm bundle before the mark (lane FLUIDIGM-CHILDREN F8)

    /// The statistics a bundle made before the mark stored for reads whose every base is a written Q40.
    private static let storedQ40 = FASTQDatasetStatistics(
        readCount: 4, baseCount: 400, meanReadLength: 100, minReadLength: 88, maxReadLength: 118,
        medianReadLength: 98, n50ReadLength: 108, meanQuality: 40, q20Percentage: 100, q30Percentage: 100,
        gcContent: 0.51, readLengthHistogram: [88: 1, 98: 1, 108: 1, 118: 1], qualityScoreHistogram: [40: 400],
        perPositionQuality: []
    )

    /// A bundle named `name` in the test folder whose manifest, of a subsample with Mean Q 40 and no mark, names the
    /// sibling bundle `parent` as its parent, as the importer writes the field.
    private func derivedBundle(named name: String = UUID().uuidString, parent: String) throws -> (bundle: URL, reads: URL) {
        let bundle = root.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let reads = bundle.appendingPathComponent("reads.fastq.gz")
        try Data().write(to: reads)
        let operation = FASTQDerivativeOperation(kind: .subsampleCount, count: 2)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: name, parentBundleRelativePath: "../\(parent)", rootBundleRelativePath: "../\(parent)",
                rootFASTQFilename: "reads.fastq.gz", payload: .full(fastqFilename: "reads.fastq.gz"),
                lineage: [operation], operation: operation, cachedStatistics: Self.storedQ40, pairingMode: nil
            ),
            in: bundle
        )
        return (bundle, reads)
    }

    /// A dataset made from a Fluidigm bundle before the mark holds no mark and no Fluidigm library prep of its own, and
    /// shows Mean Q 40 after the update unless the reader follows the manifests' parents to the bundle that does
    /// (ruling BIO-FLUIDIGM-CHILDREN F8, FLUIDIGM-OLD-CHILDREN-UNMARKED). Nothing is rewritten.
    func testAChildMadeBeforeTheMarkIsRecognizedThroughItsParent() throws {
        let fluidigm = try bundle(holding: manifest(libraryPrep: "Fluidigm Access Array"))
        let child = try derivedBundle(parent: fluidigm.bundle.lastPathComponent)
        let grandchild = try derivedBundle(parent: child.bundle.lastPathComponent)
        XCTAssertTrue(
            FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: child.reads), "a child of a Fluidigm bundle"
        )
        XCTAssertTrue(
            FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: grandchild.reads),
            "a grandchild of a Fluidigm bundle"
        )
        XCTAssertTrue(
            FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: grandchild.bundle),
            "the grandchild's bundle"
        )

        // Controls: a child of measured reads, a child whose parent is missing, and two manifests that name each other.
        let measured = try bundle(holding: manifest(kind: .subsampleCount))
        let measuredChild = try derivedBundle(parent: measured.bundle.lastPathComponent)
        XCTAssertFalse(
            FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: measuredChild.reads),
            "a child of a measured bundle"
        )
        let orphan = try derivedBundle(parent: "deleted.lungfishfastq")
        XCTAssertFalse(
            FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: orphan.reads), "a child whose parent is missing"
        )
        let first = try derivedBundle(named: "loop-a", parent: "loop-b.lungfishfastq")
        let second = try derivedBundle(named: "loop-b", parent: "loop-a.lungfishfastq")
        XCTAssertFalse(
            FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: first.reads), "two manifests that name each other"
        )
        XCTAssertFalse(FASTQQualityScoreOrigin.readsCarryPlaceholderScores(fastqURL: second.bundle), "the loop from the other side")

        // The reader writes nothing: the child's manifest keeps its stored figures and no mark.
        let stored = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: child.bundle))
        XCTAssertNil(stored.qualityScoresArePlaceholders, "reading a child leaves its manifest as it was")
        XCTAssertEqual(stored.cachedStatistics.meanQuality, 40, "the stored figures are not rewritten")
    }
}
