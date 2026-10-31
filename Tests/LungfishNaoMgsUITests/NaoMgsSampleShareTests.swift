// NaoMgsSampleShareTests.swift - A taxon's share of its sample is in one unit on every load path
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
@testable import LungfishNaoMgsUI
@testable import LungfishIO
@testable import LungfishKit
import LungfishTestSupport

/// BIO-NAOMGS-UNIQUE-READS-UNIT, Q3 items 4 and 5. One NAO-MGS row is a read pair and the taxon table counts each
/// mate, so the total a share divides by has to count mates on both load paths, and the two count columns say so.
@MainActor
final class NaoMgsSampleShareTests: XCTestCase {
    private static let sample = "walk_sample"

    /// The cached load path totals the loaded taxon rows. The manifest's hit count counts NAO-MGS rows (read pairs),
    /// so dividing the taxa's mates by it would double every paired-end share.
    func testCachedLoadTotalsTheTaxonRowsNotTheManifestRowCount() {
        let controller = makeController()
        // The walk's sample: 14 read pairs of Rotavirus A (28 mates) and 6 of Human rotavirus A (12 mates).
        let rows = [
            Self.cachedRow(taxId: 28875, name: "Rotavirus A", hitCount: 28),
            Self.cachedRow(taxId: 10941, name: "Human rotavirus A", hitCount: 12),
        ]
        let manifest = NaoMgsManifest(
            sampleName: Self.sample,
            sourceFilePath: "/tmp/naomgs.tsv",
            hitCount: 20,
            taxonCount: 2,
            topTaxon: "Rotavirus A",
            topTaxonId: 28875
        )
        controller.configureWithCachedRows(rows, manifest: manifest, awaitingDatabase: false)
        XCTAssertEqual(
            controller.naoMgsTotalHits, 40,
            "The total is the sum of the taxa's mates, not the manifest's 20 read pairs"
        )
    }

    /// The database load path: the action bar divides a taxon's mates by the sample's mates.
    func testActionBarShareOfAPairedTaxonDividesMatesByMates() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NaoMgsSampleShare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Two taxa with one concordant pair each: two mates a taxon and four mates in the sample.
        let input = directory.appendingPathComponent("virus_hits_final.tsv")
        try Self.pairedTSV(taxa: [(28875, "JN258371.1"), (10941, "KP198630.1")])
            .write(to: input, atomically: true, encoding: .utf8)
        let databaseURL = directory.appendingPathComponent("hits.sqlite")
        _ = try await NaoMgsDatabase.createStreaming(at: databaseURL, from: [input])
        let database = try NaoMgsDatabase(at: databaseURL)
        let manifest = NaoMgsManifest(
            sampleName: Self.sample,
            sourceFilePath: input.path,
            hitCount: 2,
            taxonCount: 2,
            topTaxon: "Rotavirus A",
            topTaxonId: 28875
        )

        let controller = makeController()
        controller.testDisableMiniBAMLoading = true
        controller.configure(database: database, manifest: manifest, bundleURL: directory)
        XCTAssertEqual(controller.naoMgsTotalHits, 4, "The result total is four mates, not two read pairs")

        controller.testTaxonomyTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let info = controller.actionBar.infoLabel.stringValue
        XCTAssertTrue(
            info.hasSuffix("2 hits (50.0%)"),
            "One of two equal paired taxa is half of its sample, and the bar reads \"\(info)\""
        )
    }

    /// The two count columns name the unit: each mate of a read pair is one read.
    func testCountColumnTooltipsNameTheMateUnit() throws {
        let controller = makeController()
        controller.configureWithCachedRows(
            [Self.cachedRow(taxId: 28875, name: "Rotavirus A", hitCount: 28)],
            manifest: NaoMgsManifest(
                sampleName: Self.sample,
                sourceFilePath: "/tmp/naomgs.tsv",
                hitCount: 14,
                taxonCount: 1,
                topTaxon: "Rotavirus A",
                topTaxonId: 28875
            ),
            awaitingDatabase: false
        )
        let columns = controller.testTaxonomyTableView.tableColumns
        let hits = try XCTUnwrap(columns.first { $0.identifier.rawValue == "hits" })
        let unique = try XCTUnwrap(columns.first { $0.identifier.rawValue == "unique" })
        XCTAssertEqual(
            hits.headerToolTip,
            "Aligned reads assigned to this taxon. Each mate of a read pair counts as one read, as in the BAM; one NAO-MGS row is one read pair."
        )
        XCTAssertEqual(
            unique.headerToolTip,
            "Aligned reads assigned to this taxon after duplicates are set aside. Each mate of a read pair counts as one read, so a pair with both mates aligned counts as two."
        )
    }

    // MARK: - Helpers

    private func makeController() -> NaoMgsResultViewController {
        let controller = NaoMgsResultViewController()
        controller.metadataColumnController.userDefaults = makeTestDefaultsSuite(prefix: "NaoMgsSampleShare").defaults
        controller.loadViewIfNeeded()
        return controller
    }

    private static func cachedRow(taxId: Int, name: String, hitCount: Int) -> NaoMgsTaxonSummaryRow {
        NaoMgsTaxonSummaryRow(
            sample: sample,
            taxId: taxId,
            name: name,
            hitCount: hitCount,
            uniqueReadCount: hitCount,
            avgIdentity: 99,
            avgBitScore: 200,
            avgEditDistance: 1,
            pcrDuplicateCount: 0,
            accessionCount: 1,
            topAccessions: ["JN258371.1"],
            bamPath: nil,
            bamIndexPath: nil
        )
    }

    /// A NAO-MGS v2 TSV with one concordant read pair a taxon, so every row carries both mates.
    private static func pairedTSV(taxa: [(taxId: Int, accession: String)]) -> String {
        let columns = [
            "sample", "seq_id", "aligner_taxid_lca", "query_seq", "query_seq_rev", "query_qual", "query_qual_rev",
            "prim_align_genome_id_all", "prim_align_ref_start", "prim_align_ref_start_rev",
            "prim_align_edit_distance", "prim_align_edit_distance_rev", "query_len", "query_len_rev",
            "prim_align_query_rc", "prim_align_query_rc_rev", "prim_align_pair_status",
            "prim_align_best_alignment_score", "prim_align_best_alignment_score_rev",
            "prim_align_fragment_length", "prim_align_cigar", "prim_align_subject_title",
        ]
        var lines = [columns.joined(separator: "\t")]
        for (index, taxon) in taxa.enumerated() {
            lines.append([
                sample, "read_\(index)", String(taxon.taxId), "ACGTACGT", "TGCATGCA", "IIIIIIII", "JJJJJJJJ",
                taxon.accession, "100", "240", "0", "0", "8", "8", "False", "True", "CP", "90", "88", "148", "8M",
                "Virus \(taxon.taxId)",
            ].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
