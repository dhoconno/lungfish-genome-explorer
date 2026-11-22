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
import LungfishTestSupport
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
    func walkStateMap(labelSet: String = "graphclust", embedding embeddingName: String = "TSNE") throws -> URL {
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
            name: embeddingName, method: "t-SNE", source: .imported, sourceFile: "source/1/projection.csv", otherCounts: true,
            dimensions: 2, cells: drawn, values: values)
        let set = RNASeqResultWriter.CellMapRequest.LabelSet(
            name: labelSet, source: .imported, sourceFile: "source/2/clusters.csv", cells: labelled, labels: labels)
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
        print("TV-CELLMAP walk-state words \(words), base \(Self.pinnedWalkStateWords)")
        XCTAssertLessThanOrEqual(words, Self.pinnedWalkStateWords, "the walk state reads no more words than at the base")
        XCTAssertEqual(words, Self.walkStateWordBar, "the walk state reads the bar UX set")
    }

    /// 5.6 U7's bar for the walk state. The ruled lines alone read 46 words, past 40, so a ruled line wins and UX sets the
    /// bar at the head's measured count (`docs/plans/2026-11-21-text-in-views.md:164`, TV-CELLMAP decided item 7). The
    /// base read 193 (`pinnedWalkStateWords`).
    static let walkStateWordBar = 51

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
        XCTAssertEqual(order, Self.structureAXOrder, "the AX order:\n" + order.map(\.description).joined(separator: ",\n"))
    }

    /// The pin after the move (UX 5): the caption and W3 give way to their info buttons, each right after the pop-up it
    /// explains, and the lines about the embedding and the label set sit under their pop-ups, in the order they had.
    static var structureAXOrder: [RNASeqCellMapAXEntry] {
        var order = pinnedAXOrder
        let start = order.firstIndex { $0.id == "rnaseq-cell-map-caption" } ?? 0
        let end = order.firstIndex { $0.id == "rnaseq-cell-map-fact-cells-drawn" } ?? 0
        let block = Array(order[start...end])
        order.removeSubrange(start...end)
        // A fact's name label, which has no id, goes with the value after it.
        var lines: [[RNASeqCellMapAXEntry]] = []
        var name: [RNASeqCellMapAXEntry] = []
        for entry in block {
            if entry.id.isEmpty { name.append(entry) } else { lines.append(name + [entry]); name = [] }
        }
        // The words step: the P rows leave the view (C17), and on this map of one sample the left-out line joins Cells
        // drawn, which keeps its place (C6a).
        let moved: Set<String> = ["rnaseq-cell-map-caption", "rnaseq-cell-map-cluster-numbers", joinedCellsDrawn]
        let kept = lines.filter { !moved.union(leftTheView).contains($0.last?.id ?? "") }
        let underColour = { (line: [RNASeqCellMapAXEntry]) in RNASeqCellMapViewController.labelLineIDs.contains(line.last?.id ?? "") }
        let embedding = (order.firstIndex { $0.id == "rnaseq-cell-map-embedding" } ?? 0) + 1
        order.insert(contentsOf: [RNASeqCellMapAXEntry("AXButton", "info-rnaseq.cellmap.embedding", "About UMAP")]
                     + kept.filter { !underColour($0) }.flatMap { $0 }, at: embedding)
        let colour = (order.firstIndex { $0.id == "rnaseq-cell-map-colour" } ?? 0) + 1
        order.insert(contentsOf: [RNASeqCellMapAXEntry("AXButton", "info-rnaseq.cellmap.clusters", "About clusters")]
                     + kept.filter(underColour).flatMap { $0 }, at: colour)
        // "About selecting" follows the selection line it explains (S1b).
        let count = (order.firstIndex { $0.id == "rnaseq-cell-map-selection-count" } ?? 0) + 1
        order.insert(RNASeqCellMapAXEntry("AXButton", "info-rnaseq.cellmap.selecting", "About selecting"), at: count)
        return order
    }

    /// The P rows that leave the view for the Inspector (C17), whose fact lines keep them.
    static let leftTheView: Set<String> = ["rnaseq-cell-map-fact-parent-result", "rnaseq-cell-map-fact-embedding", "rnaseq-cell-map-fact-source",
                                           "rnaseq-cell-map-fact-labels"]
    /// The left-out line that joins Cells drawn on a map of one sample (C6a).
    static let joinedCellsDrawn = "rnaseq-cell-map-left-out-1"

    /// Whether `view` is drawn inside the column's insets, not hidden and not cut short in height. The insets bound the
    /// view's alignment rect, where the stack lays it and where its content draws: a text field's frame reaches 2 pt past
    /// its alignment rect on each side, the cell's padding. The frame itself stays inside the column.
    func assertInsideTheColumn(_ view: NSView, _ what: String, in controller: RNASeqCellMapViewController, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(view.isHiddenOrHasHiddenAncestor, "\(what) is hidden", file: file, line: line)
        guard let column = controller.legendView.superview else { return XCTFail("no column", file: file, line: line) }
        let frame = view.convert(view.bounds, to: column)
        let laid = column.convert(view.alignmentRect(forFrame: view.frame), from: view.superview)
        let left = RNASeqCellMapViewController.columnInsets.left
        let right = column.bounds.width - RNASeqCellMapViewController.columnInsets.right
        XCTAssertGreaterThan(frame.width, 0, "\(what) has no width", file: file, line: line)
        XCTAssertGreaterThanOrEqual(laid.minX, left - 0.5, "\(what) starts left of the column: \(laid), frame \(frame)", file: file, line: line)
        XCTAssertLessThanOrEqual(laid.maxX, right + 0.5, "\(what) runs past the column: \(laid), frame \(frame)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(what)'s frame leaves the column: \(frame)", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, column.bounds.width + 0.5, "\(what)'s frame leaves the column: \(frame)", file: file, line: line)
        if let field = view as? NSTextField, field.preferredMaxLayoutWidth > 0 {
            XCTAssertLessThanOrEqual(field.intrinsicContentSize.height, field.frame.height + 1, "\(what) is cut short", file: file, line: line)
        }
    }

    /// 5.6 L1, SWIFT OBJECT 7. Every arranged subview of the column, and every text in it, lies inside the insets at 1200 by
    /// 800 and at the walk's 753 pt viewer, with long names, whether scroll bars overlay the column or always show beside
    /// it; the plot holds at least 60% of a 753 pt viewer.
    func testEveryRowOfTheColumnFitsItsInsetsAndThePlotTakesTheLargerShare() async throws {
        let map = try walkStateMap(labelSet: "gene_expression_kmeans_10_clusters", embedding: "TSNE_gene_expression_2_components")
        for style in [NSScroller.Style.overlay, .legacy] {
            for size in [NSSize(width: 1200, height: 800), NSSize(width: 753, height: 600)] {
                let (surface, controller) = try await open(map, size: size)
                defer { withExtendedLifetime(surface) {} }
                let at = "\(size), \(style == .legacy ? "legacy" : "overlay") scrollers"
                let column = try XCTUnwrap(controller.legendView.superview as? NSStackView)
                let side = try XCTUnwrap(column.enclosingScrollView)
                side.scrollerStyle = style
                controller.view.frame = NSRect(origin: .zero, size: size)
                controller.selectPolygon([.init(x: -1000, y: -1000), .init(x: 1000, y: -1000), .init(x: 1000, y: 1000)], mode: .replace)
                await controller.selectionWork?.value
                controller.view.layoutSubtreeIfNeeded()
                XCTAssertEqual(column.bounds.width, RNASeqCellMapViewController.columnWidth, accuracy: 0.5, "the column's width at \(at)")
                XCTAssertEqual(side.contentView.bounds.width, RNASeqCellMapViewController.columnWidth, accuracy: 0.5, "the column is not cut at \(at)")
                for (index, row) in column.arrangedSubviews.enumerated() where !row.isHidden {
                    assertInsideTheColumn(row, "row \(index) at \(at)", in: controller)
                }
                func fields(_ view: NSView) -> [NSTextField] { ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(fields) }
                for field in fields(column) where !field.isHiddenOrHasHiddenAncestor && !field.stringValue.isEmpty {
                    assertInsideTheColumn(field, "\(field.accessibilityIdentifier()) at \(at)", in: controller)
                }
                assertInsideTheColumn(controller.embeddingInfo, "About TSNE at \(at)", in: controller)
                assertInsideTheColumn(controller.clustersInfo, "About clusters at \(at)", in: controller)
                XCTAssertEqual(controller.colourPopUp.toolTip, "gene_expression_kmeans_10_clusters", "the whole name is in the help tag")
                guard size.width == 753, style == .overlay else { continue }
                XCTAssertEqual(controller.view.frame.width, 753, accuracy: 0.5, "the viewer")
                XCTAssertGreaterThanOrEqual(controller.plot.frame.width, 0.6 * 753, "the plot's share: \(controller.plot.frame.width) of 753")
                XCTAssertEqual(controller.plot.frame.width, 465, accuracy: 0.5)
            }
        }
    }

    func escapeKey(in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                       isARepeat: false, keyCode: 53))
    }

    /// 5.6 A1. With an info popover open, Escape closes it and keeps the selection, from the plot focused, the legend
    /// focused and the controller. With none open, Escape empties the selection as before.
    func testEscapeWithAnInfoPopoverOpenClosesItAndKeepsTheSelectionOnEachPath() async throws {
        let (surface, controller) = try await openController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface.controller.view
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            withExtendedLifetime(surface) {}
        }
        controller.selectLegendRow(0, adding: false)
        await settle(controller)
        await controller.selectionWork?.value
        let selected = try XCTUnwrap(controller.selection?.count)
        for (path, responder) in [("plot", controller.plot as NSResponder), ("legend", controller.legendView as NSResponder)] {
            XCTAssertTrue(window.makeFirstResponder(responder), path)
            controller.embeddingInfo.showPopover()
            XCTAssertTrue(controller.embeddingInfo.isPopoverShown, "\(path): the popover opens")
            NSApp.sendEvent(try escapeKey(in: window))
            XCTAssertTrue(waitUntilOnRunLoop(budget: .standard) { !controller.embeddingInfo.isPopoverShown }, "\(path): Escape closes the popover")
            XCTAssertEqual(controller.selection?.count, selected, "\(path): the selection stays")
            controller.embeddingInfo.showPopover()
            XCTAssertTrue(controller.embeddingInfo.isPopoverShown, "\(path): the popover opens again")
            responder.keyDown(with: try escapeKey(in: window))
            XCTAssertTrue(waitUntilOnRunLoop(budget: .standard) { !controller.embeddingInfo.isPopoverShown },
                          "\(path): its own key handler closes the popover first")
            XCTAssertEqual(controller.selection?.count, selected, "\(path): and keeps the selection")
        }
        controller.clustersInfo.showPopover()
        controller.cancelOperation(nil)
        XCTAssertTrue(waitUntilOnRunLoop(budget: .standard) { !controller.clustersInfo.isPopoverShown }, "cancelOperation closes the popover")
        XCTAssertEqual(controller.selection?.count, selected, "cancelOperation keeps the selection while it closes a popover")
        controller.cancelOperation(nil)
        XCTAssertNil(controller.selection, "with no popover open, Escape empties the selection")
    }

    /// BIO lane condition. Each info button is found in the AX tree by its id, a VoiceOver press opens its popover, and the
    /// popover holds the decided words.
    func testEachInfoButtonIsFoundThroughAXAndItsPressShowsTheDecidedWords() async throws {
        let (surface, controller) = try await openController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface.controller.view
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            withExtendedLifetime(surface) {}
        }
        func find(_ id: String, in elements: [Any]) -> Any? {
            for element in elements {
                guard let (entry, children) = RNASeqCellMapAX.read(element) else { continue }
                if entry.id == id { return element }
                if let inner = find(id, in: children) { return inner }
            }
            return nil
        }
        func press(_ button: LungfishInfoButton, shows words: String) throws {
            let id = LungfishInfoButton.accessibilityIdentifier(for: button.item)
            let element = try XCTUnwrap(find(id, in: controller.view.accessibilityChildren() ?? []) as? NSAccessibilityProtocol, "no AX element \(id)")
            // The column scrolls, and VoiceOver brings the element it presses into view first. A popover shows only beside a
            // button that is in view, and "About selecting" lies below the 21 legend rows.
            button.scrollToVisible(button.bounds)
            controller.view.layoutSubtreeIfNeeded()
            _ = element.accessibilityPerformPress()
            XCTAssertTrue(button.isPopoverShown, "\(id): a VoiceOver press opens the popover")
            XCTAssertEqual(button.popoverController.text, words, id)
            XCTAssertTrue(button.closePopover())
        }
        try press(controller.embeddingInfo, shows: RNASeqEmbeddingWords.caption(method: "UMAP", embedding: "UMAP") + "\n\n" + RNASeqEmbeddingWords.otherCountsPlace)
        try press(controller.clustersInfo, shows: RNASeqEmbeddingWords.clusterNumbers + "\n\n" + RNASeqEmbeddingWords.unlabelledGrey)
        try press(controller.selectingInfo, shows: RNASeqEmbeddingSelectionWords.howToSelect)
        controller.chooseColouring(.cellUMIs)
        await settle(controller)
        controller.view.layoutSubtreeIfNeeded()
        try press(controller.legendView.scaleInfo, shows: RNASeqEmbeddingWords.colourScale(cells: try XCTUnwrap(controller.snapshot).facts.cellCount, gene: false))
    }

    /// 5.6 A1. The cell map's items pass Kit's catalog check, for each method and each clusters caveat.
    func testTheCellMapsHelpItemsPassTheCatalogCheck() throws {
        for method in ["UMAP", "t-SNE", "PHATE", "PCA", nil] as [String?] {
            for (computed, numbers) in [(true, true), (true, false), (false, true)] {
                let items = [RNASeqEmbeddingWords.embeddingHelp(method: method, embedding: "TSNE", otherCounts: numbers),
                             try XCTUnwrap(RNASeqEmbeddingWords.clustersHelp(computed: computed, numbers: numbers, unlabelled: computed)),
                             RNASeqEmbeddingWords.scaleHelp(cells: 200, gene: computed), RNASeqEmbeddingSelectionWords.selectingHelp]
                XCTAssertEqual(LungfishHelpContent.catalogFaults(in: items), [], "\(method ?? "no method")")
            }
        }
        XCTAssertNil(RNASeqEmbeddingWords.clustersHelp(computed: false, numbers: false), "no clusters caveat holds, so no button")
    }

    /// 5.6 L1. The header's Name row sits under the toolbar on every RNA-seq result.
    func testTheResultSurfacePinsItsTopToTheSafeArea() {
        XCTAssertTrue(RNASeqResultSurface().pinsTopToSafeArea)
    }

    /// 5.6 Q1, BIO. The ruled caveats each state lays, by id.
    func testTheRuledCaveatIDsOfEachStateArePinned() async throws {
        let (surface, controller) = try await openController()
        defer { withExtendedLifetime(surface) {} }
        var found: [String: [String]] = [:]
        var words: [String: Int] = [:]
        // Each pinned id is either laid and visible inside the column, or it moved to an info button that shows beside its
        // control with the moved words as its popover's text (BIO).
        func record(_ state: String) {
            controller.view.layoutSubtreeIfNeeded()
            var ids = caveatIDs(in: controller.view)
            let shown = texts(in: controller.view)
            func field(_ id: String, in view: NSView) -> NSTextField? {
                if let found = view as? NSTextField, found.accessibilityIdentifier() == id { return found }
                return view.subviews.lazy.compactMap { field(id, in: $0) }.first
            }
            for id in ids { if let laid = field(id, in: controller.view) { assertInsideTheColumn(laid, "\(state) \(id)", in: controller) } }
            if let snapshot = controller.snapshot, let embedding = snapshot.facts.embeddings.first(where: { $0.embedding == snapshot.points.embedding }) {
                assertInsideTheColumn(controller.embeddingInfo, "\(state) About \(embedding.name)", in: controller)
                let other = ids.contains("rnaseq-cell-map-other-counts")
                XCTAssertEqual(controller.embeddingInfo.popoverController.text,
                               RNASeqEmbeddingWords.caption(method: embedding.method, embedding: embedding.name) + (other ? "\n\n" + RNASeqEmbeddingWords.otherCountsPlace : ""))
                XCTAssertNil(shown["rnaseq-cell-map-caption"])
                ids.append("rnaseq-cell-map-caption")
                // The P rows went to the Inspector (C17): each pinned one is gone from the view and kept in the fact lines.
                let facts = Dictionary(controller.factLines(snapshot).map { ("rnaseq-cell-map-fact-\($0.label.lowercased().replacingOccurrences(of: " ", with: "-"))", $0.value) },
                                       uniquingKeysWith: { first, _ in first })
                for id in Self.pinnedCaveatIDs[state, default: []] where Self.leftTheView.contains(id) {
                    XCTAssertNil(shown[id], "\(state) \(id) left the view")
                    XCTAssertNotNil(facts[id], "\(state) \(id) is in the Inspector's fact lines")
                    ids.append(id)
                }
                // On this map of one sample the left-out line joined Cells drawn (C6a).
                if Self.pinnedCaveatIDs[state, default: []].contains(Self.joinedCellsDrawn) {
                    XCTAssertNil(shown[Self.joinedCellsDrawn])
                    XCTAssertTrue(shown["rnaseq-cell-map-fact-cells-drawn"]?.contains("3 have no coordinates in \(embedding.name).") == true,
                                  "\(state) Cells drawn: \(shown["rnaseq-cell-map-fact-cells-drawn"] ?? "none")")
                    ids.append(Self.joinedCellsDrawn)
                }
            }
            if !controller.clustersInfo.isHidden {
                assertInsideTheColumn(controller.clustersInfo, "\(state) About clusters", in: controller)
                // W3 (C9, Sol's revised words cleared by BIO on recheck) and the grey of the 3 unlabelled cells (C7b).
                XCTAssertEqual(controller.clustersInfo.popoverController.text, RNASeqEmbeddingWords.clusterNumbers + "\n\n" + RNASeqEmbeddingWords.unlabelledGrey)
                ids.append("rnaseq-cell-map-cluster-numbers")
            }
            if controller.snapshot?.colours.legend.scale != nil {
                assertInsideTheColumn(controller.legendView.scaleInfo, "\(state) About the colour scale", in: controller)
                XCTAssertEqual(controller.legendView.scaleInfo.accessibilityLabel(), "About the colour scale")
            }
            assertInsideTheColumn(controller.selectingInfo, "\(state) About selecting", in: controller)
            found[state] = ids.sorted()
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
            print("TV-CELLMAP \(state) words \(words[state] ?? -1), base \(Self.pinnedWordCounts[state] ?? -1)")
            XCTAssertLessThanOrEqual(words[state] ?? .max, Self.pinnedWordCounts[state] ?? 0, "\(state) reads no more words than at the base")
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
