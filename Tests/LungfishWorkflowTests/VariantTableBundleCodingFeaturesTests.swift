// VariantTableBundleCodingFeaturesTests.swift - The bundle-wide CDS read of the variant table's derived columns
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.38 M2 (BIO ruling on M854 items 6 and 7, R-QB2 item 1, V1-1 item 4).

import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class VariantTableBundleCodingFeaturesTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("VariantTableBundleCodingFeatures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private static func row(_ chromosome: String, _ start: Int, _ ref: String?) -> AnnotationSearchResult {
        AnnotationSearchResult(
            name: "v\(start)", chromosome: chromosome, start: start, end: start + 1, trackId: "calls", ref: ref, alt: "T"
        )
    }

    /// A bundle of chr1 (100 bases) with two annotation tracks. `b` ("B") comes first in the manifest. It holds the
    /// spliced `cdsS` ([0,10) and [90,100)), `cdsI` whose intron ([35,75)) holds base 55, `cdsB1` ([50,60)) and a gene.
    /// `a` has no name and holds `cdsA` ([0,60)).
    private func makeBundle() throws -> ReferenceBundle {
        let bundleURL = folder.appendingPathComponent("fixture.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("annotations", isDirectory: true), withIntermediateDirectories: true
        )
        let tracks = [
            ("b", "chr1\t0\t100\tcdsS\t0\t+\t0\t100\t0,0,0\t2\t10,10\t0,90\tCDS\tgene=gS\n"
                + "chr1\t30\t80\tcdsI\t0\t+\t30\t80\t0,0,0\t2\t5,5\t0,45\tCDS\tgene=gI\n"
                + "chr1\t50\t60\tcdsB1\t0\t+\t50\t60\t0,0,0\t1\t10\t0\tCDS\tgene=gB\n"
                + "chr1\t40\t70\tgeneB\t0\t+\t40\t70\t0,0,0\t1\t30\t0\tgene\tgene=gB\n"),
            ("a", "chr1\t0\t60\tcdsA\t0\t-\t0\t60\t0,0,0\t1\t60\t0\tCDS\tgene=gA\n"),
        ]
        for (id, lines) in tracks {
            let bed = folder.appendingPathComponent("\(id).bed")
            try lines.write(to: bed, atomically: true, encoding: .utf8)
            _ = try AnnotationDatabase.createFromBED(
                bedURL: bed, outputURL: bundleURL.appendingPathComponent("annotations/\(id).db")
            )
        }
        let manifest = BundleManifest(
            name: "fixture",
            identifier: "org.lungfish.test.bundle-coding-features",
            source: SourceInfo(organism: "Test", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai", totalLength: 100,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 100, offset: 6, lineBases: 100, lineWidth: 101)]
            ),
            annotations: [
                AnnotationTrackInfo(id: "b", name: "B", path: "annotations/b.bb", databasePath: "annotations/b.db"),
                AnnotationTrackInfo(id: "a", name: "", path: "annotations/a.bb", databasePath: "annotations/a.db"),
                AnnotationTrackInfo(id: "nodb", name: "No database", path: "annotations/nodb.bb"),
            ]
        )
        try manifest.save(to: bundleURL)
        return ReferenceBundle(url: bundleURL, manifest: manifest)
    }

    /// Item 6. A row covers `[start, start + max(1, ref count))`, rows that overlap or touch merge, a row's chromosome
    /// is read under the reference's name, and the spans come in chromosome and then start order.
    func testSpansMergeRowsThatOverlapOrTouch() {
        let rows = [
            Self.row("chr2", 5, "A"), Self.row("chr1", 20, nil), Self.row("chr1", 11, "AC"), Self.row("chr1", 10, "A"),
            Self.row("1", 12, "G"),
        ]
        let spans = VariantTableBundleCodingFeatures.spans(rows: rows) { $0 == "1" ? "chr1" : $0 }
        XCTAssertEqual(spans.map { "\($0.chromosome) \($0.shownChromosome) \($0.start)-\($0.end)" }, [
            "chr1 1 10-13", "chr1 1 20-21", "chr2 chr2 5-6",
        ])
    }

    /// Items 6 and 7. The named tracks are read in the manifest's order, a CDS met in two spans is kept once, a CDS
    /// whose intron holds the row and a gene are dropped, and a track's CDS keep start order. The new selection names
    /// every track with a database, sorted.
    func testReadKeepsTrackOrderAndEachCDSOnce() throws {
        let bundle = try makeBundle()
        XCTAssertEqual(VariantTableBundleCodingFeatures.trackIDs(bundle: bundle), ["a", "b"])
        let features = try VariantTableBundleCodingFeatures.features(
            bundle: bundle, trackIDs: ["a", "b"], rows: [Self.row("chr1", 55, "C"), Self.row("chr1", 4, "A")],
            referenceChromosome: { $0 }
        )
        XCTAssertEqual(features.map(\.label), ["gS • cdsS", "gB • cdsB1", "gA • cdsA"])
        XCTAssertTrue(features.allSatisfy { $0.codingBases == nil && $0.chromosome == "chr1" })
        let onlyA = try VariantTableBundleCodingFeatures.features(
            bundle: bundle, trackIDs: ["a"], rows: [Self.row("chr1", 4, "A")], referenceChromosome: { $0 }
        )
        XCTAssertEqual(onlyA.map(\.label), ["gA • cdsA"])
        XCTAssertThrowsError(try VariantTableBundleCodingFeatures.features(
            bundle: bundle, trackIDs: ["b", "nodb"], rows: [], referenceChromosome: { $0 }
        )) { error in
            XCTAssertEqual(error as? VariantTableBundleCodingFeatures.UnknownTrack, .init(trackID: "nodb"))
        }
    }

    /// A bundle of chr1 (100 bases) with the one annotation track `trackID`, built from the BED lines `bed`.
    private func makeSingleTrackBundle(trackID: String, bed lines: String) throws -> ReferenceBundle {
        let bundleURL = folder.appendingPathComponent("single-\(trackID).lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("annotations", isDirectory: true), withIntermediateDirectories: true
        )
        let bed = folder.appendingPathComponent("\(trackID).bed")
        try lines.write(to: bed, atomically: true, encoding: .utf8)
        _ = try AnnotationDatabase.createFromBED(
            bedURL: bed, outputURL: bundleURL.appendingPathComponent("annotations/\(trackID).db")
        )
        let manifest = BundleManifest(
            name: "single",
            identifier: "org.lungfish.test.bundle-coding-features-single",
            source: SourceInfo(organism: "Test", assembly: "single"),
            genome: GenomeInfo(
                path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai", totalLength: 100,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 100, offset: 6, lineBases: 100, lineWidth: 101)]
            ),
            annotations: [
                AnnotationTrackInfo(
                    id: trackID, name: trackID.uppercased(), path: "annotations/\(trackID).bb",
                    databasePath: "annotations/\(trackID).db"
                ),
            ]
        )
        try manifest.save(to: bundleURL)
        return ReferenceBundle(url: bundleURL, manifest: manifest)
    }

    /// BIO review of 13.38, Fix 1. The database lists a track by start, end and then name under SQLite's NOCASE
    /// collation (`AnnotationDatabase+Query.swift`), and the viewer, the 2.12 leaf and F11 keep that order. Two CDS with
    /// one start and end and the names `BB` and `aa` list `aa` first, where a code-point `<` on the names puts `BB` first.
    func testReadKeepsTheDatabaseNocaseNameOrderForTiedCDS() throws {
        let bundle = try makeSingleTrackBundle(
            trackID: "n",
            bed: "chr1\t0\t30\tBB\t0\t+\t0\t30\t0,0,0\t1\t30\t0\tCDS\tgene=gBB\n"
                + "chr1\t0\t30\taa\t0\t+\t0\t30\t0,0,0\t1\t30\t0\tCDS\tgene=gaa\n"
        )
        let features = try VariantTableBundleCodingFeatures.features(
            bundle: bundle, trackIDs: ["n"], rows: [Self.row("chr1", 4, "A")], referenceChromosome: { $0 }
        )
        XCTAssertEqual(features.map(\.label), ["gaa • aa", "gBB • BB"])
    }

    /// R-QB2 item 1. A read that returns its limit fails with the ruled words, naming the first such read in track
    /// and span order, the track's name or its id when the name is empty, the shown chromosome and the span 1-based.
    func testReadAtTheLimitFailsWithTheRuledWords() throws {
        let bundle = try makeBundle()
        let rows = [Self.row("chr1", 55, "C"), Self.row("chr1", 4, "A")]
        XCTAssertThrowsError(try VariantTableBundleCodingFeatures.features(
            bundle: bundle, trackIDs: ["a", "b"], rows: rows, referenceChromosome: { $0 }, limit: 2
        )) { error in
            XCTAssertEqual(error.localizedDescription, "The annotation track B holds at least 2 annotations in chr1:56-56, "
                + "the most the export reads from one track at a time, so the Gene / Protein, Consequence and AA Change "
                + "cells of the variants there could miss a coding feature. No file was written. Export fewer of the "
                + "variants in that span at a time.")
        }
        XCTAssertThrowsError(try VariantTableBundleCodingFeatures.features(
            bundle: bundle, trackIDs: ["a"], rows: rows, referenceChromosome: { $0 }, limit: 1
        )) { error in
            XCTAssertEqual(
                (error as? VariantTableBundleCodingFeatures.LimitReached)?.trackName, "a", "the id when the name is empty"
            )
        }
        XCTAssertEqual(VariantTableBundleCodingFeatures.grouped(VariantTableBundleCodingFeatures.annotationLimit), "50,000")
        XCTAssertEqual(VariantTableBundleCodingFeatures.grouped(999), "999")
        XCTAssertEqual(VariantTableBundleCodingFeatures.grouped(1_234_567), "1,234,567")
    }
}
