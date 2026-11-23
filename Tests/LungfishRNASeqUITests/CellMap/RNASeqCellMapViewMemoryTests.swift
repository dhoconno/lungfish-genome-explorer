// RNASeqCellMapViewMemoryTests.swift - The cell map's kept view: names, the form on an equal key, and a late restore (VS-RNA)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The 200-cell map of RNASeqCellMapViewFixtures has a UMAP and a PCA and the label set graphclust. A kept selection comes
// back only as its `cell-map select` form, run again through the view's select rule, so `selectionRequest()` after a
// restore names the same cells as one `cell-map select` of that form (BIO OBJECT 2, VS B7). A changed key drops it, and
// a person's choice made before the restore's read ends wins (VS A2).

import AppKit
@testable import LungfishIO
import LungfishKit
import LungfishTestSupport
@testable import LungfishWorkflow
import XCTest
@testable import LungfishRNASeqUI

@MainActor
final class RNASeqCellMapViewMemoryTests: XCTestCase {
    var root: URL!
    var map: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "cm-view-memory")
        map = try RNASeqCellMapViewFixtures.cellMap(in: root).map
    }

    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    /// A surface that shows the map as the host's load shows it, with the data key the load reads.
    func open() async throws -> (RNASeqResultSurface, RNASeqCellMapViewController) {
        let surface = RNASeqResultSurface()
        let outcome = RNASeqResultSurface.read(map)
        guard case .loaded(let result) = outcome else {
            XCTFail("the cell map does not read: \(outcome)")
            throw CancellationError()
        }
        surface.present(outcome, bundleURL: map, cellMap: await RNASeqCellMapLoader.load(result: result, bundleURL: map))
        surface.viewMemoryDataKey = RNASeqResultSurface.viewMemoryDataKey(of: outcome)
        let controller = try XCTUnwrap(surface.controller.cellMap)
        surface.controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        surface.controller.view.layoutSubtreeIfNeeded()
        controller.requestRaster()
        await settle(controller)
        return (surface, controller)
    }

    func settle(_ controller: RNASeqCellMapViewController) async {
        while true {
            let (work, selecting) = (controller.work, controller.selectionWork)
            await selecting?.value
            await work?.value
            if controller.work == work, controller.selectionWork == selecting { return }
        }
    }

    func choose(_ name: String, in controller: RNASeqCellMapViewController) async throws {
        let embedding = try XCTUnwrap(controller.snapshot?.facts.embeddings.first { $0.name == name })
        controller.chooseEmbedding(embedding.embedding)
        await settle(controller)
    }

    func testARestoredLabelsSelectionNamesTheCellsOfOneCellMapSelectOfItsForm() async throws {
        let (first, left) = try await open()
        try await choose("PCA", in: left)
        left.selectLegendRow(0, adding: false)
        await settle(left)
        left.selectLegendRow(2, adding: true)
        await settle(left)
        let asked = try XCTUnwrap(left.selectionRequest())
        let kept = first.captureViewMemory()
        guard case .labels(let set, let labels)? = kept.cellMap?.selection else {
            return XCTFail("a legend pick keeps its labels form: \(String(describing: kept.cellMap?.selection))")
        }
        XCTAssertEqual(set, "graphclust")
        XCTAssertEqual(labels.count, 2)
        XCTAssertNil(kept.cellMap?.window)

        let (second, back) = try await open()
        XCTAssertEqual(second.restoreViewMemory(kept, dataChanged: false), [])
        XCTAssertNil(back.selection, "the selection waits for the PCA read and runs off the main actor")
        await settle(back)
        XCTAssertEqual(back.embeddingPopUp.titleOfSelectedItem, "PCA")
        let restored = try XCTUnwrap(back.selectionRequest())
        XCTAssertEqual(restored, asked, "the restored selection names the same form, embedding and count")
        let cli = try RNASeqCellMapSelect.select(cellMap: map, embedding: "PCA", form: restored.form)
        XCTAssertEqual(restored.count, cli.samples.map(\.selected).reduce(0, +), "one cell-map select of the form names the same cells")
        XCTAssertEqual(back.selection?.mask, left.selection?.mask)
        XCTAssertEqual(back.selectionField.stringValue, left.selectionField.stringValue)
    }

    func testALassoComesBackOnAnEqualKeyAndIsDroppedOnAChangedKey() async throws {
        let (first, left) = try await open()
        try await choose("PCA", in: left)
        left.plot.onWindowChange?(RNASeqEmbeddingWindow(minX: 0, minY: -120, maxX: 120, maxY: 0))
        left.selectPolygon([.init(x: 0, y: 0), .init(x: 60, y: 0), .init(x: 60, y: -60), .init(x: 0, y: -60)])
        await settle(left)
        let asked = try XCTUnwrap(left.selectionRequest())
        let kept = first.captureViewMemory()

        let (second, back) = try await open()
        XCTAssertEqual(second.restoreViewMemory(kept, dataChanged: false), [])
        await settle(back)
        XCTAssertEqual(back.selectionRequest(), asked)
        XCTAssertEqual(back.plotWindow, left.plotWindow)
        let cli = try RNASeqCellMapSelect.select(cellMap: map, embedding: "PCA", form: asked.form)
        XCTAssertEqual(back.selection?.count, cli.samples.map(\.selected).reduce(0, +))

        let (third, changed) = try await open()
        XCTAssertEqual(third.restoreViewMemory(kept, dataChanged: true), [.place, .selection])
        await settle(changed)
        XCTAssertEqual(changed.embeddingPopUp.titleOfSelectedItem, "PCA", "the embedding comes back by its name")
        XCTAssertNil(changed.selection, "a lasso is plane coordinates, so a changed key drops it")
        XCTAssertNil(changed.plotWindow)
        XCTAssertEqual(changed.selectionField.stringValue, RNASeqEmbeddingSelectionWords.none)
    }

    func testAChoiceMadeBeforeTheRestoresReadEndsWins() async throws {
        let (first, left) = try await open()
        try await choose("PCA", in: left)
        left.selectAllCells()
        await settle(left)
        let kept = first.captureViewMemory()
        XCTAssertNotNil(kept.cellMap?.selection)

        let (second, back) = try await open()
        _ = second.restoreViewMemory(kept, dataChanged: false)
        try await choose("UMAP", in: back)
        XCTAssertEqual(back.embeddingPopUp.titleOfSelectedItem, "UMAP", "the person's choice stands")
        XCTAssertNil(back.selection, "the kept selection never lands over the person's choice")
        XCTAssertEqual(second.captureViewMemory().cellMap?.embedding, "UMAP")
        XCTAssertNil(second.captureViewMemory().cellMap?.selection)
    }

    func testANameTheMapNoLongerHoldsOpensTheDefaultAndLosesThePlace() async throws {
        let (surface, controller) = try await open()
        var kept = surface.captureViewMemory()
        kept.cellMap = RNASeqCellMapViewMemory(embedding: "tSNE", colouring: .labelSet("leiden"), pointSize: 9,
                                               window: nil, selection: nil)
        XCTAssertEqual(surface.restoreViewMemory(kept, dataChanged: true), [.place])
        await settle(controller)
        XCTAssertEqual(controller.embeddingPopUp.titleOfSelectedItem, "UMAP")
        XCTAssertEqual(controller.colourPopUp.titleOfSelectedItem, "graphclust")
        XCTAssertEqual(controller.pointSize, 8, "the size clamps to 1 to 8")
    }

    func testASelectionNoOneFormNamesKeepsNoSelection() async throws {
        let (surface, controller) = try await open()
        controller.selectLegendRow(0, adding: false)
        await settle(controller)
        controller.selectPolygon([.init(x: -1000, y: -1000), .init(x: 0, y: -1000), .init(x: 0, y: 1000)], mode: .add)
        await settle(controller)
        XCTAssertNotNil(controller.selection)
        XCTAssertNil(controller.selection?.form)
        XCTAssertNil(surface.captureViewMemory().cellMap?.selection, "a nil form keeps no selection, and no mask or rows")
    }

    // MARK: - The zoom a capture keeps (VS-RNA review BIO SF-1, SWIFT SF2)

    /// A double click that shows every cell after a restored zoom is the person's view, so the next capture keeps no zoom.
    func testAZoomShownAgainAfterARestoreIsWhatTheNextCaptureKeeps() async throws {
        let (first, left) = try await open()
        left.plot.onWindowChange?(RNASeqEmbeddingWindow(minX: 0, minY: -120, maxX: 120, maxY: 0))
        let kept = first.captureViewMemory()
        XCTAssertNotNil(kept.cellMap?.window)

        let (second, back) = try await open()
        XCTAssertEqual(second.restoreViewMemory(kept, dataChanged: false), [])
        await settle(back)
        XCTAssertEqual(back.plotWindow, left.plotWindow)
        back.plot.onWindowChange?(nil)
        XCTAssertNil(back.plotWindow, "a double click on the plot shows every cell")
        XCTAssertNil(second.captureViewMemory().cellMap?.window, "the person's view of every cell is the one to keep")
    }

    /// While another embedding is read, the zoom on show belongs to the embedding it was drawn in, so a capture keeps the
    /// new embedding's name with no zoom.
    func testACaptureWhileAnotherEmbeddingReadsKeepsNoZoomOfTheOldOne() async throws {
        let (surface, controller) = try await open()
        controller.plot.onWindowChange?(RNASeqEmbeddingWindow(minX: 0, minY: -120, maxX: 120, maxY: 0))
        let pca = try XCTUnwrap(controller.snapshot?.facts.embeddings.first { $0.name == "PCA" })
        controller.chooseEmbedding(pca.embedding)
        let kept = surface.captureViewMemory().cellMap
        await settle(controller)
        XCTAssertEqual(kept?.embedding, "PCA")
        XCTAssertNil(kept?.window, "a zoom drawn on the UMAP is never kept as the PCA's")
    }

    /// VS A2: a zoom or a selection a person makes before the restore's read ends stands, and the kept zoom and selection
    /// never land over it. Each assertion fails if its guard in `finishRestore` or `applies` is removed.
    func testAZoomOrASelectionMadeBeforeTheRestoresReadEndsWins() async throws {
        let (first, left) = try await open()
        left.plot.onWindowChange?(RNASeqEmbeddingWindow(minX: 0, minY: 0, maxX: 100, maxY: 100))
        left.selectAllCells()
        await settle(left)
        var kept = first.captureViewMemory()
        kept.cellMap?.colouring = .sample
        XCTAssertNotNil(kept.cellMap?.window)
        XCTAssertNotNil(kept.cellMap?.selection)

        let (zoomed, zoomedMap) = try await open()
        _ = zoomed.restoreViewMemory(kept, dataChanged: false)
        let mine = RNASeqEmbeddingWindow(minX: 1, minY: 1, maxX: 50, maxY: 50)
        zoomedMap.plot.onWindowChange?(mine)
        await settle(zoomedMap)
        XCTAssertEqual(zoomedMap.plotWindow, mine, "the person's zoom stands")
        XCTAssertNil(zoomedMap.selection, "the kept selection never lands over it")

        let (picked, pickedMap) = try await open()
        _ = picked.restoreViewMemory(kept, dataChanged: false)
        pickedMap.selectLegendRow(0, adding: false)
        await settle(pickedMap)
        XCTAssertNil(pickedMap.plotWindow, "the kept zoom never lands over the person's selection")
        XCTAssertEqual(pickedMap.selection?.rows, [0])
    }

    // MARK: - The data key's size (VS-RNA review BIO SF-2, SWIFT SF3)

    /// The map's key is short, so a record stays far under the store's 64 KB cap, past which the store drops it whole.
    func testTheDataKeyOfASmallMapStaysUnder200Bytes() throws {
        let key = try XCTUnwrap(RNASeqResultSurface.viewMemoryDataKey(of: RNASeqResultSurface.read(map)))
        XCTAssertLessThan(key.utf8.count, 200, "a long key would push the record toward the store's 64 KB cap")
    }

    /// A result that lists 700 files keeps a key under 1,000 bytes that differs from the short one, and one changed
    /// checksum gives a third key, so a rerun still reads as changed.
    func testTheDataKeyStaysShortWithManyListedFilesAndChangesWithOneChecksum() throws {
        guard case .loaded(var result) = RNASeqResultSurface.read(map) else { return XCTFail("the cell map does not read") }
        let one = try XCTUnwrap(RNASeqResultSurface.viewMemoryDataKey(of: .loaded(result)))
        result.manifest.sourceFiles += (0..<700).map {
            RNASeqResultManifest.SourceFileEntry(path: "source/S\($0)/quant.sf", sha256: String(repeating: "a", count: 64),
                                                 size: 1, sample: "S\($0)", tool: "salmon")
        }
        let many = try XCTUnwrap(RNASeqResultSurface.viewMemoryDataKey(of: .loaded(result)))
        XCTAssertLessThan(many.utf8.count, 1_000)
        XCTAssertNotEqual(many, one)
        result.manifest.sourceFiles[350].sha256 = String(repeating: "b", count: 64)
        let changed = try XCTUnwrap(RNASeqResultSurface.viewMemoryDataKey(of: .loaded(result)))
        XCTAssertNotEqual(changed, many, "one changed checksum gives another key")
        XCTAssertNotEqual(changed, one)
    }
}
