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
}
