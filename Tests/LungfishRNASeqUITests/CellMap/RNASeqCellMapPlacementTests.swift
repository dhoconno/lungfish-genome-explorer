// RNASeqCellMapPlacementTests.swift - The cell map's VoiceOver order and its ruled caveats, pinned (Phase 5.6 lane TV-CELLMAP)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// 5.6 Q1. The first commit of the lane pins, at its base, the ordered AX children of the cell map's root (role,
// identifier, label), walked with `accessibilityChildren()`, and the ids of the ruled caveats each state lays. The move
// of the words changes these pins only as the plan's Cell map table says (UX 5, BIO). The file reads no source.

import AppKit
@testable import LungfishIO
import LungfishKit
import XCTest
@testable import LungfishRNASeqUI
@testable import LungfishWorkflow

/// One element of the cell map's AX walk.
struct RNASeqCellMapAXEntry: Equatable, CustomStringConvertible {
    let role: String
    let id: String
    let label: String

    init(_ role: String, _ id: String, _ label: String) {
        self.role = role
        self.id = id
        self.label = label
    }

    var description: String { "(\"\(role)\", \"\(id)\", \"\(label)\")" }
}

@MainActor
enum RNASeqCellMapAX {
    /// The role, identifier, label and children of one AX element, which AppKit gives as a view, a cell or an element.
    static func read(_ element: Any) -> (entry: RNASeqCellMapAXEntry, children: [Any])? {
        guard let element = element as? NSAccessibilityProtocol else { return nil }
        // A control's element is often its cell, and the identifier sits on the control.
        let control = (element as? NSCell)?.controlView
        let own: String? = element.accessibilityIdentifier()
        let id = own.flatMap { $0.isEmpty ? nil : $0 } ?? control?.accessibilityIdentifier() ?? ""
        let label = element.accessibilityLabel().flatMap { $0.isEmpty ? nil : $0 } ?? control?.accessibilityLabel() ?? ""
        return (RNASeqCellMapAXEntry(element.accessibilityRole()?.rawValue ?? "", id, label), element.accessibilityChildren() ?? [])
    }

    /// Every element under `root` in the order VoiceOver walks it, depth first.
    static func order(of root: NSView) -> [RNASeqCellMapAXEntry] {
        var found: [RNASeqCellMapAXEntry] = []
        func walk(_ elements: [Any]) {
            for element in elements {
                guard let (entry, children) = read(element) else { continue }
                found.append(entry)
                walk(children)
            }
        }
        walk(root.accessibilityChildren() ?? [])
        return found
    }
}

extension RNASeqCellMapViewControllerTests {
    /// The ids of the word and fact lines laid in view, the legend's words and the selection's note, sorted. A field
    /// with no words is not counted.
    func caveatIDs(in view: NSView) -> [String] {
        let prefixes = ["rnaseq-cell-map-caption", "rnaseq-cell-map-imported", "rnaseq-cell-map-other-counts", "rnaseq-cell-map-left-out-",
                        "rnaseq-cell-map-computed-labels", "rnaseq-cell-map-cluster-numbers", "rnaseq-cell-map-fact-",
                        "rnaseq-cell-map-legend-words-", "rnaseq-cell-map-legend-formula", "rnaseq-cell-map-selection-note"]
        return texts(in: view).filter { id, words in !words.isEmpty && prefixes.contains { id.hasPrefix($0) } }.keys.sorted()
    }

    /// 5.6 U7. The words of drawn, visible static text under `root`: every text field that is shown and holds words,
    /// leaving out legend rows, the labels of control rows and control titles by type (a button, a pop-up or a
    /// segmented control is not a text field). The shared slider's hosting view is left out whole.
    func visibleWords(in root: NSView, legend: RNASeqEmbeddingLegendView) -> Int {
        let rows = Set(legend.rowViews.map(ObjectIdentifier.init))
        var count = 0
        func walk(_ view: NSView) {
            if view.isHiddenOrHasHiddenAncestor || rows.contains(ObjectIdentifier(view)) { return }
            if String(describing: type(of: view)).hasPrefix("NSHostingView") { return }
            if let field = view as? NSTextField, field.frame.width > 0, field.frame.height > 0 {
                let rowLabel = (field.superview as? NSStackView)?.arrangedSubviews.contains { $0 is NSControl && !($0 is NSTextField) } == true
                    || (field.superview as? NSStackView)?.arrangedSubviews.contains { String(describing: type(of: $0)).hasPrefix("NSHostingView") } == true
                if !rowLabel { count += field.stringValue.split(whereSeparator: \.isWhitespace).count }
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return count
    }

    /// A cell map with the walk state's facts: pbmc_1k_v3-tsne, a t-SNE imported on other counts with 3 cells left out,
    /// coloured by the imported graphclust of 7 clusters with 3 cells unlabelled, one sample of a fixed name.
    func walkStateMap() throws -> URL {
        let parent = try RNASeqCellMapViewFixtures.parent(RNASeqCellMapViewFixtures.starsolo, name: "pbmc_1k_v3", in: root)
        let all = Array(1...Int32(200))
        let drawn = all.filter { !RNASeqCellMapViewFixtures.leftOut.contains($0) }
        let labelled = all.filter { !RNASeqCellMapViewFixtures.unlabelled.contains($0) }
        var values: [Double] = []
        for cell in drawn {
            let point = RNASeqCellMapViewFixtures.umap(cell)
            values += [point.x, point.y]
        }
        let labels: [String] = labelled.map { String($0 % 7 + 1) }
        let embedding = RNASeqResultWriter.CellMapRequest.Embedding(
            name: "TSNE", method: "t-SNE", source: .imported, sourceFile: "source/1/projection.csv", otherCounts: true,
            dimensions: 2, cells: drawn, values: values)
        let set = RNASeqResultWriter.CellMapRequest.LabelSet(
            name: "graphclust", source: .imported, sourceFile: "source/2/clusters.csv", cells: labelled, labels: labels)
        let request = RNASeqResultWriter.CellMapRequest(
            name: "pbmc_1k_v3-tsne", parent: parent, origin: .init(kind: .imported, tool: "Cell Ranger"),
            embeddings: [embedding], labelSets: [set], createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let map = root.appendingPathComponent("pbmc_1k_v3-tsne.lungfishrnaseq", isDirectory: true)
        try RNASeqCellMapViewFixtures.write(request, to: map)
        return map
    }

    /// Opens `map` as the surface does, at `size`, with a raster on show.
    func open(_ map: URL, size: NSSize = NSSize(width: 1200, height: 800)) async throws -> (RNASeqResultSurface, RNASeqCellMapViewController) {
        let surface = RNASeqResultSurface()
        let outcome = RNASeqResultSurface.read(map)
        guard case .loaded(let result) = outcome else { throw XCTSkip("the cell map does not read") }
        surface.present(outcome, bundleURL: map, cellMap: await RNASeqCellMapLoader.load(result: result, bundleURL: map))
        let controller = try XCTUnwrap(surface.controller.cellMap)
        surface.controller.view.frame = NSRect(origin: .zero, size: size)
        surface.controller.view.layoutSubtreeIfNeeded()
        controller.requestRaster()
        await settle(controller)
        return (surface, controller)
    }

    /// 5.6 U7. The walk state's words, and a hidden label and a button title leave the count as it was.
    func testTheWalkStateReadsItsPinnedWordCount() async throws {
        let (surface, controller) = try await open(try walkStateMap())
        defer { withExtendedLifetime(surface) {} }
        XCTAssertEqual(controller.embeddingPopUp.titleOfSelectedItem, "TSNE")
        XCTAssertEqual(controller.colourPopUp.titleOfSelectedItem, "graphclust")
        let words = visibleWords(in: controller.view, legend: controller.legendView)
        let hidden = NSTextField(labelWithString: "one two three")
        hidden.isHidden = true
        let button = NSButton(title: "Four five", target: nil, action: nil)
        controller.view.addSubview(hidden)
        controller.view.addSubview(button)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(visibleWords(in: controller.view, legend: controller.legendView), words, "a hidden label and a button title count no word")
        XCTAssertEqual(words, Self.pinnedWalkStateWords, "the walk state's words")
    }

    /// LYZ in the unit asked, from the cell map's features.
    func lyz(_ controller: RNASeqCellMapViewController) throws -> RNASeqGeneChoice {
        let features = try XCTUnwrap(controller.snapshot).database.features()
        let found = try XCTUnwrap(features.first { $0.name == "LYZ" && $0.type == "Gene Expression" }, "LYZ is in the cut")
        return RNASeqGeneChoice(feature: found.feature, id: found.id, name: found.name, unit: .normalised)
    }

    /// 5.6 Q1, UX 5. The order VoiceOver reads the cell map in, opened on its first embedding coloured by its label set.
    func testTheCellMapRootsAXOrderIsPinned() async throws {
        let (surface, controller) = try await openController()
        defer { withExtendedLifetime(surface) {} }
        let order = RNASeqCellMapAX.order(of: controller.view)
        XCTAssertEqual(order, Self.pinnedAXOrder, "the AX order:\n" + order.map(\.description).joined(separator: ",\n"))
    }

    /// 5.6 Q1, BIO. The ruled caveats each state lays, by id.
    func testTheRuledCaveatIDsOfEachStateArePinned() async throws {
        let (surface, controller) = try await openController()
        defer { withExtendedLifetime(surface) {} }
        var found: [String: [String]] = [:]
        var words: [String: Int] = [:]
        func record(_ state: String) {
            controller.view.layoutSubtreeIfNeeded()
            found[state] = caveatIDs(in: controller.view)
            words[state] = visibleWords(in: controller.view, legend: controller.legendView)
        }
        record("open")
        controller.selectLegendRow(0, adding: false)
        await settle(controller)
        await controller.selectionWork?.value
        record("legend row")
        controller.selectPolygon([.init(x: -1000, y: -1000), .init(x: 1000, y: -1000), .init(x: 1000, y: 1000)], mode: .add)
        await controller.selectionWork?.value
        record("joined")
        controller.cancelOperation(nil)
        controller.chooseColouring(.sample)
        await settle(controller)
        record("sample")
        controller.chooseColouring(.cellUMIs)
        await settle(controller)
        record("umis")
        controller.chooseColouring(.gene(try lyz(controller)))
        await settle(controller)
        record("gene")
        controller.chooseEmbedding(2)
        await settle(controller)
        record("pca")
        for state in found.keys.sorted() {
            XCTAssertEqual(found[state], Self.pinnedCaveatIDs[state], "\(state): \(found[state] ?? [])")
            XCTAssertEqual(words[state], Self.pinnedWordCounts[state], "\(state) words: \(words[state] ?? -1)")
        }
        XCTAssertEqual(Set(found.keys), Set(Self.pinnedCaveatIDs.keys))
    }

    /// The legend's 21 values as VoiceOver reads them under the plot.
    static let plotChildren = (1...21).map { label -> RNASeqCellMapAXEntry in
        RNASeqCellMapAXEntry("AXStaticText", "", "\(label), \([2, 3, 4, 5, 9, 10, 11, 12].contains(label) ? 10 : 9) cells")
    }

    /// The 21 legend rows of the column, a name and a count each.
    static let legendRows = (0...20).flatMap { row in
        [RNASeqCellMapAXEntry("AXStaticText", "rnaseq-cell-map-legend-\(row)-name", ""),
         RNASeqCellMapAXEntry("AXStaticText", "rnaseq-cell-map-legend-\(row)-count", "")]
    }

    /// The scroll view's vertical scroller and its parts.
    static let scroller = [RNASeqCellMapAXEntry("AXScrollBar", "", ""), RNASeqCellMapAXEntry("AXValueIndicator", "", "")]
        + Array(repeating: RNASeqCellMapAXEntry("AXButton", "", ""), count: 4)

    /// The base's order (5.6 Q1), at c2612e446's view with TV-INSPECT's commits on e5080bf7c.
    static let pinnedAXOrder: [RNASeqCellMapAXEntry] = [RNASeqCellMapAXEntry("AXGroup", "rnaseq-cell-map-plot", "UMAP of the cells, coloured by graphclust")]
        + plotChildren + [
            RNASeqCellMapAXEntry("AXStaticText", "rnaseq-cell-map-axis-x", ""),
            RNASeqCellMapAXEntry("AXStaticText", "rnaseq-cell-map-axis-y", ""),
            RNASeqCellMapAXEntry("AXScrollArea", "", ""),
            RNASeqCellMapAXEntry("AXStaticText", "", ""),
            RNASeqCellMapAXEntry("AXPopUpButton", "rnaseq-cell-map-embedding", ""),
            RNASeqCellMapAXEntry("AXStaticText", "", ""),
            RNASeqCellMapAXEntry("AXPopUpButton", "rnaseq-cell-map-colour", ""),
            RNASeqCellMapAXEntry("AXStaticText", "", ""),
            RNASeqCellMapAXEntry("AXGroup", "", ""),
            RNASeqCellMapAXEntry("AXStaticText", "rnaseq-cell-map-legend-title", ""),
        ] + legendRows + [
            RNASeqCellMapAXEntry("AXStaticText", "rnaseq-cell-map-legend-words-0", ""),
            RNASeqCellMapAXEntry("AXStaticText", "rnaseq-cell-map-legend-words-1", ""),
            RNASeqCellMapAXEntry("AXStaticText", "rnaseq-cell-map-selection-count", ""),
            RNASeqCellMapAXEntry("AXButton", "rnaseq-cell-map-save-selection", "Save Selection as Labels Table…"),
            RNASeqCellMapAXEntry("AXButton", "rnaseq-cell-map-pseudobulk-selection", "Pseudobulk Selected Cells…"),
            RNASeqCellMapAXEntry("AXStaticText", "rnaseq-cell-map-caption", ""),
            RNASeqCellMapAXEntry("AXStaticText", "rnaseq-cell-map-imported", ""),
            RNASeqCellMapAXEntry("AXStaticText", "rnaseq-cell-map-other-counts", ""),
            RNASeqCellMapAXEntry("AXStaticText", "rnaseq-cell-map-left-out-1", ""),
            RNASeqCellMapAXEntry("AXStaticText", "rnaseq-cell-map-cluster-numbers", ""),
            RNASeqCellMapAXEntry("AXStaticText", "rnaseq-cell-map-imported-labels", ""),
            RNASeqCellMapAXEntry("AXStaticText", "", ""),
            RNASeqCellMapAXEntry("AXStaticText", "rnaseq-cell-map-fact-parent-result", ""),
            RNASeqCellMapAXEntry("AXStaticText", "", ""),
            RNASeqCellMapAXEntry("AXStaticText", "rnaseq-cell-map-fact-embedding", ""),
            RNASeqCellMapAXEntry("AXStaticText", "", ""),
            RNASeqCellMapAXEntry("AXStaticText", "rnaseq-cell-map-fact-source", ""),
            RNASeqCellMapAXEntry("AXStaticText", "", ""),
            RNASeqCellMapAXEntry("AXStaticText", "rnaseq-cell-map-fact-labels", ""),
            RNASeqCellMapAXEntry("AXStaticText", "", ""),
            RNASeqCellMapAXEntry("AXStaticText", "rnaseq-cell-map-fact-cells-drawn", ""),
            RNASeqCellMapAXEntry("AXStaticText", "rnaseq-cell-map-hover", ""),
        ] + scroller

    /// The ids every state laid at the base.
    static let factIDs = ["rnaseq-cell-map-fact-cells-drawn", "rnaseq-cell-map-fact-embedding", "rnaseq-cell-map-fact-parent-result",
                          "rnaseq-cell-map-fact-source"]

    static let pinnedCaveatIDs: [String: [String]] = [
        "open": ["rnaseq-cell-map-caption", "rnaseq-cell-map-cluster-numbers", "rnaseq-cell-map-fact-cells-drawn", "rnaseq-cell-map-fact-embedding",
                 "rnaseq-cell-map-fact-labels", "rnaseq-cell-map-fact-parent-result", "rnaseq-cell-map-fact-source", "rnaseq-cell-map-imported",
                 "rnaseq-cell-map-imported-labels", "rnaseq-cell-map-left-out-1", "rnaseq-cell-map-legend-words-0", "rnaseq-cell-map-legend-words-1",
                 "rnaseq-cell-map-other-counts"],
        "legend row": ["rnaseq-cell-map-caption", "rnaseq-cell-map-cluster-numbers", "rnaseq-cell-map-fact-cells-drawn", "rnaseq-cell-map-fact-embedding",
                       "rnaseq-cell-map-fact-labels", "rnaseq-cell-map-fact-parent-result", "rnaseq-cell-map-fact-source", "rnaseq-cell-map-imported",
                       "rnaseq-cell-map-imported-labels", "rnaseq-cell-map-left-out-1", "rnaseq-cell-map-legend-words-0", "rnaseq-cell-map-legend-words-1",
                       "rnaseq-cell-map-other-counts", "rnaseq-cell-map-selection-note"],
        "joined": ["rnaseq-cell-map-caption", "rnaseq-cell-map-cluster-numbers", "rnaseq-cell-map-fact-cells-drawn", "rnaseq-cell-map-fact-embedding",
                   "rnaseq-cell-map-fact-labels", "rnaseq-cell-map-fact-parent-result", "rnaseq-cell-map-fact-source", "rnaseq-cell-map-imported",
                   "rnaseq-cell-map-imported-labels", "rnaseq-cell-map-left-out-1", "rnaseq-cell-map-legend-words-0", "rnaseq-cell-map-legend-words-1",
                   "rnaseq-cell-map-other-counts", "rnaseq-cell-map-selection-note"],
        "sample": ["rnaseq-cell-map-caption", "rnaseq-cell-map-fact-cells-drawn", "rnaseq-cell-map-fact-embedding", "rnaseq-cell-map-fact-parent-result",
                   "rnaseq-cell-map-fact-source", "rnaseq-cell-map-imported", "rnaseq-cell-map-left-out-1", "rnaseq-cell-map-other-counts"],
        "umis": ["rnaseq-cell-map-caption", "rnaseq-cell-map-fact-cells-drawn", "rnaseq-cell-map-fact-embedding", "rnaseq-cell-map-fact-parent-result",
                 "rnaseq-cell-map-fact-source", "rnaseq-cell-map-imported", "rnaseq-cell-map-left-out-1", "rnaseq-cell-map-legend-words-0",
                 "rnaseq-cell-map-other-counts"],
        "gene": ["rnaseq-cell-map-caption", "rnaseq-cell-map-fact-cells-drawn", "rnaseq-cell-map-fact-embedding", "rnaseq-cell-map-fact-parent-result",
                 "rnaseq-cell-map-fact-source", "rnaseq-cell-map-imported", "rnaseq-cell-map-left-out-1", "rnaseq-cell-map-legend-formula",
                 "rnaseq-cell-map-legend-words-0", "rnaseq-cell-map-legend-words-1", "rnaseq-cell-map-other-counts"],
        "pca": ["rnaseq-cell-map-caption", "rnaseq-cell-map-fact-cells-drawn", "rnaseq-cell-map-fact-embedding", "rnaseq-cell-map-fact-parent-result",
                "rnaseq-cell-map-fact-source", "rnaseq-cell-map-imported", "rnaseq-cell-map-legend-formula", "rnaseq-cell-map-legend-words-0",
                "rnaseq-cell-map-legend-words-1"],
    ]

    /// The words each state reads at the lane's base (5.6 U7).
    static let pinnedWordCounts: [String: Int] = ["open": 198, "legend row": 216, "joined": 220, "sample": 126, "umis": 166, "gene": 199, "pca": 143]

    /// The walk state's words at the lane's base (5.6 U7).
    static let pinnedWalkStateWords = 193
}
