// TaxonomyBatchBarPercentTests.swift - The Kraken 2 bar and the table give one percent for one row
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow
@testable import LungfishTaxonomyUI

/// Phase 3.2 lane KRAKENBAR (walk row W-22, BIO S1).
///
/// The walk of 2026-11-04 opened a two-sample Kraken 2 batch. One row read 18.5% in the table, which divides by the
/// sample's own reads, and "8.7% of all reads" in the bar, which divided by the reads of both samples. The fixture
/// below carries the walked batch's counts for its first sample (4,819,760 reads, 893,706 classified) and a second
/// sample of 5,440,369 reads, so the two samples' totals differ and a wrong denominator shows.
@MainActor
final class TaxonomyBatchBarPercentTests: XCTestCase {

    private static let first = "SRR12486983"
    private static let second = "SRR12486989"

    /// Kept alive for the test, since a view controller's window is only referenced weakly.
    private var host: NSWindow?

    // MARK: - Fixture

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KrakenBarPercent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func row(
        _ sample: String, _ name: String, _ taxId: Int, _ rank: String, _ rankName: String,
        direct: Int, clade: Int, percent: Double, parent: Int?, depth: Int
    ) -> Kraken2ClassificationRow {
        Kraken2ClassificationRow(
            sample: sample, taxonName: name, taxId: taxId, rank: rank, rankDisplayName: rankName,
            readsDirect: direct, readsClade: clade, percentage: percent, parentTaxId: parent,
            depth: depth, fractionDirect: 0
        )
    }

    /// A batch database holding the named samples, each with the per-sample total keys the writers record.
    private func makeBatchDatabase(in dir: URL, samples: [String]) throws -> Kraken2Database {
        var rows: [Kraken2ClassificationRow] = []
        var metadata: [String: String] = [:]
        if samples.contains(Self.first) {
            let s = Self.first
            rows += [
                row(s, "root", 1, "R", "Root", direct: 0, clade: 893_706, percent: 18.54, parent: nil, depth: 0),
                row(s, "Viruses", 10239, "D", "Domain", direct: 93_706, clade: 893_706, percent: 18.54, parent: 1, depth: 1),
                row(s, "Severe acute respiratory syndrome coronavirus 2", 2697049, "S", "Species",
                    direct: 400_000, clade: 400_000, percent: 8.30, parent: 10239, depth: 2),
                row(s, "Influenza A virus", 11320, "S", "Species",
                    direct: 400_000, clade: 400_000, percent: 8.30, parent: 10239, depth: 2),
            ]
            metadata["total_reads_\(s)"] = "4819760"
            metadata["classified_reads_\(s)"] = "893706"
            metadata["unclassified_reads_\(s)"] = "3926054"
        }
        if samples.contains(Self.second) {
            let s = Self.second
            rows += [
                row(s, "root", 1, "R", "Root", direct: 0, clade: 1_360_092, percent: 25.00, parent: nil, depth: 0),
                row(s, "Viruses", 10239, "D", "Domain", direct: 0, clade: 1_360_092, percent: 25.00, parent: 1, depth: 1),
                row(s, "Influenza A virus", 11320, "S", "Species",
                    direct: 680_046, clade: 680_046, percent: 12.50, parent: 10239, depth: 2),
                row(s, "Human betaherpesvirus 5", 10359, "S", "Species",
                    direct: 680_046, clade: 680_046, percent: 12.50, parent: 10239, depth: 2),
            ]
            metadata["total_reads_\(s)"] = "5440369"
            metadata["classified_reads_\(s)"] = "1360092"
            metadata["unclassified_reads_\(s)"] = "4080277"
        }
        return try Kraken2Database.create(
            at: dir.appendingPathComponent("kraken2.sqlite"), rows: rows, metadata: metadata
        )
    }

    /// Opens the database in a view controller, as the batch route does, with every sample selected.
    private func openBatch(_ db: Kraken2Database, in dir: URL) -> TaxonomyViewController {
        let vc = TaxonomyViewController()
        isolateLayouts(vc)
        _ = vc.view
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = NSView(frame: window.frame)
        window.contentView?.addSubview(vc.view)
        host = window
        vc.batchURL = dir
        vc.configureFromDatabase(db)
        vc.testTableView.expandAll()
        vc.testTableView.outlineView.layoutSubtreeIfNeeded()
        return vc
    }

    private func find(_ taxId: Int, in node: TaxonNode) -> TaxonNode? {
        if node.taxId == taxId { return node }
        for child in node.children {
            if let hit = find(taxId, in: child) { return hit }
        }
        return nil
    }

    /// The taxon `taxId` under the synthetic node of `sample` in a merged tree.
    private func node(in root: TaxonNode, underSample sample: String, taxId: Int) throws -> TaxonNode {
        let sampleNode = try XCTUnwrap(
            root.children.first { $0.taxId < 0 && $0.name == sample }, "The merged tree has no node for \(sample)"
        )
        return try XCTUnwrap(find(taxId, in: sampleNode), "\(sample) holds no taxon \(taxId)")
    }

    /// Picks `node` in the table as a click does, then returns the table's percent cell and the bar's words.
    private func pick(_ node: TaxonNode, in vc: TaxonomyViewController) throws -> (table: String, bar: String) {
        let outline = vc.testTableView.outlineView
        let rowIndex = outline.row(forItem: node)
        XCTAssertGreaterThanOrEqual(rowIndex, 0, "\(node.name) is not a visible row")
        outline.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
        let column = outline.column(withIdentifier: NSUserInterfaceItemIdentifier("percent"))
        XCTAssertGreaterThanOrEqual(column, 0, "The table has no % column")
        let cell = try XCTUnwrap(outline.view(atColumn: column, row: rowIndex, makeIfNecessary: true) as? NSTableCellView)
        return (cell.textField?.stringValue ?? "", vc.testActionBar.infoLabel.stringValue)
    }

    // MARK: - The bar and the table

    /// W-22. S1's Viruses row reads 18.5% in the table, so the bar must give 18.5%, never 8.7%.
    func testBatchBarPercentEqualsTablePercentForSameRow() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vc = openBatch(try makeBatchDatabase(in: dir, samples: [Self.first, Self.second]), in: dir)
        let tree = try XCTUnwrap(vc.testTableView.tree)
        XCTAssertEqual(tree.root.children.count, 2, "Both samples are selected, so the table holds the merged tree")

        let viruses = try node(in: tree.root, underSample: Self.first, taxId: 10239)
        let shown = try pick(viruses, in: vc)

        XCTAssertEqual(shown.table, "18.5%", "The table divides by the sample's own 4,819,760 reads")
        XCTAssertTrue(shown.bar.contains("893,706 reads"), "The bar gives the row's reads: \(shown.bar)")
        XCTAssertTrue(
            shown.bar.contains(shown.table),
            "The bar says '\(shown.bar)' but the table row says \(shown.table), the same row under the same words"
        )
        XCTAssertFalse(shown.bar.contains("8.7%"), "8.7% divides by the reads of both samples: \(shown.bar)")
        XCTAssertTrue(
            shown.bar.contains(Self.first),
            "A percent in a batch view names the sample whose reads it divides by: \(shown.bar)"
        )
    }

    /// The second sample divides by its own total, not by the first selected sample's and not by the batch's.
    func testBatchBarPercentUsesTheOwningSamplesOwnTotalForTheSecondSample() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vc = openBatch(try makeBatchDatabase(in: dir, samples: [Self.first, Self.second]), in: dir)
        let tree = try XCTUnwrap(vc.testTableView.tree)

        let flu = try node(in: tree.root, underSample: Self.second, taxId: 11320)
        let shown = try pick(flu, in: vc)

        XCTAssertEqual(shown.table, "12.5%", "680,046 of the second sample's 5,440,369 reads")
        XCTAssertTrue(shown.bar.contains(shown.table), "Bar '\(shown.bar)' against table \(shown.table)")
        XCTAssertFalse(shown.bar.contains("6.6%"), "6.6% divides by the reads of both samples: \(shown.bar)")
        XCTAssertFalse(shown.bar.contains("14.1%"), "14.1% divides by the first sample's reads: \(shown.bar)")
        XCTAssertTrue(shown.bar.contains(Self.second), "The bar names its sample: \(shown.bar)")
    }

    /// A deeper row of the first sample, so the fix is not specific to a depth-one taxon.
    func testBatchBarPercentEqualsTablePercentForASpeciesRow() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vc = openBatch(try makeBatchDatabase(in: dir, samples: [Self.first, Self.second]), in: dir)
        let tree = try XCTUnwrap(vc.testTableView.tree)

        let species = try node(in: tree.root, underSample: Self.first, taxId: 2697049)
        let shown = try pick(species, in: vc)

        XCTAssertEqual(shown.table, "8.3%")
        XCTAssertTrue(shown.bar.contains(shown.table), "Bar '\(shown.bar)' against table \(shown.table)")
    }

    /// A one-sample result has no other sample to confuse, so its bar keeps its words and its number.
    func testSingleSampleBarKeepsItsWordsAndPercent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vc = openBatch(try makeBatchDatabase(in: dir, samples: [Self.first]), in: dir)
        let tree = try XCTUnwrap(vc.testTableView.tree)

        let viruses = try XCTUnwrap(tree.node(taxId: 10239))
        let shown = try pick(viruses, in: vc)

        XCTAssertEqual(shown.table, "18.5%")
        XCTAssertTrue(
            shown.bar.contains("Viruses \u{2014} 893,706 reads (18.5% of all reads)"),
            "A single sample's bar reads as it always has: \(shown.bar)"
        )
    }

    // MARK: - The sunburst centre

    /// The centre of a zoomed sunburst says "of classified". In the merged tree the classified reads of the tree are
    /// the batch's total, so a row of one sample read 3.9% of classified where the sample's own share is 44.8%.
    func testMergedTreeCentreTextDividesByTheOwningSamplesClassifiedReads() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeBatchDatabase(in: dir, samples: [Self.first, Self.second])
        let merged = Kraken2TaxonomyTableExport.mergedTree(for: [
            (sampleId: Self.first, tree: try db.fetchTree(sample: Self.first)),
            (sampleId: Self.second, tree: try db.fetchTree(sample: Self.second)),
        ])

        let species = try node(in: merged.root, underSample: Self.first, taxId: 2697049)
        XCTAssertEqual(
            TaxonomySunburstView.centerPercentText(for: species, isZoomed: true, tree: merged),
            "44.8% of classified",
            "400,000 of the first sample's 893,706 classified reads"
        )
        let flu = try node(in: merged.root, underSample: Self.second, taxId: 11320)
        XCTAssertEqual(
            TaxonomySunburstView.centerPercentText(for: flu, isZoomed: true, tree: merged),
            "50.0% of classified",
            "680,046 of the second sample's 1,360,092 classified reads"
        )
    }

    // MARK: - The read base

    /// Every node of a merged tree divides by its own sample's counts, and the tree's own counts stay the batch's.
    func testReadBaseGivesEachSampleItsOwnCounts() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeBatchDatabase(in: dir, samples: [Self.first, Self.second])
        let firstTree = try db.fetchTree(sample: Self.first)
        let merged = Kraken2TaxonomyTableExport.mergedTree(for: [
            (sampleId: Self.first, tree: firstTree),
            (sampleId: Self.second, tree: try db.fetchTree(sample: Self.second)),
        ])

        let species = merged.readBase(for: try node(in: merged.root, underSample: Self.first, taxId: 2697049))
        XCTAssertEqual(species.totalReads, 4_819_760)
        XCTAssertEqual(species.classifiedReads, 893_706)
        XCTAssertEqual(species.sampleName, Self.first)
        XCTAssertFalse(species.spansSamples)

        let flu = merged.readBase(for: try node(in: merged.root, underSample: Self.second, taxId: 11320))
        XCTAssertEqual(flu.totalReads, 5_440_369)
        XCTAssertEqual(flu.classifiedReads, 1_360_092)
        XCTAssertEqual(flu.sampleName, Self.second)

        let sampleNode = try XCTUnwrap(merged.root.children.first { $0.name == Self.second })
        XCTAssertEqual(merged.readBase(for: sampleNode).totalReads, 5_440_369, "A sample's own node divides by its reads")

        let whole = merged.readBase(for: merged.root)
        XCTAssertEqual(whole.totalReads, 10_260_129, "The merged root is the whole selection")
        XCTAssertNil(whole.sampleName)
        XCTAssertTrue(whole.spansSamples)

        let single = firstTree.readBase(for: try XCTUnwrap(firstTree.node(taxId: 10239)))
        XCTAssertEqual(single.totalReads, 4_819_760, "A tree of one sample uses its own counts")
        XCTAssertNil(single.sampleName)
        XCTAssertFalse(single.spansSamples)
    }

    /// The wedge that sums small taxa is never linked into the tree, so it names the selection, not a sample.
    func testBarWordsSayWhichReadsAnUnlinkedWedgeDividesBy() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeBatchDatabase(in: dir, samples: [Self.first, Self.second])
        let merged = Kraken2TaxonomyTableExport.mergedTree(for: [
            (sampleId: Self.first, tree: try db.fetchTree(sample: Self.first)),
            (sampleId: Self.second, tree: try db.fetchTree(sample: Self.second)),
        ])
        let wedge = TaxonNode(
            taxId: 10239, name: "3 smaller taxa under Viruses", rank: TaxonomicRank(code: "Aggregated"), depth: 3,
            readsDirect: 0, readsClade: 1_000_000, fractionClade: 0, fractionDirect: 0, parentTaxId: 10239
        )

        let words = TaxonomyBarWords.selection(for: wedge, base: merged.readBase(for: wedge))
        XCTAssertEqual(
            words,
            "3 smaller taxa under Viruses \u{2014} 1,000,000 reads (9.7% of all reads in the selected samples)"
        )
    }

    /// With no known total the bar gives the reads and no percent, never a percent of nothing.
    func testBarWordsOmitThePercentWhenTheSampleTotalIsUnknown() throws {
        let virus = TaxonNode(
            taxId: 10239, name: "Viruses", rank: TaxonomicRank(code: "D"), depth: 1,
            readsDirect: 0, readsClade: 893_706, fractionClade: 0, fractionDirect: 0, parentTaxId: 1
        )
        XCTAssertEqual(TaxonomyBarWords.selection(for: virus, base: nil), "Viruses \u{2014} 893,706 reads")
    }

    // MARK: - The tooltip

    /// Review B1. The tooltip of the wedge that sums small taxa asked the tree about a node that is never linked into
    /// it, found no sample and divided by the reads of both samples: 10 reads of the first sample read as a share of
    /// 10,260,129 where the sample holds 4,819,760. The wedge's segment now names the node whose small taxa it sums.
    func testTooltipOfAnAggregateWedgeInAMergedTreeDividesByTheOwnersSample() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try makeBatchDatabase(in: dir, samples: [Self.first, Self.second])
        let firstTree = try db.fetchTree(sample: Self.first)
        let secondTree = try db.fetchTree(sample: Self.second)
        // One taxon in each sample is far below the drawing threshold, so the layout sums it into a wedge.
        for (tree, reads) in [(firstTree, 10), (secondTree, 20)] {
            try XCTUnwrap(tree.node(taxId: 10239)).addChild(TaxonNode(
                taxId: 900_000 + reads, name: "Small virus \(reads)", rank: TaxonomicRank(code: "S"), depth: 2,
                readsDirect: reads, readsClade: reads, fractionClade: 0, fractionDirect: 0, parentTaxId: 10239
            ))
        }
        let merged = Kraken2TaxonomyTableExport.mergedTree(for: [
            (sampleId: Self.first, tree: firstTree),
            (sampleId: Self.second, tree: secondTree),
        ])
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 600)
        let segments = SunburstLayout(tree: merged, bounds: bounds).computeSegments()
        let wedges = segments.filter(\.isOther)
        XCTAssertEqual(wedges.count, 2, "Each sample sums its one small taxon into a wedge")

        let firstWedge = try XCTUnwrap(wedges.first { $0.node.readsClade == 10 })
        let firstBase = TaxonomySunburstView.tooltipReadBase(for: firstWedge.node, segments: segments, tree: merged)
        XCTAssertEqual(firstBase.totalReads, 4_819_760, "The wedge belongs to the first sample, not to both samples' 10,260,129")
        XCTAssertEqual(firstBase.sampleName, Self.first)
        XCTAssertFalse(firstBase.spansSamples)

        let secondWedge = try XCTUnwrap(wedges.first { $0.node.readsClade == 20 })
        let secondBase = TaxonomySunburstView.tooltipReadBase(for: secondWedge.node, segments: segments, tree: merged)
        XCTAssertEqual(secondBase.totalReads, 5_440_369, "The wedge belongs to the second sample")
        XCTAssertEqual(secondBase.sampleName, Self.second)

        let species = try node(in: merged.root, underSample: Self.first, taxId: 2697049)
        let speciesBase = TaxonomySunburstView.tooltipReadBase(for: species, segments: segments, tree: merged)
        XCTAssertEqual(speciesBase.totalReads, 4_819_760, "A drawn taxon still asks the tree")
        XCTAssertEqual(speciesBase.sampleName, Self.first)

        let singleSegments = SunburstLayout(tree: firstTree, bounds: bounds).computeSegments()
        let singleWedge = try XCTUnwrap(singleSegments.first { $0.isOther })
        let singleBase = TaxonomySunburstView.tooltipReadBase(for: singleWedge.node, segments: singleSegments, tree: firstTree)
        XCTAssertEqual(singleBase.totalReads, 4_819_760, "A tree of one sample gives the wedge its own counts")
        XCTAssertNil(singleBase.sampleName)
        XCTAssertFalse(singleBase.spansSamples)
    }
}
