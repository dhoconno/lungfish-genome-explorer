// RNASeqEmbeddingGeneTests.swift - Colour the cell map by a gene (Phase 5.5 lane CM-GENE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// 5.5 G1, L3, V3 and W5 on the STARsolo cut of 200 cells (`Tests/Fixtures/rnaseq/starsolo-pbmc_1k_v3`). LYZ and S100A9 are
// in the cut and CD3E is not (`Tests/Fixtures/rnaseq/README.md:20`). The colour of every cell is computed here from the
// stored `gene_values` row alone, and the stored raw UMIs and normalised values are read against CM-TRUTH's table from
// `mmread` (`Tests/Fixtures/rnaseq/cell-map-pbmc_1k_v3/genes-of-interest-starsolo.tsv`), so a value on screen is the
// tool's own number. The picker is tested on lists of features made here, since the cut holds no name that two ids share.

import AppKit
@testable import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishRNASeqUI

fileprivate typealias Unit = RNASeqCellMapDatabase.GeneUnit
fileprivate typealias Feature = RNASeqCellMapDatabase.Feature

@MainActor
enum RNASeqEmbeddingGeneSupport {
    static let cells = 200
    static let truth = RNASeqFixtures.root.appendingPathComponent("cell-map-pbmc_1k_v3/genes-of-interest-starsolo.tsv")

    fileprivate static func choice(_ name: String, _ unit: Unit, in features: [Feature]) throws -> RNASeqGeneChoice {
        let found = try XCTUnwrap(features.first { $0.name == name && $0.type == "Gene Expression" }, "\(name) is in the cut")
        return RNASeqGeneChoice(feature: found.feature, id: found.id, name: found.name, unit: unit)
    }

    /// The palette index of every cell from the stored row alone: grey for a cell with no count, else the step of its value
    /// on a scale from 0 to the p99, or to the maximum when the p99 is 0 (5.5 L3, V3).
    static func expectedIndex(_ stored: RNASeqCellMapDatabase.GeneValues) -> [UInt16] {
        var value = [Double](repeating: 0, count: cells)
        for (cell, amount) in zip(stored.cells, stored.floats) { value[Int(cell) - 1] = Double(amount) }
        let top = stored.p99 > 0 ? stored.p99 : stored.maximum
        return value.map { amount in
            guard amount > 0, top > 0 else { return RNASeqEmbeddingPalette.greyIndex }
            return RNASeqEmbeddingPalette.gradientBase + UInt16(min(Int(amount / top * Double(RNASeqEmbeddingPalette.gradientSteps - 1)),
                                                                    RNASeqEmbeddingPalette.gradientSteps - 1))
        }
    }

    /// CM-TRUTH's rows of one gene by cell column, which is the cell number in a one-sample result.
    static func truthRows(_ gene: String) throws -> [Int: (umis: Int, bits: UInt32)] {
        var found: [Int: (umis: Int, bits: UInt32)] = [:]
        for line in try String(contentsOf: truth, encoding: .utf8).split(separator: "\n").dropFirst() {
            let field = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard field.count == 7, field[1] == gene, let column = Int(field[2]), let umis = Int(field[4]),
                  let bits = UInt32(field[6], radix: 16) else { continue }
            found[column] = (umis, bits)
        }
        return found
    }

    /// W5 as the brief words it.
    fileprivate static func w5(_ unit: Unit, _ gene: String) -> String {
        "Colour shows \(unit == .umis ? "UMIs" : "normalised UMIs") of \(gene) in each cell. Grey cells have no UMIs of \(gene) counted, which does not show that the gene is off."
    }

    fileprivate static func feature(_ number: Int, _ id: String, _ name: String, _ type: String = "Gene Expression", cells: Int = 10) -> Feature {
        Feature(feature: number, id: id, name: name, type: type, total: cells * 3, cells: cells)
    }
}

@MainActor
final class RNASeqEmbeddingGeneTests: XCTestCase {
    typealias Support = RNASeqEmbeddingGeneSupport
    var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "cm-gene") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    fileprivate func open() throws -> (database: RNASeqCellMapDatabase, shown: RNASeqCellMapSnapshot, features: [Feature]) {
        let (_, map) = try RNASeqCellMapViewFixtures.cellMap(in: root)
        let shown = try RNASeqCellMapLoader.snapshot(result: try RNASeqResultBundle.load(from: map), bundleURL: map)
        return (shown.database, shown, try shown.database.features())
    }

    fileprivate func colours(_ gene: RNASeqGeneChoice, _ open: (database: RNASeqCellMapDatabase, shown: RNASeqCellMapSnapshot, features: [Feature]))
        throws -> RNASeqCellMapColours {
        let values = try RNASeqCellMapLoader.values(open.database, colouring: .gene(gene))
        return try RNASeqCellMapColours.make(facts: open.shown.facts, colouring: .gene(gene), values: values, points: open.shown.points)
    }

    /// Each cell's colour equals what `gene_values` holds for LYZ and S100A9 in both units, and what those values hold
    /// equals the tool's own count and float32 value (raw UMIs exactly, normalised within 1 ulp as 5.5 G1 allows).
    func testEachCellsColourValueEqualsTheStoredGeneValuesForLYZAndS100A9InBothUnits() throws {
        let map = try open()
        for (name, id) in [("LYZ", "ENSG00000090382"), ("S100A9", "ENSG00000163220")] {
            let truth = try Support.truthRows(name)
            XCTAssertFalse(truth.isEmpty, "CM-TRUTH lists cells for \(name)")
            for unit in Unit.allCases {
                let gene = try Support.choice(name, unit, in: map.features)
                XCTAssertEqual(gene.id, id)
                let stored = try XCTUnwrap(try map.database.geneValues(feature: gene.feature, unit: unit))
                guard case .gene(let read) = try RNASeqCellMapLoader.values(map.database, colouring: .gene(gene)) else {
                    return XCTFail("the loader reads a gene's values")
                }
                XCTAssertEqual(read.values, stored, "\(name) \(unit): the view reads the stored row")
                let made = try colours(gene, map)
                XCTAssertEqual(Array(made.index), Support.expectedIndex(stored), "\(name) \(unit): the colour of every cell")
                // Zeros draw first in grey and the rest in rising order of value, cell number breaking a tie (5.5 V3).
                var value = [Double](repeating: 0, count: Support.cells)
                for (cell, amount) in zip(stored.cells, stored.floats) { value[Int(cell) - 1] = Double(amount) }
                let drawn = (1...Support.cells).filter { !RNASeqCellMapViewFixtures.leftOut.contains(Int32($0)) }
                let counted = drawn.filter { value[$0 - 1] > 0 }.sorted { value[$0 - 1] != value[$1 - 1] ? value[$0 - 1] < value[$1 - 1] : $0 < $1 }
                XCTAssertEqual(made.order.map { Int($0) + 1 }, drawn.filter { value[$0 - 1] == 0 } + counted, "\(name) \(unit): the draw order")
                XCTAssertEqual(Set(stored.cells.map { Int($0) }), Set(truth.keys), "\(name) \(unit): the cells with a count")
                for (cell, value) in zip(stored.cells, stored.floats) {
                    let known = try XCTUnwrap(truth[Int(cell)])
                    if unit == .umis {
                        XCTAssertEqual(Int(value), known.umis, "\(name) cell \(cell) UMIs")
                    } else {
                        XCTAssertLessThanOrEqual(abs(Int64(value.bitPattern) - Int64(known.bits)), 1, "\(name) cell \(cell) normalised")
                    }
                }
            }
        }
    }

    /// The legend holds the stored minimum, maximum and p99 of the unit shown, the unit, the formula the file records and
    /// W5. Each unit has its own bounds.
    func testTheLegendHoldsTheStoredBoundsOfTheUnitShownItsFormulaAndW5() throws {
        let map = try open()
        let formula = try XCTUnwrap(try map.database.meta()["normalisation"])
        var tops: [Double] = []
        for unit in Unit.allCases {
            let gene = try Support.choice("LYZ", unit, in: map.features)
            let stored = try XCTUnwrap(try map.database.geneValues(feature: gene.feature, unit: unit))
            XCTAssertGreaterThan(stored.p99, 0, "LYZ is counted in enough of the 200 cells for a p99 above 0")
            let legend = try colours(gene, map).legend
            let top = stored.p99
            XCTAssertEqual(legend.scale, .init(minimum: stored.minimum, maximum: stored.maximum, p99: stored.p99))
            XCTAssertEqual(legend.scale?.top, top)
            XCTAssertEqual(legend.title, "LYZ \(unit == .umis ? "UMIs" : "normalised UMIs")")
            XCTAssertEqual(legend.formula, unit == .normalised ? formula : nil, "the formula is the file's, and raw UMIs have none")
            let n = RNASeqEmbeddingWords.number
            XCTAssertEqual(legend.words, [
                Support.w5(unit, "LYZ"),
                "Colour runs from 0 to \(n(top)), the 99th percentile of all 200 cells of this cell map, zeros included. Cells above \(n(top)) take the top colour, and the largest value is \(n(stored.maximum)).",
            ])
            tops.append(top)
        }
        XCTAssertNotEqual(tops[0], tops[1], "the UMIs and the normalised value each have their own bounds")
        XCTAssertEqual(formula, "log1p(10000 * UMIs / cell Gene Expression UMIs)")
    }

    /// A gene counted in at most 2 of 200 cells has a p99 of 0, so the scale runs to its maximum and the words say so. A
    /// gene no cell counts draws every cell in grey and says that all cells have 0.
    func testAGeneWhoseP99IsZeroShowsItsMaximumWithItsWordsAndAnUncountedGeneIsAllGrey() throws {
        let map = try open()
        let rare = try XCTUnwrap(map.features.first { $0.type == "Gene Expression" && (1...2).contains($0.cells) }, "a gene counted in one or two cells")
        for unit in Unit.allCases {
            let gene = RNASeqGeneChoice(feature: rare.feature, id: rare.id, name: rare.name, unit: unit)
            let stored = try XCTUnwrap(try map.database.geneValues(feature: rare.feature, unit: unit))
            XCTAssertEqual(stored.p99, 0, "\(rare.name) \(unit): at most 2 of 200 cells is under rank 198")
            XCTAssertGreaterThan(stored.maximum, 0)
            let made = try colours(gene, map)
            XCTAssertEqual(made.legend.scale?.top, stored.maximum, "the legend uses the maximum")
            let top = RNASeqEmbeddingWords.number(stored.maximum)
            XCTAssertEqual(made.legend.words, [Support.w5(unit, rare.name),
                "Colour runs from 0 to \(top), the largest value, since at least 99% of the 200 cells of this cell map have 0."])
            XCTAssertEqual(made.index.filter { $0 >= RNASeqEmbeddingPalette.gradientBase }.max(),
                           RNASeqEmbeddingPalette.gradientBase + UInt16(RNASeqEmbeddingPalette.gradientSteps - 1), "the largest value takes the top colour")
            XCTAssertEqual(Array(made.index), Support.expectedIndex(stored))
        }
        let silent = try XCTUnwrap(map.features.first { $0.type == "Gene Expression" && $0.cells == 0 }, "a gene no cell counts")
        let gene = RNASeqGeneChoice(feature: silent.feature, id: silent.id, name: silent.name, unit: .normalised)
        let made = try colours(gene, map)
        XCTAssertTrue(made.index.allSatisfy { $0 == RNASeqEmbeddingPalette.greyIndex })
        XCTAssertEqual(made.legend.words, [Support.w5(.normalised, silent.name), "All 200 cells of this cell map have 0, so every cell draws in grey."])
        XCTAssertThrowsError(try RNASeqCellMapLoader.values(map.database, colouring: .gene(
            RNASeqGeneChoice(feature: 999_999, id: "none", name: "none", unit: .umis))), "a feature with no row has no values to read")
    }

    /// The count colourings keep their words, since the gene's grey sentence replaces only theirs.
    func testTheCountColouringsKeepTheirGreyCellsHaveZeroSentence() throws {
        let map = try open()
        let values = try RNASeqCellMapLoader.values(map.database, colouring: .cellUMIs)
        let words = try RNASeqCellMapColours.make(facts: map.shown.facts, colouring: .cellUMIs, values: values, points: map.shown.points).legend.words
        XCTAssertEqual(words.count, 1)
        XCTAssertEqual(words.first?.hasSuffix(" Grey cells have 0."), true, words.first ?? "no words")
    }

    /// A name that two ids hold lists both ids, the feature type shows, and an Antibody Capture feature is not offered.
    func testAGeneNameHeldByTwoIdsListsBothAndAntibodyCaptureIsNotOffered() throws {
        let index = RNASeqGeneIndex(features: [
            Support.feature(1, "ENSG00000015479", "MATR3"), Support.feature(2, "ENSG00000280987", "MATR3"),
            Support.feature(3, "ENSG00000198851", "CD3E"), Support.feature(4, "CD3_TotalSeqB", "CD3", "Antibody Capture"),
            Support.feature(5, "ENSG00000000003", "TSPAN6", cells: 0),
        ])
        let both = try index.search("matr3")
        XCTAssertEqual(both.map(\.id), ["ENSG00000015479", "ENSG00000280987"], "each id of the name is listed")
        XCTAssertEqual(both.map(\.sharesName), [true, true])
        XCTAssertEqual(both.compactMap { RNASeqGeneChoice(entry: $0, unit: .umis)?.label }, ["MATR3 (ENSG00000015479)", "MATR3 (ENSG00000280987)"], "a shared name names its id once picked")
        XCTAssertEqual(both.map(\.type), ["Gene Expression", "Gene Expression"], "the type shows")
        XCTAssertEqual(try index.search("ensg00000280987").map(\.feature), [2], "an id finds its own row")
        XCTAssertEqual(try index.search("  Tspan ").map(\.sharesName), [false])
        XCTAssertEqual(try index.search("tspan").first?.cells, 0, "the row carries the cells the file counts for it")
        XCTAssertEqual(try index.search(""), [], "nothing is listed for an empty search")
        let cd3 = try index.search("cd3")
        XCTAssertEqual(cd3.map(\.feature), [3, 4], "an offered gene comes before a feature that is not offered")
        XCTAssertEqual(cd3.map(\.offered), [true, false])
        XCTAssertNil(RNASeqGeneChoice(entry: cd3[1], unit: .normalised), "Antibody Capture is not offered")
        XCTAssertEqual(RNASeqGeneChoice(entry: cd3[0], unit: .umis), RNASeqGeneChoice(feature: 3, id: "ENSG00000198851", name: "CD3E", unit: .umis))
        XCTAssertEqual(RNASeqGeneChoice(entry: cd3[0], unit: .umis)?.label, "CD3E", "a name no other id holds stays bare")
    }

    /// A name that two ids hold shows the id in the title of the picked gene and in W5, so two genes never look alike
    /// (CM-GENE-BIO SF-1).
    func testASharedNameShowsItsIdInTheTitleAndW5() throws {
        let facts = try open().shown.facts
        let gene = RNASeqGeneChoice(feature: 1, id: "ENSG00000280987", name: "MATR3", unit: .umis, sharesName: true)
        XCTAssertEqual(facts.title(of: .gene(gene)), "MATR3 (ENSG00000280987) UMIs")
        XCTAssertEqual(RNASeqEmbeddingWords.geneColour(unit: .umis, gene: gene.label),
            "Colour shows UMIs of MATR3 (ENSG00000280987) in each cell. Grey cells have no UMIs of MATR3 (ENSG00000280987) counted, which does not show that the gene is off.")
    }

    /// The picker reads `features` of the cell map, so LYZ and S100A9 are found by name or by id, and the cut holds no CD3E.
    func testThePickerFindsLYZAndS100A9ByNameAndByIdInTheCellMapsFeatures() throws {
        let map = try open()
        let index = RNASeqGeneIndex(features: map.features)
        XCTAssertEqual(map.features.count, 1353)
        for (name, id) in [("LYZ", "ENSG00000090382"), ("S100A9", "ENSG00000163220")] {
            XCTAssertEqual(try index.search(name.lowercased()).first.map { [$0.name, $0.id, $0.type] }, [name, id, "Gene Expression"])
            XCTAssertEqual(try index.search(id).first?.name, name)
        }
        XCTAssertEqual(try index.search("CD3E"), [], "the cut holds no CD3E")
    }
}

/// The controller's side: a pick is a colouring choice, so it uses the newest-wins path of the other choices (5.5 V1).
@MainActor
final class RNASeqEmbeddingGeneControllerTests: XCTestCase {
    typealias Support = RNASeqEmbeddingGeneSupport
    var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "cm-gene-ui") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    /// Opens the fixture's cell map as the surface does, laid out with a raster on show. The surface holds the controller.
    func openController() async throws -> (RNASeqResultSurface, RNASeqCellMapViewController) {
        let (_, map) = try RNASeqCellMapViewFixtures.cellMap(in: root)
        let surface = RNASeqResultSurface()
        let outcome = RNASeqResultSurface.read(map)
        guard case .loaded(let result) = outcome else { throw XCTSkip("the cell map does not read") }
        surface.present(outcome, bundleURL: map, cellMap: await RNASeqCellMapLoader.load(result: result, bundleURL: map))
        let controller = try XCTUnwrap(surface.controller.cellMap)
        surface.controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        surface.controller.view.layoutSubtreeIfNeeded()
        controller.requestRaster()
        await settle(controller)
        XCTAssertNotNil(controller.snapshot, "the cell map opens")
        return (surface, controller)
    }

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

    fileprivate func gene(_ name: String, _ unit: Unit, _ controller: RNASeqCellMapViewController) throws -> RNASeqGeneChoice {
        try Support.choice(name, unit, in: try XCTUnwrap(controller.snapshot).database.features())
    }

    /// A second pick made while the first is read cancels the first, and only the second gene's buffer is shown. The
    /// first pick's read is let run a few steps before the second, and whichever step it reached the newest wins.
    func testASecondPickMadeDuringAFirstReadCancelsItAndOnlyTheSecondGenesBufferIsShown() async throws {
        let (surface, controller) = try await openController()
        defer { withExtendedLifetime(surface) {} }
        let lyz = try gene("LYZ", .normalised, controller), s100a9 = try gene("S100A9", .normalised, controller)
        controller.chooseColouring(.gene(lyz))
        let first = try XCTUnwrap(controller.work)
        controller.chooseColouring(.gene(s100a9))
        XCTAssertTrue(first.isCancelled, "the second pick cancels the read of the first")
        await settle(controller)
        await first.value
        let shown = try XCTUnwrap(controller.snapshot)
        XCTAssertEqual(shown.colouring, .gene(s100a9))
        guard case .gene(let read) = shown.values else { return XCTFail("a gene's values are shown") }
        XCTAssertEqual(read.values.feature, s100a9.feature, "only the second gene's buffer is shown")
        let stored = try XCTUnwrap(try shown.database.geneValues(feature: s100a9.feature, unit: .normalised))
        XCTAssertEqual(Array(shown.colours.index), Support.expectedIndex(stored))
        XCTAssertEqual(controller.colourPopUp.titleOfSelectedItem, "Gene: S100A9")
        XCTAssertEqual(texts(in: controller.view)["rnaseq-cell-map-legend-title"], "S100A9 normalised UMIs")
        for steps in [1, 3, 8] {
            controller.chooseColouring(.gene(lyz))
            for _ in 0..<steps { await Task.yield() }
            controller.chooseColouring(.gene(s100a9))
            await settle(controller)
            XCTAssertEqual(controller.snapshot?.colouring, .gene(s100a9), "the newest pick wins after \(steps) steps")
            guard case .gene(let again) = controller.snapshot?.values else { return XCTFail("a gene's values are shown") }
            XCTAssertEqual(again.values.feature, s100a9.feature)
        }
    }

    /// A gene picked while an embedding is read keeps that embedding, and the gene stays when the embedding changes.
    func testAGenePickedWhileAnEmbeddingIsReadKeepsTheEmbeddingAndTheGeneStaysWhenItChanges() async throws {
        let (surface, controller) = try await openController()
        defer { withExtendedLifetime(surface) {} }
        let lyz = try gene("LYZ", .normalised, controller)
        controller.chooseEmbedding(2)
        controller.chooseColouring(.gene(lyz))
        await settle(controller)
        XCTAssertEqual(controller.snapshot?.points.embedding, 2, "the embedding chosen first is kept")
        XCTAssertEqual(controller.snapshot?.colouring, .gene(lyz))
        XCTAssertEqual(controller.embeddingPopUp.titleOfSelectedItem, "PCA")
        controller.chooseEmbedding(1)
        await settle(controller)
        XCTAssertEqual(controller.snapshot?.points.embedding, 1)
        XCTAssertEqual(controller.snapshot?.colouring, .gene(lyz), "the gene stays when the embedding changes")
        XCTAssertEqual(controller.snapshot?.colours.order.count, 197, "the cells the UMAP leaves out are not drawn")
    }

    /// The legend shows the stored top, the unit and the formula of the file with W5, no word says "not expressed" or "expression
    /// level", hover names the unit, and the unit control switches to raw UMIs with the other row's bounds.
    func testColourByGeneShowsW5TheFormulaTheStoredTopAndTheCellsValueWithItsUnit() async throws {
        let (surface, controller) = try await openController()
        defer { withExtendedLifetime(surface) {} }
        let lyz = try gene("LYZ", .normalised, controller)
        controller.chooseColouring(.gene(lyz))
        await settle(controller)
        let shown = try XCTUnwrap(controller.snapshot)
        let formula = try XCTUnwrap(try shown.database.meta()["normalisation"])
        var found = texts(in: controller.view)
        XCTAssertEqual(found["rnaseq-cell-map-legend-title"], "LYZ normalised UMIs")
        XCTAssertEqual(found["rnaseq-cell-map-legend-words-0"], Support.w5(.normalised, "LYZ"))
        XCTAssertEqual(found["rnaseq-cell-map-legend-formula"], "Normalised UMIs are \(formula).")
        let stored = try XCTUnwrap(try shown.database.geneValues(feature: lyz.feature, unit: .normalised))
        XCTAssertEqual(found["rnaseq-cell-map-scale-top"], RNASeqEmbeddingWords.number(stored.p99))
        XCTAssertEqual(controller.plot.accessibilityLabel(), "UMAP of the cells, coloured by LYZ normalised UMIs")
        for banned in ["not expressed", "xpression level"] {
            XCTAssertFalse(found.values.contains { $0.contains(banned) }, "no word says \(banned)")
        }
        func hoverCell() async throws -> Int {
            let raster = try XCTUnwrap(controller.plot.raster)
            let pixel = raster.mapping.pixel(x: shown.points.x[0], y: shown.points.y[0])
            let cell = try XCTUnwrap(controller.plot.cell(at: controller.plot.viewPoint(column: Int(pixel.column), row: Int(pixel.row))))
            controller.hover(cell)
            await controller.hoverWork?.value
            return cell
        }
        var cell = try await hoverCell()
        func valueText(_ values: RNASeqCellMapDatabase.GeneValues) -> String {
            values.cells.firstIndex(of: UInt32(cell + 1)).map { RNASeqEmbeddingWords.number(Double(values.floats[$0])) } ?? "0"
        }
        XCTAssertEqual(controller.hoverWords?.hasSuffix("LYZ normalised UMIs \(valueText(stored))"), true, controller.hoverWords ?? "no hover")

        controller.geneUnitControl.selectedSegment = 1
        controller.geneUnitControl.sendAction(controller.geneUnitControl.action, to: controller.geneUnitControl.target)
        await settle(controller)
        XCTAssertEqual(controller.snapshot?.colouring, .gene(try gene("LYZ", .umis, controller)), "raw UMIs on request")
        let raw = try XCTUnwrap(try shown.database.geneValues(feature: lyz.feature, unit: .umis))
        found = texts(in: controller.view)
        XCTAssertEqual(found["rnaseq-cell-map-legend-title"], "LYZ UMIs")
        XCTAssertNil(found["rnaseq-cell-map-legend-formula"], "raw UMIs have no formula")
        XCTAssertEqual(found["rnaseq-cell-map-scale-top"], RNASeqEmbeddingWords.number(raw.p99))
        XCTAssertEqual(found["rnaseq-cell-map-legend-words-0"], Support.w5(.umis, "LYZ"))
        cell = try await hoverCell()
        XCTAssertEqual(controller.hoverWords?.hasSuffix("LYZ UMIs \(valueText(raw))"), true, controller.hoverWords ?? "no hover")
    }

    /// The Colour by list ends with Gene…, which opens the picker and colours nothing until a gene is picked from it. The
    /// unit control sits beside a gene only, and a pick uses the unit last chosen.
    func testTheColourByListEndsWithGeneAndThePickerColoursNothingUntilAGeneIsPicked() async throws {
        let (surface, controller) = try await openController()
        defer { withExtendedLifetime(surface) {} }
        let facts = try XCTUnwrap(controller.snapshot).facts
        XCTAssertEqual(controller.colourPopUp.itemTitles.count, facts.colourings.count + 1)
        XCTAssertEqual(controller.colourPopUp.itemTitles.last, "Gene…")
        XCTAssertEqual(controller.geneUnitControl.superview?.isHidden, true, "the unit control shows only beside a gene")
        let before = controller.colourPopUp.titleOfSelectedItem
        controller.colourPopUp.selectItem(at: facts.colourings.count)
        controller.colourPopUp.sendAction(controller.colourPopUp.action, to: controller.colourPopUp.target)
        let picker = try XCTUnwrap(controller.genePicker, "the Gene… item opens the picker")
        XCTAssertEqual(controller.snapshot?.colouring, facts.defaultColouring, "opening the picker colours nothing")
        XCTAssertEqual(controller.colourPopUp.titleOfSelectedItem, before, "the pop-up still names what is shown")
        await controller.geneIndexWork?.value
        picker.search("lyz")
        await picker.searchWork?.value
        let entry = try XCTUnwrap(picker.results.first)
        XCTAssertEqual([entry.name, entry.id, entry.type], ["LYZ", "ENSG00000090382", "Gene Expression"])
        picker.pick(entry)
        await settle(controller)
        let lyz = try gene("LYZ", .normalised, controller)
        XCTAssertEqual(controller.snapshot?.colouring, .gene(lyz), "the normalised value is the default colour")
        XCTAssertEqual(controller.geneUnitControl.superview?.isHidden, false)
        XCTAssertEqual(controller.geneUnitControl.selectedSegment, 0)
        XCTAssertEqual(controller.colourPopUp.titleOfSelectedItem, "Gene: LYZ")
        controller.chooseColouring(facts.defaultColouring)
        await settle(controller)
        XCTAssertEqual(controller.colourPopUp.itemTitles.last, "Gene…", "the item names the gene only while one is shown")
        XCTAssertEqual(controller.geneUnitControl.superview?.isHidden, true)

        // Raw UMIs asked for one gene do not carry to the next: the unit control is hidden by then (CM-GENE-BIO SF-3).
        controller.chooseColouring(.gene(lyz))
        await settle(controller)
        controller.geneUnitControl.selectedSegment = 1
        controller.geneUnitControl.sendAction(controller.geneUnitControl.action, to: controller.geneUnitControl.target)
        await settle(controller)
        XCTAssertEqual(controller.geneUnit, .umis)
        controller.chooseColouring(facts.defaultColouring)
        await settle(controller)
        XCTAssertEqual(controller.geneUnit, .normalised, "raw UMIs were asked for one gene, so the next gene starts normalised")
        controller.colourPopUp.selectItem(at: facts.colourings.count)
        controller.colourPopUp.sendAction(controller.colourPopUp.action, to: controller.colourPopUp.target)
        let again = try XCTUnwrap(controller.genePicker)
        await controller.geneIndexWork?.value
        again.search("s100a9")
        await again.searchWork?.value
        again.pick(try XCTUnwrap(again.results.first))
        await settle(controller)
        XCTAssertEqual(controller.snapshot?.colouring, .gene(try gene("S100A9", .normalised, controller)))
    }

    /// A label set named Sample repeats the title of the sample colouring, and two embeddings may share a name. AppKit's
    /// `addItem(withTitle:)` removes an earlier item of the same title, so each pop-up item must stay in step with the
    /// colouring or embedding it stands for (CM-GENE-BIO SF-4).
    static func withRepeatedTitles(_ shown: RNASeqCellMapSnapshot) -> RNASeqCellMapSnapshot {
        var renamed = shown
        renamed.facts.labelSets[0].name = "Sample"
        renamed.facts.embeddings[1].name = renamed.facts.embeddings[0].name
        return renamed
    }

    /// The cell map shown with the first label set named Sample and both embeddings named alike. The tests that use it are not
    /// async, so that a failure of the pop-ups, such as the exception AppKit raises for an item out of range, is a failure of
    /// the test and not an abort of the run.
    func openWithRepeatedTitles() throws -> (RNASeqResultSurface, RNASeqCellMapViewController) {
        let (_, map) = try RNASeqCellMapViewFixtures.cellMap(in: root)
        let surface = RNASeqResultSurface()
        let outcome = RNASeqResultSurface.read(map)
        guard case .loaded(let result) = outcome else { throw XCTSkip("the cell map does not read") }
        let shown = Self.withRepeatedTitles(try RNASeqCellMapLoader.snapshot(result: result, bundleURL: map))
        surface.present(outcome, bundleURL: map, cellMap: RNASeqCellMapLoadOutcome.loaded(shown))
        let controller = try XCTUnwrap(surface.controller.cellMap)
        surface.controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        surface.controller.view.layoutSubtreeIfNeeded()
        return (surface, controller)
    }

    /// Lets the reads in flight finish, as `settle` does, for a test that is not async.
    func settleNow(_ controller: RNASeqCellMapViewController) {
        let done = expectation(description: "the reads settle")
        Task { @MainActor in
            await self.settle(controller)
            await controller.geneIndexWork?.value
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
    }

    func testALabelSetNamedSampleAndTwoEmbeddingsOfOneNameKeepEveryPopUpItem() throws {
        let (surface, controller) = try openWithRepeatedTitles()
        defer { withExtendedLifetime(surface) {} }
        let facts = try XCTUnwrap(controller.snapshot).facts
        let colourTitles = facts.colourings.map { facts.title(of: $0) }
        let embeddingNames = facts.embeddings.map { $0.name }
        XCTAssertEqual(colourTitles[0], facts.title(of: .sample), "the first label set repeats the sample colouring's title")
        XCTAssertEqual(controller.embeddingPopUp.itemTitles, embeddingNames, "two embeddings of one name keep both items")
        XCTAssertEqual(controller.colourPopUp.numberOfItems, colourTitles.count + 1, "a repeated title keeps its own item")
        XCTAssertEqual(controller.colourPopUp.itemTitles, colourTitles + ["Gene…"], "each item names its colouring, and the last is Gene…")
    }

    func testTheItemsOfARepeatedTitleColourByWhatTheyName() throws {
        let (surface, controller) = try openWithRepeatedTitles()
        defer { withExtendedLifetime(surface) {} }
        let facts = try XCTUnwrap(controller.snapshot).facts
        let umisIndex = try XCTUnwrap(facts.colourings.firstIndex(of: .cellUMIs))
        controller.colourPopUp.selectItem(at: umisIndex)
        controller.colourPopUp.sendAction(controller.colourPopUp.action, to: controller.colourPopUp.target)
        settleNow(controller)
        XCTAssertEqual(controller.snapshot?.colouring, .cellUMIs, "the item at a colouring's index colours by it")
        controller.colourPopUp.selectItem(withTitle: "Genes per cell")
        controller.colourPopUp.sendAction(controller.colourPopUp.action, to: controller.colourPopUp.target)
        settleNow(controller)
        XCTAssertEqual(controller.snapshot?.colouring, .cellGenes, "the item that reads Genes per cell colours by it")
        controller.colourPopUp.selectItem(withTitle: "UMIs per cell")
        controller.colourPopUp.sendAction(controller.colourPopUp.action, to: controller.colourPopUp.target)
        settleNow(controller)
        XCTAssertEqual(controller.snapshot?.colouring, .cellUMIs, "the item that reads UMIs per cell colours by it")
    }

    func testGeneAfterARepeatedTitleOpensThePickerAndColoursNothing() throws {
        let (surface, controller) = try openWithRepeatedTitles()
        defer { withExtendedLifetime(surface) {} }
        let facts = try XCTUnwrap(controller.snapshot).facts
        controller.colourPopUp.selectItem(withTitle: "Gene…")
        controller.colourPopUp.sendAction(controller.colourPopUp.action, to: controller.colourPopUp.target)
        XCTAssertNotNil(controller.genePicker, "Gene… opens the picker")
        settleNow(controller)
        XCTAssertEqual(controller.snapshot?.colouring, facts.defaultColouring, "opening the picker colours nothing")
    }

    /// The picker lists matches, the newest search wins, and only an offered gene is picked.
    func testThePickerKeepsTheNewestSearchAndPicksOnlyAnOfferedGene() async throws {
        let index = RNASeqGeneIndex(features: [
            Support.feature(1, "ENSG00000015479", "MATR3"), Support.feature(2, "ENSG00000280987", "MATR3"),
            Support.feature(3, "ENSG00000198851", "CD3E"), Support.feature(4, "CD3_TotalSeqB", "CD3", "Antibody Capture"),
        ])
        let picker = RNASeqEmbeddingGenePickerViewController()
        _ = picker.view
        var picked: [Int] = []
        picker.onPick = { picked.append($0.feature) }
        picker.search("matr3")
        picker.show(index: index)
        await picker.searchWork?.value
        XCTAssertEqual(picker.results.map(\.feature), [1, 2], "a search made before the genes were read runs when they are")
        picker.search("matr3")
        picker.search("cd3")
        await picker.searchWork?.value
        XCTAssertEqual(picker.results.map(\.feature), [3, 4], "the newest search is the one shown")
        picker.pick(picker.results[1])
        XCTAssertEqual(picked, [], "an Antibody Capture feature is not offered")
        picker.pick(picker.results[0])
        XCTAssertEqual(picked, [3])
    }
}
