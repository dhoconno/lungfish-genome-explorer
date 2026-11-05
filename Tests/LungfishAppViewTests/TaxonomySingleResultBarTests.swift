// TaxonomySingleResultBarTests.swift - The bar of one opened Kraken 2 result keeps its words and its percent
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow
@testable import LungfishTaxonomyUI

/// Phase 3.2 lane KRAKENBAR, review item S-2.
///
/// The common route opens one classification result through `configure(result:)`. The lane deleted the
/// `totalReadsForActionBar` field that route fed, so this pins the words and the percent it gives. They did not
/// change, so the test passes before and after the lane. The expected percent is computed from the old expression,
/// the row's reads over the result's total reads.
@MainActor
final class TaxonomySingleResultBarTests: XCTestCase {

    /// Kept alive for the test, since a view controller's window is only referenced weakly.
    private var host: NSWindow?

    func testSingleResultBarKeepsItsWordsAndPercent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KrakenSingleBar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // The walked batch's first sample: 4,819,760 reads of which 893,706 are classified, all of them viruses.
        let root = TaxonNode(
            taxId: 1, name: "root", rank: .root, depth: 0, readsDirect: 0, readsClade: 893_706,
            fractionClade: 893_706.0 / 4_819_760.0, fractionDirect: 0, parentTaxId: nil
        )
        let viruses = TaxonNode(
            taxId: 10239, name: "Viruses", rank: TaxonomicRank(code: "D"), depth: 1, readsDirect: 93_706,
            readsClade: 893_706, fractionClade: 893_706.0 / 4_819_760.0, fractionDirect: 0, parentTaxId: 1
        )
        root.addChild(viruses)
        let tree = TaxonTree(root: root, unclassifiedNode: nil, totalReads: 4_819_760)
        let result = ClassificationResult(
            config: ClassificationConfig(
                inputFiles: [dir.appendingPathComponent("reads.fastq")],
                isPairedEnd: false,
                databaseName: "test-db",
                databasePath: dir.appendingPathComponent("db"),
                outputDirectory: dir
            ),
            tree: tree,
            reportURL: dir.appendingPathComponent("classification.kreport"),
            outputURL: dir.appendingPathComponent("classification.kraken"),
            brackenURL: nil,
            runtime: 5.2,
            toolVersion: "2.1.3",
            provenanceId: nil
        )

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
        vc.configure(result: result)
        vc.testTableView.expandAll()
        vc.testTableView.outlineView.layoutSubtreeIfNeeded()

        let outline = vc.testTableView.outlineView
        let rowIndex = outline.row(forItem: viruses)
        XCTAssertGreaterThanOrEqual(rowIndex, 0, "Viruses is not a visible row")
        outline.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
        let column = outline.column(withIdentifier: NSUserInterfaceItemIdentifier("percent"))
        XCTAssertGreaterThanOrEqual(column, 0, "The table has no % column")
        let cell = try XCTUnwrap(outline.view(atColumn: column, row: rowIndex, makeIfNecessary: true) as? NSTableCellView)

        let percent = String(format: "%.1f%%", Double(viruses.readsClade) / Double(result.tree.totalReads) * 100)
        XCTAssertEqual(percent, "18.5%")
        XCTAssertEqual(cell.textField?.stringValue, percent, "The table gives the same percent")
        XCTAssertTrue(
            vc.testActionBar.infoLabel.stringValue.contains("Viruses \u{2014} 893,706 reads (\(percent) of all reads)"),
            "The bar of one opened result reads as it always has: \(vc.testActionBar.infoLabel.stringValue)"
        )
    }
}
