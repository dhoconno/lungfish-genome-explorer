// RNASeqCellMapViewModelTests.swift - The embedding view shows what cellmap.sqlite holds (Phase 5.5 lane CM-VIEW)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Model assertions, no stored image (5.5 O6, owner choice O-9). The point buffer equals the file for every cell, the
// colour index follows the label set with slots 0 to 18 repeating past 19 labels and grey for no label, the legend rows
// are the file's counts, a hit test on a known point names its barcode, and the view opens on the first embedding in
// file order. The raster byte test computes its own expected words and stores no image.

import AppKit
@testable import LungfishIO
import LungfishKit
import LungfishTestSupport
import SwiftUI
import XCTest
@testable import LungfishRNASeqUI

final class RNASeqCellMapViewModelTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "cm-view") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    func snapshot() throws -> (RNASeqCellMapSnapshot, RNASeqResult, URL) {
        let (_, map) = try RNASeqCellMapViewFixtures.cellMap(in: root)
        let result = try RNASeqResultBundle.load(from: map)
        return (try RNASeqCellMapLoader.snapshot(result: result, bundleURL: map), result, map)
    }

    func testThePointBufferEqualsTheFileForEveryCell() throws {
        let (shown, _, _) = try snapshot()
        XCTAssertEqual(shown.points.x.count, 200)
        for cell in Int32(1)...200 {
            let index = Int(cell) - 1
            if RNASeqCellMapViewFixtures.leftOut.contains(cell) {
                XCTAssertTrue(shown.points.x[index].isNaN && shown.points.y[index].isNaN, "cell \(cell) is left out")
            } else {
                let point = RNASeqCellMapViewFixtures.umap(cell)
                XCTAssertEqual(shown.points.x[index], Float32(point.x), "x of cell \(cell)")
                XCTAssertEqual(shown.points.y[index], Float32(point.y), "y of cell \(cell)")
            }
        }
        let drawn = Set(shown.colours.order.map { Int32($0) + 1 })
        XCTAssertEqual(drawn, Set(Int32(1)...200).subtracting(RNASeqCellMapViewFixtures.leftOut))
        XCTAssertEqual(shown.colours.order.count, 197, "each drawn cell is drawn once")
    }

    func testTheColourIndexFollowsTheLabelSetAndRepeatsPast19() throws {
        let (shown, _, _) = try snapshot()
        let set = try XCTUnwrap(shown.facts.labelSets.first)
        XCTAssertEqual(set.labels.count, 21)
        guard case .labels(let labels) = shown.values else { return XCTFail("the default colouring is the label set") }
        for cell in Int32(1)...200 {
            let index = shown.colours.index[Int(cell) - 1]
            if RNASeqCellMapViewFixtures.unlabelled.contains(cell) {
                XCTAssertEqual(labels[Int(cell) - 1], 0)
                XCTAssertEqual(index, RNASeqEmbeddingPalette.greyIndex, "cell \(cell) has no label and takes the grey")
            } else {
                let label = Int(labels[Int(cell) - 1])
                XCTAssertEqual(set.labels[label - 1].name, RNASeqCellMapViewFixtures.label(cell), "the label chain of cell \(cell)")
                XCTAssertEqual(Int(index), (label - 1) % 19, "cell \(cell) takes slot label - 1, repeating past 19")
            }
        }
        XCTAssertEqual(set.labels.map(\.name).suffix(2), ["20", "21"])
        XCTAssertEqual(shown.colours.legend.rows.suffix(2).map(\.colour), [0, 1], "labels 20 and 21 take slots 0 and 1")
        XCTAssertFalse(shown.colours.index.contains { $0 > RNASeqEmbeddingPalette.greyIndex }, "no label takes a scale colour")
        let drawnUnlabelled = shown.colours.order.prefix(2).map { Int32($0) + 1 }
        XCTAssertEqual(drawnUnlabelled, [6, 7], "unlabelled cells draw first, under the labelled ones, in cell order")
        XCTAssertEqual(Array(shown.colours.order.dropFirst(2)), shown.colours.order.dropFirst(2).sorted(), "labels draw in cell order")
    }

    func testTheLegendRowsEqualTheFilesCounts() throws {
        let (shown, _, map) = try snapshot()
        let database = try RNASeqCellMapDatabase(url: map.appendingPathComponent(RNASeqCellMap.filename))
        let stored = try database.labelSets()[0]
        let legend = shown.colours.legend
        XCTAssertEqual(legend.title, "graphclust")
        XCTAssertEqual(legend.rows.map(\.name), stored.labels.map(\.name))
        XCTAssertEqual(legend.rows.map(\.count), stored.labels.map { String($0.cells) })
        XCTAssertTrue(legend.words.contains(RNASeqEmbeddingWords.coloursRepeat))
        let sample = try database.samples()[0]
        XCTAssertTrue(legend.words.contains(RNASeqEmbeddingWords.unlabelled(3, sample: sample.name, set: "graphclust")))
        let bySample = try RNASeqCellMapColours.make(facts: shown.facts, colouring: .sample, values: .samples, points: shown.points)
        XCTAssertEqual(bySample.legend.rows.map(\.count), try database.samples().map { String($0.cells) })
        XCTAssertEqual(shown.facts.cellCount, try database.cellCount())
    }

    func testAHitTestOnAKnownPointNamesItsBarcode() throws {
        let (shown, _, _) = try snapshot()
        let input = RNASeqEmbeddingRasterInput(
            x: shown.points.x, y: shown.points.y, order: shown.colours.order, colour: shown.colours.index,
            palette: RNASeqEmbeddingPalette.words(dark: false), width: 1600, height: 1000, radius: 2,
            window: .fit(x: shown.points.x, y: shown.points.y, order: shown.colours.order))
        let raster = try RNASeqEmbeddingRaster.draw(input)
        let pixel = raster.mapping.pixel(x: shown.points.x[99], y: shown.points.y[99])
        let cell = try XCTUnwrap(raster.cell(column: Int(pixel.column), row: Int(pixel.row)))
        XCTAssertEqual(cell, 99)
        let barcodes = try String(contentsOf: RNASeqCellMapViewFixtures.starsolo.appendingPathComponent("Solo.out/Gene/filtered/barcodes.tsv"),
                                  encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(try shown.database.cell(id: cell + 1)?.barcode, String(barcodes[99]))
        let leftOut = raster.mapping.pixel(x: Float32(RNASeqCellMapViewFixtures.umap(5).x), y: Float32(RNASeqCellMapViewFixtures.umap(5).y))
        XCTAssertNotEqual(raster.cell(column: Int(leftOut.column), row: Int(leftOut.row)), 4, "a cell left out is never hit")
    }

    func testTheDefaultEmbeddingIsTheFirstInFileOrder() throws {
        let (shown, _, _) = try snapshot()
        XCTAssertEqual(shown.facts.embeddings.map(\.name), ["UMAP", "PCA"])
        XCTAssertEqual(shown.facts.defaultEmbedding?.name, "UMAP")
        XCTAssertEqual(shown.points.embedding, shown.facts.embeddings[0].embedding)
        XCTAssertEqual(shown.colouring, .labelSet(shown.facts.labelSets[0].labelSet))
    }

    /// The bytes are computed here from the palette and the mapping, and no image is stored (5.5 O6).
    func testTheRasterWritesThePaletteWordAtEachPointAndTheLastDrawnIsOnTop() throws {
        let palette = RNASeqEmbeddingPalette.words(dark: false)
        let x: ContiguousArray<Float32> = [0, 10, 10, .nan]
        let y: ContiguousArray<Float32> = [0, 5, 5, 1]
        let input = RNASeqEmbeddingRasterInput(x: x, y: y, order: [0, 1, 2, 3], colour: [0, 1, 2, 3], palette: palette,
                                               width: 64, height: 48, radius: 0, window: .init(minX: 0, minY: 0, maxX: 10, maxY: 5))
        let raster = try RNASeqEmbeddingRaster.draw(input)
        var expected = ContiguousArray<UInt32>(repeating: 0, count: 64 * 48)
        for cell in [0, 1, 2] {
            let pixel = raster.mapping.pixel(x: x[cell], y: y[cell])
            expected[Int(pixel.row) * 64 + Int(pixel.column)] = palette[cell]
        }
        XCTAssertEqual(raster.pixels, expected, "each drawn cell sets its one pixel, cell 2 over cell 1, and the NaN cell draws nothing")
        XCTAssertEqual(palette[2] & 0xFF, 0x4C, "red sits in the lowest byte")
        XCTAssertEqual(palette[2] >> 24, 0xFF)
    }

    func testThePaletteCopyEqualsLungfishKitsFirst19Slots() throws {
        for (appearance, dark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
            let drawing: NSAppearance = try XCTUnwrap(NSAppearance(named: appearance))
            drawing.performAsCurrentDrawingAppearance {
                for slot in 0..<19 {
                    let colour = PhylumPalette.phylumColors[slot].usingColorSpace(.sRGB)!
                    let copy = dark ? RNASeqEmbeddingPalette.labelColours[slot].dark : RNASeqEmbeddingPalette.labelColours[slot].light
                    XCTAssertEqual(Int((colour.redComponent * 255).rounded()), Int(copy.red), "slot \(slot) red")
                    XCTAssertEqual(Int((colour.greenComponent * 255).rounded()), Int(copy.green), "slot \(slot) green")
                    XCTAssertEqual(Int((colour.blueComponent * 255).rounded()), Int(copy.blue), "slot \(slot) blue")
                }
            }
        }
    }

    func testACountColouringDrawsZerosFirstInGreyThenRising() throws {
        let (shown, _, _) = try snapshot()
        var facts = shown.facts
        facts.extras = [.init(extra: 1, name: "SARS-CoV-2", kind: "virus")]
        facts.valueBounds.append(.init(value: "not_host_umis", extra: 1, minimum: 0, maximum: 10, p99: 0))
        let colours = try RNASeqCellMapColours.make(facts: facts, colouring: .notHostUMIs(extra: 1),
                                                    values: .counts(cells: [9, 2, 3], values: [10, 4, 2]), points: shown.points)
        XCTAssertEqual(Array(colours.order.suffix(3)), [2, 1, 8], "the rest draw in rising order after the zeros")
        XCTAssertEqual(colours.index[8], RNASeqEmbeddingPalette.gradientBase + 255, "the maximum takes the top colour")
        XCTAssertEqual(colours.index[0], RNASeqEmbeddingPalette.greyIndex)
        XCTAssertEqual(colours.legend.scale?.top, 10, "a p99 of 0 makes the maximum the top")
        XCTAssertEqual(colours.legend.words, [RNASeqEmbeddingWords.scaleToMaximum(maximum: "10", cells: 200)])
        XCTAssertEqual(colours.legend.title, "SARS-CoV-2 not-host UMIs")
    }

    /// The expected colour of each cell is computed here from `cell(id:)` and the file's `value_bounds` row, a second
    /// path to the values the view reads in one ordered read.
    func testColourByUMIsAndGenesPerCellFollowsTheFilesTotalsAndBounds() throws {
        let (shown, _, map) = try snapshot()
        let database = try RNASeqCellMapDatabase(url: map.appendingPathComponent(RNASeqCellMap.filename))
        XCTAssertEqual(Array(shown.facts.colourings.suffix(2)), [.cellUMIs, .cellGenes], "the fixture has no extras")
        XCTAssertEqual(shown.facts.title(of: .cellUMIs), "UMIs per cell")
        XCTAssertEqual(shown.facts.title(of: .cellGenes), "Genes per cell")
        let bounds = try database.valueBounds()
        for (colouring, name) in [(RNASeqCellMapColouring.cellUMIs, "umis"), (.cellGenes, "genes")] {
            let values = try RNASeqCellMapLoader.values(database, colouring: colouring)
            let colours = try RNASeqCellMapColours.make(facts: shown.facts, colouring: colouring, values: values, points: shown.points)
            let row = try XCTUnwrap(bounds.first { $0.value == name && $0.extra == 0 }, "the file's \(name) bounds")
            let top = row.p99 > 0 ? row.p99 : row.maximum
            var totals: [Int] = []
            for cell in 0..<shown.facts.cellCount {
                let stored = try XCTUnwrap(try database.cell(id: cell + 1))
                let total = colouring == .cellUMIs ? stored.umis : stored.genes
                totals.append(total)
                let step: Int = min(Int(Double(total) / top * 255), 255)
                let expected: UInt16 = total == 0 ? RNASeqEmbeddingPalette.greyIndex : RNASeqEmbeddingPalette.gradientBase + UInt16(step)
                XCTAssertEqual(colours.index[cell], expected, "the \(name) colour of cell \(cell + 1)")
            }
            XCTAssertEqual(colours.legend.title, shown.facts.title(of: colouring))
            XCTAssertEqual(colours.legend.scale, RNASeqEmbeddingLegend.Scale(minimum: row.minimum, maximum: row.maximum, p99: row.p99))
            let drawn = colours.order.map { totals[Int($0)] }
            XCTAssertEqual(drawn.count, 197, "each drawn cell is drawn once")
            let zeros = drawn.prefix { $0 == 0 }.count
            XCTAssertEqual(drawn.filter { $0 == 0 }.count, zeros, "the cells with 0 draw first")
            XCTAssertEqual(Array(drawn.dropFirst(zeros)), drawn.dropFirst(zeros).sorted(), "the rest draw in rising order")
            let words: String
            if row.maximum <= 0 {
                words = RNASeqEmbeddingWords.scaleAllZero(cells: shown.facts.cellCount)
            } else if row.p99 > 0 {
                words = RNASeqEmbeddingWords.scale(p99: RNASeqEmbeddingWords.number(row.p99), cells: shown.facts.cellCount,
                                                   maximum: RNASeqEmbeddingWords.number(row.maximum))
            } else {
                words = RNASeqEmbeddingWords.scaleToMaximum(maximum: RNASeqEmbeddingWords.number(row.maximum), cells: shown.facts.cellCount)
            }
            XCTAssertEqual(colours.legend.words, [words])
        }
    }

    /// The only link between the memory guard's `load.cancel()` and the reader's step loop (SF-1).
    func testACancelBeforeTheReadGivesTheStoppedWordsAndNoSnapshot() async throws {
        let (_, map) = try RNASeqCellMapViewFixtures.cellMap(in: root)
        guard case .loaded(let result) = RNASeqResultSurface.read(map) else { return XCTFail("the cell map reads") }
        let task = Task { () -> RNASeqCellMapLoadOutcome in
            while !Task.isCancelled { await Task.yield() }
            return await RNASeqCellMapLoader.load(result: result, bundleURL: map)
        }
        task.cancel()
        guard case .failed(let words) = await task.value else { return XCTFail("a cancelled read shows no snapshot") }
        XCTAssertTrue(words.contains("The read was stopped."), words)
    }

    /// The bytes are computed here with plain loops, and no image is stored (5.5 O6). The disc of radius 2 runs the
    /// stamp offsets, the corner disc the clipped branch, and the dark palette its own words (SF-2).
    func testADiscOfRadiusTwoSetsExactlyItsPixelsAndAnEdgeDiscIsClipped() throws {
        let palette = RNASeqEmbeddingPalette.words(dark: true)
        let width = 64, height = 48, radius = 2
        let window = RNASeqEmbeddingWindow(minX: 0, minY: 0, maxX: 10, maxY: 5)
        let mapping = RNASeqEmbeddingMapping(window: window, width: width, height: height, pad: radius + 1)
        // Cells 0 and 1 overlap, cell 2's disc runs off the corner, cell 3 is left out. Half pixels keep Int() stable.
        let spots: [(column: Float32, row: Float32)] = [(30.5, 24.5), (32.5, 25.5), (1.5, 1.5)]
        let points = spots.map { mapping.point(column: $0.column, row: $0.row) }
        let colours: [UInt16] = [0, 5, 19, 3]
        let input = RNASeqEmbeddingRasterInput(
            x: ContiguousArray(points.map(\.x) + [.nan]), y: ContiguousArray(points.map(\.y) + [1]), order: [0, 1, 2, 3],
            colour: ContiguousArray(colours), palette: palette, width: width, height: height, radius: radius, window: window)
        let raster = try RNASeqEmbeddingRaster.draw(input)
        var expected = ContiguousArray<UInt32>(repeating: 0, count: width * height)
        for cell in 0..<3 {
            let column = Int(spots[cell].column), row = Int(spots[cell].row)
            for dy in -radius...radius {
                for dx in -radius...radius where dx * dx + dy * dy <= radius * radius {
                    let c = column + dx, r = row + dy
                    if c >= 0, c < width, r >= 0, r < height { expected[r * width + c] = palette[Int(colours[cell])] }
                }
            }
        }
        XCTAssertEqual(raster.pixels, expected, "plain loops give the same bytes as the stamp and the clipped branch")
    }
}

final class RNASeqCellMapViewWordsTests: XCTestCase {
    func testUMAPAndTSNEShareW1AndPCAOrNoMethodGetsTheNeutralCaption() {
        let umap = RNASeqEmbeddingWords.caption(method: "UMAP", embedding: "umap")
        let tsne = RNASeqEmbeddingWords.caption(method: "t-SNE", embedding: "TSNE")
        XCTAssertTrue(umap.hasPrefix("UMAP places cells"))
        XCTAssertEqual(tsne, umap.replacingOccurrences(of: "UMAP", with: "t-SNE"))
        for caption in [RNASeqEmbeddingWords.caption(method: "PCA", embedding: "PCA"), RNASeqEmbeddingWords.caption(method: nil, embedding: "x")] {
            XCTAssertFalse(caption.contains("near neighbours"), caption)
            XCTAssertTrue(caption.contains("computes nothing"), caption)
        }
        XCTAssertTrue(RNASeqEmbeddingWords.caption(method: nil, embedding: "x").contains("not recorded"))
        XCTAssertEqual(RNASeqEmbeddingWords.caption(method: "PHATE", embedding: "phate"),
                       "PHATE draws cells along smooth paths. A path suggests a transition, not an order in time.")
        XCTAssertEqual(RNASeqEmbeddingWords.axes(method: "t-SNE", embedding: "TSNE").x, "t-SNE 1")
        XCTAssertEqual(RNASeqEmbeddingWords.axes(method: nil, embedding: "TSNE").y, "TSNE 2")
    }

    func testNoWordSaysInfectedOrThatClustersMatch() {
        let all = [RNASeqEmbeddingWords.computedLabels, RNASeqEmbeddingWords.clusterNumbers, RNASeqEmbeddingWords.coloursRepeat,
                   RNASeqEmbeddingWords.otherCounts(embedding: "e", parent: "p"), RNASeqSingleCellWords.cellMap]
        for words in all {
            for forbidden in ["infected", "matches", "the same clusters as", "equivalent", "not expressed", "trajectory", "pseudotime"] {
                XCTAssertFalse(words.lowercased().contains(forbidden), "\(forbidden) in \(words)")
            }
        }
        XCTAssertTrue(RNASeqSingleCellWords.cellMap.contains("Import Embedding\u{2026}"))
        XCTAssertTrue(RNASeqSingleCellWords.cellMap.contains("lungfish-cli rnaseq cell-map import"))
        XCTAssertTrue(RNASeqSingleCellWords.cellMap.contains("lungfish-cli rnaseq cell-map compute"))
    }
}

@MainActor
final class RNASeqCellMapViewControllerTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "cm-view-controller") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    func settle(_ controller: RNASeqCellMapViewController) async {
        while let work = controller.work {
            await work.value
            if controller.work == work { return }
        }
    }

    func texts(in view: NSView) -> [String: String] {
        var found: [String: String] = [:]
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, !field.accessibilityIdentifier().isEmpty { found[field.accessibilityIdentifier()] = field.stringValue }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    func testTheSurfaceOpensACellMapOnItsFirstEmbeddingWithItsWordsAndRaster() async throws {
        let (_, map) = try RNASeqCellMapViewFixtures.cellMap(in: root)
        let surface = RNASeqResultSurface()
        let outcome = RNASeqResultSurface.read(map)
        guard case .loaded(let result) = outcome else { return XCTFail("the cell map reads") }
        surface.present(outcome, bundleURL: map, cellMap: await RNASeqCellMapLoader.load(result: result, bundleURL: map))
        let controller = try XCTUnwrap(surface.controller.cellMap)
        XCTAssertNil(surface.controller.singleCell)
        XCTAssertEqual(controller.view.accessibilityIdentifier(), RNASeqCellMapViewController.accessibilityID)
        surface.controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        surface.controller.view.layoutSubtreeIfNeeded()
        controller.requestRaster()
        await settle(controller)
        XCTAssertNotNil(controller.plot.raster, "the plot shows a raster")
        XCTAssertEqual(controller.embeddingPopUp.titleOfSelectedItem, "UMAP")
        XCTAssertEqual(controller.pointSize, RNASeqCellMapViewController.defaultPointSize)
        var shown = texts(in: controller.view)
        let sample = try XCTUnwrap(controller.snapshot?.facts.samples.first?.name)
        XCTAssertEqual(shown["rnaseq-cell-map-caption"], RNASeqEmbeddingWords.caption(method: "UMAP", embedding: "UMAP"))
        XCTAssertEqual(shown["rnaseq-cell-map-left-out-1"], "3 of the 200 cells of \(sample) have no coordinates in UMAP and are not drawn.")
        XCTAssertEqual(shown["rnaseq-cell-map-other-counts"], RNASeqEmbeddingWords.otherCounts(embedding: "UMAP", parent: "pbmc"))
        XCTAssertEqual(shown["rnaseq-cell-map-fact-parent-result"], "pbmc (pbmc.lungfishrnaseq)")
        XCTAssertEqual(shown["rnaseq-cell-map-fact-cells-drawn"], "197 of 200")
        XCTAssertEqual(shown["rnaseq-cell-map-axis-x"], "UMAP 1")
        XCTAssertNotNil(shown["rnaseq-cell-map-cluster-numbers"], "W3 shows beside numeric labels")
        XCTAssertEqual(shown["rnaseq-cell-map-legend-0-count"], String(try XCTUnwrap(controller.snapshot?.facts.labelSets[0].labels[0].cells)))
        XCTAssertEqual(controller.plot.accessibilityChildren()?.count, 21, "VoiceOver reads one child for each legend value")

        controller.chooseEmbedding(2)
        await settle(controller)
        shown = texts(in: controller.view)
        XCTAssertEqual(shown["rnaseq-cell-map-caption"], RNASeqEmbeddingWords.caption(method: "PCA", embedding: "PCA"))
        XCTAssertNil(shown["rnaseq-cell-map-left-out-1"], "the PCA draws every cell")
        XCTAssertEqual(controller.snapshot?.colours.order.count, 200)

        controller.chooseColouring(.sample)
        await settle(controller)
        XCTAssertEqual(texts(in: controller.view)["rnaseq-cell-map-legend-title"], "Sample")
        XCTAssertEqual(controller.colourPopUp.titleOfSelectedItem, "Sample")

        let raster = try XCTUnwrap(controller.plot.raster)
        let pixel = raster.mapping.pixel(x: 42, y: -42)
        controller.hover(controller.plot.cell(at: controller.plot.viewPoint(column: Int(pixel.column), row: Int(pixel.row))))
        await controller.hoverWork?.value
        let barcodes = try String(contentsOf: RNASeqCellMapViewFixtures.starsolo.appendingPathComponent("Solo.out/Gene/filtered/barcodes.tsv"),
                                  encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(controller.hoverWords?.hasPrefix("Barcode \(barcodes[41]), sample \(sample)"), true, controller.hoverWords ?? "no hover")
    }

    /// Opens the fixture's cell map as the surface does, laid out with a raster on show. The surface holds the
    /// controller, so a test keeps it.
    func openController() async throws -> (RNASeqResultSurface, RNASeqCellMapViewController) {
        let (_, map) = try RNASeqCellMapViewFixtures.cellMap(in: root)
        let surface = RNASeqResultSurface()
        let outcome = RNASeqResultSurface.read(map)
        var read: RNASeqResult?
        if case .loaded(let result) = outcome { read = result }
        let result = try XCTUnwrap(read, "the cell map reads")
        surface.present(outcome, bundleURL: map, cellMap: await RNASeqCellMapLoader.load(result: result, bundleURL: map))
        let controller = try XCTUnwrap(surface.controller.cellMap)
        surface.controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        surface.controller.view.layoutSubtreeIfNeeded()
        controller.requestRaster()
        await settle(controller)
        XCTAssertNotNil(controller.snapshot, "the cell map opens")
        return (surface, controller)
    }

    /// The sliders and the SwiftUI hosting views under `root`. The walk stops at a hosting view, because SwiftUI draws the
    /// shared slider with views of its own, and `NSHostingView` is generic, so a host is found by its class name.
    func sliderAndHostCounts(in root: NSView) -> (sliders: Int, hosts: Int) {
        var counts = (sliders: 0, hosts: 0)
        func walk(_ view: NSView) {
            if view is NSSlider { counts.sliders += 1 }
            if String(describing: type(of: view)).hasPrefix("NSHostingView") {
                counts.hosts += 1
                return
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return counts
    }

    /// The path, size and modification time of every file and folder under `folder`.
    func listing(of folder: URL) throws -> [String] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys))
        return try walker.compactMap { $0 as? URL }.map { url in
            let values = try url.resourceValues(forKeys: Set(keys))
            return "\(url.path) \(values.fileSize ?? -1) \(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }.sorted()
    }

    /// Every slider in LGE is LungfishKit's shared control (the shared-slider-control ratchet), which is SwiftUI, so the
    /// point size is one hosting view in the control row and the view holds no NSSlider.
    func testThePointSizeIsTheSharedSliderInAHostingViewAndNoNSSliderIsLeft() async throws {
        let (surface, controller) = try await openController()
        defer { withExtendedLifetime(surface) {} }
        let counts = sliderAndHostCounts(in: controller.view)
        XCTAssertEqual(counts.sliders, 0, "an NSSlider draws the point size")
        XCTAssertEqual(counts.hosts, 1, "the shared slider is hosted once, in the control row")
    }

    /// The point size runs 1 to 8 pt, opens on 2 pt and clamps what it is given. A new size draws again with a disc of
    /// the radius it names, and nothing in the bundle changes (5.5 V6).
    func testThePointSizeClampsToOneToEightRedrawsAtTheNewRadiusAndWritesNothing() async throws {
        let (surface, controller) = try await openController()
        defer { withExtendedLifetime(surface) {} }
        let scale = controller.plot.pixelSize.scale
        func radius(of size: Double) -> Int { max(Int((size * scale / 2).rounded()), 0) }
        let bundle = try XCTUnwrap(controller.bundleURL)
        let before = try listing(of: bundle)
        XCTAssertEqual(RNASeqCellMapViewController.pointSizes, 1.0...8.0)
        XCTAssertEqual(controller.pointSize, 2)
        XCTAssertEqual(controller.plot.raster?.radius, radius(of: 2), "the view opens on 2 pt")
        for (asked, expected) in [(5.0, 5.0), (0.2, 1.0), (99.0, 8.0), (-3.0, 1.0), (2.0, 2.0)] {
            controller.choosePointSize(asked)
            await settle(controller)
            XCTAssertEqual(controller.pointSize, expected, "asked for \(asked) pt")
            XCTAssertEqual(controller.plot.raster?.radius, radius(of: expected), "drawn again at \(expected) pt")
        }
        XCTAssertEqual(try listing(of: bundle), before, "the point size is not recorded")
    }

    /// The shared slider and its number field write the model's `written` through a binding, so the test writes that
    /// binding as they do. A size written draws again at its radius, a size already on show draws nothing again, a size over the
    /// range is clamped, and a size set from code is what the binding reads. The control sits in the "Point size" row.
    func testTheSharedSlidersBindingWritesThePointSizeAndReadsWhatCodeSets() async throws {
        let (surface, controller) = try await openController()
        defer { withExtendedLifetime(surface) {} }
        let scale = controller.plot.pixelSize.scale
        let binding = Bindable(controller.pointSizeModel).written
        XCTAssertEqual(binding.wrappedValue, 2, "the control opens on 2 pt")
        binding.wrappedValue = 6
        await settle(controller)
        XCTAssertEqual(controller.pointSize, 6)
        XCTAssertEqual(controller.plot.raster?.radius, max(Int((6 * scale / 2).rounded()), 0), "the slider's size is drawn")
        let work = controller.work
        binding.wrappedValue = 6
        XCTAssertEqual(controller.work, work, "a size already on show draws nothing again")
        binding.wrappedValue = 40
        await settle(controller)
        XCTAssertEqual(controller.pointSize, 8, "a size over the range is clamped to 8 pt")
        controller.choosePointSize(3)
        XCTAssertEqual(binding.wrappedValue, 3, "a size set from code is what the control shows")
        XCTAssertEqual(RNASeqCellMapPointSizeControl.title, "Point size")
        XCTAssertEqual(RNASeqCellMapPointSizeControl.accessibilityID, "rnaseq-cell-map-point-size")
        let row = try XCTUnwrap(controller.pointSizeHost.superview as? NSStackView)
        XCTAssertEqual((row.arrangedSubviews.first as? NSTextField)?.stringValue, "Point size", "the control sits in the labelled row")
        await settle(controller)
    }

    func testColourByUMIsPerCellShowsItsScaleAndHoverReadsTheCellsUMIs() async throws {
        let (surface, controller) = try await openController()
        defer { withExtendedLifetime(surface) {} }
        controller.chooseColouring(.cellUMIs)
        await settle(controller)
        XCTAssertEqual(controller.colourPopUp.titleOfSelectedItem, "UMIs per cell")
        let shown = texts(in: controller.view)
        XCTAssertEqual(shown["rnaseq-cell-map-legend-title"], "UMIs per cell")
        let snapshot = try XCTUnwrap(controller.snapshot)
        let row = try XCTUnwrap(try snapshot.database.valueBounds().first { $0.value == "umis" && $0.extra == 0 })
        XCTAssertEqual(shown["rnaseq-cell-map-scale-top"], RNASeqEmbeddingWords.number(row.p99 > 0 ? row.p99 : row.maximum))
        let raster = try XCTUnwrap(controller.plot.raster)
        let pixel = raster.mapping.pixel(x: snapshot.points.x[99], y: snapshot.points.y[99])
        let cell = try XCTUnwrap(controller.plot.cell(at: controller.plot.viewPoint(column: Int(pixel.column), row: Int(pixel.row))))
        controller.hover(cell)
        await controller.hoverWork?.value
        let umis = try XCTUnwrap(try snapshot.database.cell(id: cell + 1)).umis
        XCTAssertEqual(controller.hoverWords?.hasSuffix("UMIs per cell \(umis)"), true, controller.hoverWords ?? "no hover")
    }

    /// The newest choice is the one shown, a read that `close()` superseded is never applied, and a pointer that moves
    /// inside one disc keeps its hover read (SF-1).
    func testTheNewestChoiceWinsCloseDropsItsReadAndHoverKeepsItsReadOnOneCell() async throws {
        let (surface, controller) = try await openController()
        defer { withExtendedLifetime(surface) {} }
        let first = try XCTUnwrap(controller.snapshot?.facts.labelSets.first?.labelSet)
        controller.chooseColouring(.sample)
        controller.chooseColouring(.labelSet(first))
        await settle(controller)
        XCTAssertEqual(controller.snapshot?.colouring, .labelSet(first), "the newest choice is the one shown")
        controller.chooseColouring(.sample)
        controller.close()
        await settle(controller)
        XCTAssertEqual(controller.snapshot?.colouring, .labelSet(first), "a read that close() superseded is never applied")
        controller.hover(7)
        let read = controller.hoverWork
        controller.hover(7)
        XCTAssertEqual(controller.hoverWork, read, "a pointer moving inside one disc keeps the read in flight")
        await controller.hoverWork?.value
    }

    /// A colouring chosen while another embedding is still being read keeps that embedding (SF-3, 5.5 V1).
    func testAColouringChosenWhileAnEmbeddingIsReadKeepsTheEmbedding() async throws {
        let (surface, controller) = try await openController()
        defer { withExtendedLifetime(surface) {} }
        controller.chooseEmbedding(2)
        controller.chooseColouring(.sample)
        await settle(controller)
        XCTAssertEqual(controller.snapshot?.points.embedding, 2, "the embedding chosen first is kept")
        XCTAssertEqual(controller.snapshot?.colouring, .sample)
        XCTAssertEqual(controller.embeddingPopUp.titleOfSelectedItem, "PCA")
    }
}

final class RNASeqCellMapViewFixtureTests: XCTestCase {
    /// The committed smoke fixture reads back whole through the reader the view uses.
    func testTheCommittedSmokeCellMapReadsBack() throws {
        let fixtures = RNASeqCellMapViewFixtures.self
        let map = fixtures.smoke.appendingPathComponent("\(fixtures.smokeMapName).lungfishrnaseq", isDirectory: true)
        let parent = fixtures.smoke.appendingPathComponent("\(fixtures.smokeParentName).lungfishrnaseq", isDirectory: true)
        XCTAssertEqual(try RNASeqResultBundle.verifyChecksums(of: map), [])
        XCTAssertEqual(try RNASeqResultBundle.verifyChecksums(of: parent), [])
        let result = try RNASeqResultBundle.load(from: map)
        XCTAssertEqual(result.manifest.modality, .cellMap)
        XCTAssertEqual(result.manifest.name, fixtures.smokeMapName)
        XCTAssertEqual(result.manifest.parent?.path, "\(fixtures.smokeParentName).lungfishrnaseq")
        let parentManifest = try Data(contentsOf: RNASeqResultBundle.manifestURL(in: parent))
        XCTAssertEqual(result.manifest.parent?.manifestSHA256, RNASeqResultBundle.sha256Hex(parentManifest))
        let shown = try RNASeqCellMapLoader.snapshot(result: result, bundleURL: map)
        XCTAssertEqual(shown.facts.embeddings.map(\.name), ["UMAP"])
        XCTAssertEqual(shown.facts.cellCount, Int(fixtures.smokeCells))
        XCTAssertEqual(shown.facts.embeddingCells.map { [$0.drawn, $0.leftOut] }, [[11, 1]])
        XCTAssertEqual(shown.facts.labelSets.map(\.name), ["clusters"])
        XCTAssertEqual(shown.facts.labelSets[0].labels.map(\.name), ["1", "2", "3"])
        for cell in Int32(1)...fixtures.smokeCells {
            let index = Int(cell) - 1
            if fixtures.smokeLeftOut.contains(cell) {
                XCTAssertTrue(shown.points.x[index].isNaN)
            } else {
                XCTAssertEqual(shown.points.x[index], Float32(fixtures.smokePoint(cell).x))
                XCTAssertEqual(shown.points.y[index], Float32(fixtures.smokePoint(cell).y))
            }
        }
        let counts = Dictionary(grouping: (Int32(1)...fixtures.smokeCells).filter { !fixtures.smokeUnlabelled.contains($0) }, by: fixtures.smokeLabel)
        XCTAssertEqual(shown.facts.labelSets[0].labels.map(\.cells), ["1", "2", "3"].map { counts[$0]?.count ?? 0 })
    }

    /// Writes the smoke fixture again into the folder LUNGFISH_CM_VIEW_WRITE_SMOKE_FIXTURE names. No gate sets it.
    func testWriteTheSmokeFixtureWhenAsked() throws {
        guard let target = ProcessInfo.processInfo.environment["LUNGFISH_CM_VIEW_WRITE_SMOKE_FIXTURE"] else {
            throw XCTSkip("Set LUNGFISH_CM_VIEW_WRITE_SMOKE_FIXTURE to a folder to write the smoke cell map there.")
        }
        let scratch = try TestTempDirectory.make(prefix: "cm-view-smoke")
        defer { TestTempDirectory.cleanup(scratch) }
        let folder = URL(fileURLWithPath: target, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try RNASeqCellMapViewFixtures.writeSmoke(into: folder, scratch: scratch)
    }
}
