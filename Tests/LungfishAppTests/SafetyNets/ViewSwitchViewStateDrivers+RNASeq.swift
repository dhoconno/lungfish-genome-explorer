// ViewSwitchViewStateDrivers+RNASeq.swift - The RNA-seq result and cell map drivers for the view state cases (VS-RNA)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The RNA-seq fixture (RoutingSafetyNetFixtures.rnaseqResultBundle) is a two-sample bulk result of genes G1 and G2. Its
// change searches for G2, selects its row and opens the Quality tab. The cell map fixture is the committed smoke map of
// 12 cells on one UMAP. Its change colours by UMIs per cell, sets the point size to 5, zooms and lassoes four cells.
// A changed bundle is a rerun written in place, so the folder keeps its identity and only the data key differs.

import AppKit
import XCTest
@testable import LungfishApp
import LungfishCore
@testable import LungfishIO
import LungfishRNASeqUI
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
enum RNASeqViewStateControls {
    static func surface(in harness: ViewSwitchWindowHarness) -> RNASeqResultSurface? {
        harness.split.viewerController.surfaceHost.activeViewport as? RNASeqResultSurface
    }

    /// The view under `root` whose accessibility identifier is `id`.
    static func view(_ id: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == id { return root }
        for child in root.subviews { if let found = view(id, in: child) { return found } }
        return nil
    }

    /// Writes a result with `write` beside `bundle`, then moves its files into `bundle`, so the folder keeps its file
    /// number and creation date and only what it holds changes, as a rerun into the same folder does.
    static func rewrite(_ bundle: URL, with write: (URL) throws -> Void) throws {
        let fileManager = FileManager.default
        let fresh = bundle.deletingLastPathComponent().appendingPathComponent("rerun.lungfishrnaseq", isDirectory: true)
        try write(fresh)
        for name in try fileManager.contentsOfDirectory(atPath: bundle.path) {
            try fileManager.removeItem(at: bundle.appendingPathComponent(name))
        }
        for name in try fileManager.contentsOfDirectory(atPath: fresh.path) {
            try fileManager.moveItem(at: fresh.appendingPathComponent(name), to: bundle.appendingPathComponent(name))
        }
        try fileManager.removeItem(at: fresh)
    }

    static let envelope = ProvenanceEnvelope(workflowName: "RNA-seq import", toolName: "lungfish-cli", toolVersion: "test")
    static let writer = RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))

    /// The smoke map again with `embedding` as its one embedding and the points moved by `shift`, as a rerun gives.
    static func rerunCellMap(_ bundle: URL, embedding: String, shift: Double) throws {
        let parent = bundle.deletingLastPathComponent().appendingPathComponent("Smoke single-cell.lungfishrnaseq", isDirectory: true)
        let drawn = (Int32(1)...12).filter { $0 != 4 }
        let labelled = drawn.filter { $0 != 9 }
        let point = { (cell: Int32) in [Double(cell % 4) * 1.5 + shift, Double(cell / 4) * 1.25 + shift] }
        let request = RNASeqResultWriter.CellMapRequest(
            name: "Smoke cell map", parent: parent, origin: .init(kind: .imported, tool: "Seurat", toolVersion: "5.5.1"),
            embeddings: [.init(name: embedding, method: embedding, source: .imported, sourceFile: "source/1/rerun.tsv",
                               otherCounts: false, dimensions: 2, cells: drawn, values: drawn.flatMap(point))],
            labelSets: [.init(name: "clusters", source: .imported, sourceFile: "source/1/rerun.tsv", cells: labelled,
                              labels: labelled.map { String($0 % 3 + 1) })],
            createdAt: Date(timeIntervalSince1970: 1_800_000_600))
        try rewrite(bundle) { fresh in
            _ = try writer.writeCellMap(request, to: fresh, availableBytes: { _ in Int64.max }, observe: nil) { _ in
                ProvenanceEnvelope(workflowName: "RNA-seq cell map", toolName: "lungfish-cli", toolVersion: "test")
            }
        }
    }
}

@MainActor
struct RNASeqViewStateDriver: ViewStateDriver {
    let kind = "RNA-seq"

    private func bulk(in harness: ViewSwitchWindowHarness) -> RNASeqBulkViewController? {
        RNASeqViewStateControls.surface(in: harness)?.controller.bulk
    }

    func isShown(in harness: ViewSwitchWindowHarness) -> Bool {
        bulk(in: harness)?.countTables.isEmpty == false
    }

    /// Types G2 in the gene search as a person does, picks its row and opens the Quality tab.
    func change(in harness: ViewSwitchWindowHarness) throws {
        let bulk = try XCTUnwrap(bulk(in: harness))
        bulk.searchField.stringValue = "G2"
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(bulk.searchField.action), to: bulk.searchField.target, from: bulk.searchField))
        bulk.countTables[0].selectRowIndexes([0], byExtendingSelection: false)
        bulk.tabView.selectTabViewItem(withIdentifier: "rnaseq-bulk-tab-quality")
    }

    /// The search field, the match line beside it, the rows and selected genes of the count table, and the tab.
    func read(in harness: ViewSwitchWindowHarness) throws -> [String] {
        let bulk = try XCTUnwrap(bulk(in: harness))
        let table = bulk.countTables[0]
        let match = RNASeqViewStateControls.view("rnaseq-bulk-matches", in: bulk.view) as? NSTextField
        let selected = table.selectedRowIndexes.map { bulk.shownText(tableTag: 0, column: 0, row: $0) }
        return [
            "search \(bulk.searchField.stringValue)",
            "match \(match?.stringValue ?? "none")",
            "rows \(table.numberOfRows)",
            "selected \(selected.joined(separator: ", "))",
            "tab \(bulk.tabView.selectedTabViewItem?.label ?? "none")",
        ]
    }

    /// Writes the result again with other counts for the same genes, so its manifest lists new checksums.
    func changeBundle(of fixture: ViewSwitchFixture) throws {
        let bundle = try XCTUnwrap(fixture.item.url)
        let table = RNASeqCountTable(sampleIDs: ["S1", "S2"], rows: [
            RNASeqCountTable.Row(id: "G1", counts: [11, 20]),
            RNASeqCountTable.Row(id: "G2", counts: [0, 6]),
        ])
        let request = RNASeqResultWriter.Request(
            name: "Two sample test", modality: .bulk,
            origin: .init(kind: .imported, tool: "salmon", toolVersion: "1.10.0"),
            route: .init(id: "salmon-selective-alignment", tool: "salmon", toolVersion: "1.10.0", settings: ["unit": "NumReads"]),
            referenceSet: nil,
            samples: ["S1", "S2"].map { RNASeqSampleRecord(id: $0, runs: [$0]) },
            genes: .ids(table.rows.map(\.id)),
            counts: [.init(rows: .gene, column: .default, unit: .reads, table: table)],
            sourceFiles: [], notHost: [])
        try RNASeqViewStateControls.rewrite(bundle) { fresh in
            _ = try RNASeqViewStateControls.writer.write(request, to: fresh, envelope: RNASeqViewStateControls.envelope)
        }
    }

    /// The search is a search text, so a changed key drops it and both genes show. The tab and the selected gene by
    /// its id come back (VS B4, B6).
    func readingAfterChangedBundle(changed: [String]) -> [String] {
        var reading = changed
        reading[0] = "search "
        reading[1] = "match "
        reading[2] = "rows 2"
        return reading
    }

    var lineAfterChangedBundle: String? {
        "The data changed since your last visit, so your filters were not kept."
    }
}

@MainActor
struct CellMapViewStateDriver: ViewStateDriver {
    let kind = "Cell map"
    /// A box around the cells 1, 2, 5 and 6 of the smoke map's UMAP.
    static let lasso: [RNASeqCellMapSelection.Vertex] = [.init(x: -0.5, y: -0.5), .init(x: 3.5, y: -0.5), .init(x: 3.5, y: 2), .init(x: -0.5, y: 2)]

    func map(in harness: ViewSwitchWindowHarness) -> RNASeqCellMapViewController? {
        RNASeqViewStateControls.surface(in: harness)?.controller.cellMap
    }

    func isShown(in harness: ViewSwitchWindowHarness) -> Bool {
        map(in: harness)?.snapshot != nil
    }

    /// Waits for the reads, the raster and the selection run in flight, as the controller's own tests do.
    func settle(in harness: ViewSwitchWindowHarness) async {
        guard let map = map(in: harness) else { return }
        while true {
            let (work, selecting) = (map.work, map.selectionWork)
            await selecting?.value
            await work?.value
            if map.work == work, map.selectionWork == selecting { return }
        }
    }

    /// Colours by UMIs per cell through the pop-up, sets the size to 5, zooms as a pinch's end does and lassoes.
    func change(in harness: ViewSwitchWindowHarness) throws {
        let map = try XCTUnwrap(map(in: harness))
        map.colourPopUp.selectItem(withTitle: "UMIs per cell")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(map.colourPopUp.action), to: map.colourPopUp.target, from: map.colourPopUp))
        map.choosePointSize(5)
        map.plot.onWindowChange?(RNASeqEmbeddingWindow(minX: -1, minY: -1, maxX: 4, maxY: 3))
        map.selectPolygon(Self.lasso)
    }

    /// The two pop-ups, the point size, the plot's window and the selection line.
    func read(in harness: ViewSwitchWindowHarness) throws -> [String] {
        let map = try XCTUnwrap(map(in: harness))
        let window = map.plotWindow.map { "\($0.minX) \($0.minY) \($0.maxX) \($0.maxY)" } ?? "all cells"
        return [
            "embedding \(map.embeddingPopUp.titleOfSelectedItem ?? "none")",
            "colour \(map.colourPopUp.titleOfSelectedItem ?? "none")",
            "point size \(map.pointSize)",
            "window \(window)",
            "selection \(map.selectionField.stringValue)",
        ]
    }

    /// A rerun that keeps the embedding's name and the label set and moves every point.
    func changeBundle(of fixture: ViewSwitchFixture) throws {
        try RNASeqViewStateControls.rerunCellMap(try XCTUnwrap(fixture.item.url), embedding: "UMAP", shift: 10)
    }

    /// The colouring and the size come back by name. The zoom and the lasso are coordinates of the plane, so a changed
    /// key drops them (VS B3, B7).
    func readingAfterChangedBundle(changed: [String]) -> [String] {
        var reading = changed
        reading[3] = "window all cells"
        reading[4] = "selection No cells selected"
        return reading
    }

    var lineAfterChangedBundle: String? {
        "The data changed since your last visit, so your place and selection were not kept."
    }
}
