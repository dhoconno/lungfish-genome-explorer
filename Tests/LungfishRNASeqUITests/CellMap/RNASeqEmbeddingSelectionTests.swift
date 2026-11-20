// RNASeqEmbeddingSelectionTests.swift - Selecting cells in the embedding view (Phase 5.5 lane CM-SELECT-APP)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Selecting writes nothing, and a hash of every file before and after holds it (5.5 S1). The view's cells for a polygon with
// a point on an edge equal the cells `cell-map select` writes, since both run LungfishIO's one function (5.5 S2). A legend
// click, Command-click, Space, Escape and Command-A select as UX U-A2 says, the count is announced, and each legend child's
// VoiceOver action selects its label (5.5 V2). The lasso keeps at most the format page's vertex count by one fixed rule.
// The bench at 1,000,000 points is opt-in with LUNGFISH_PERF_BENCH=1.

import AppKit
import CryptoKit
@testable import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow
import XCTest
@testable import LungfishRNASeqUI

@MainActor
final class RNASeqEmbeddingSelectionTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "cm-select-app") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    func open() async throws -> (RNASeqResultSurface, RNASeqCellMapViewController, URL) {
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
        return (surface, controller, map)
    }

    func settle(_ controller: RNASeqCellMapViewController) async {
        await controller.selectionWork?.value
        while let work = controller.work {
            await work.value
            if controller.work == work { return }
        }
    }

    /// The sha256 and size of every file under `folder`, by path.
    func hashes(of folder: URL) throws -> [String: String] {
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
        var found: [String: String] = [:]
        for case let url as URL in walker where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let data = try Data(contentsOf: url)
            found[url.path] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + " \(data.count)"
        }
        return found
    }

    /// The cells the controller selected, as sample name and barcode, the table's first two columns.
    func viewCells(_ controller: RNASeqCellMapViewController) throws -> Set<String> {
        let shown = try XCTUnwrap(controller.snapshot)
        let mask = try XCTUnwrap(controller.selection?.mask)
        let keys = try shown.database.cellKeys()
        return Set(keys.barcode.indices.filter { mask[$0] }.map { "\(shown.facts.sampleName(Int(keys.sample[$0])))\t\(keys.barcode[$0])" })
    }

    func testSelectingWritesNothing() async throws {
        let (surface, controller, map) = try await open()
        defer { withExtendedLifetime(surface) {} }
        let before = try hashes(of: map.deletingLastPathComponent())
        XCTAssertFalse(before.isEmpty)
        controller.selectLegendRow(0, adding: false)
        await settle(controller)
        controller.selectLegendRow(1, adding: true)
        await settle(controller)
        controller.toggleLegendRow(0)
        await settle(controller)
        controller.selectPolygon([.init(x: -1000, y: -1000), .init(x: 0, y: -1000), .init(x: 0, y: 1000)], mode: .add)
        await settle(controller)
        controller.selectAll(nil)
        await settle(controller)
        XCTAssertTrue(controller.plot.showsSelection, "the selected cells draw on top")
        controller.cancelOperation(nil)
        await settle(controller)
        XCTAssertEqual(try hashes(of: map.deletingLastPathComponent()), before, "selecting changed a file")
    }

    func testTheViewsCellsEqualTheCLIsForAPolygonWithAPointOnAnEdgeAndAVertex() async throws {
        let (surface, controller, map) = try await open()
        defer { withExtendedLifetime(surface) {} }
        let points = try XCTUnwrap(controller.snapshot?.points)
        let cell = try XCTUnwrap(points.x.indices.first { points.isDrawn($0) })
        let px = points.x[cell], py = points.y[cell]
        // The cell lies on the left edge, and a second cell lies on the first vertex.
        let other = try XCTUnwrap(points.x.indices.first { $0 != cell && points.isDrawn($0) })
        let polygons: [[RNASeqCellMapSelection.Vertex]] = [
            [.init(x: px, y: py - 50), .init(x: px + 50, y: py - 50), .init(x: px + 50, y: py + 50), .init(x: px, y: py + 50)],
            [.init(x: points.x[other], y: points.y[other]), .init(x: points.x[other] + 40, y: points.y[other] + 3),
             .init(x: points.x[other] - 7, y: points.y[other] + 60)],
        ]
        for vertices in polygons {
            controller.selectPolygon(vertices)
            await settle(controller)
            XCTAssertEqual(controller.selectionRequest()?.form, .polygon(vertices), "the polygon handed on is the one drawn")
            let cli = try RNASeqCellMapSelect.select(cellMap: map, embedding: "UMAP", form: .polygon(vertices))
            let text = try XCTUnwrap(String(data: cli.table, encoding: .utf8))
            let selected = Set(text.split(separator: "\n").dropFirst().compactMap { line -> String? in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                return fields.last == "selected" ? fields.dropLast().joined(separator: "\t") : nil
            })
            XCTAssertFalse(selected.isEmpty)
            XCTAssertEqual(try viewCells(controller), selected, "the view's cells and the CLI's")
            XCTAssertEqual(controller.selection?.count, cli.samples.reduce(0) { $0 + $1.selected })
            if vertices == polygons[0] {
                // On the left edge `px < px` is false, so only the right edge crosses and the cell is inside.
                XCTAssertTrue(RNASeqCellMapSelection.contains(x: px, y: py, polygon: vertices))
                XCTAssertEqual(controller.selection?.mask[cell], true, "the cell on the edge is selected in the view as in the CLI")
            }
        }
    }

    func testALegendClickCommandClickSpaceEscapeAndCommandASelectAndAnnounceTheCount() async throws {
        let (surface, controller, _) = try await open()
        defer { withExtendedLifetime(surface) {} }
        let shown = try XCTUnwrap(controller.snapshot)
        guard case .labelSet(let id) = shown.colouring, case .labels(let labels) = shown.values,
              let set = shown.facts.labelSets.first(where: { $0.labelSet == id }) else { return XCTFail("the view opens on a label set") }
        func drawn(_ rows: [Int]) -> Int {
            let wanted = Set(rows.map { UInt32(set.labels[$0].label) })
            return labels.indices.filter { wanted.contains(labels[$0]) && shown.points.isDrawn($0) }.count
        }
        controller.selectLegendRow(0, adding: false)
        await settle(controller)
        XCTAssertEqual(controller.selection?.count, drawn([0]))
        XCTAssertEqual(controller.selectionRequest()?.form, .labels(set: set.name, labels: [set.labels[0].name]))
        XCTAssertEqual(controller.selectionField.stringValue, RNASeqEmbeddingSelectionWords.count(drawn([0])))
        XCTAssertEqual(controller.selectionAnnouncement, RNASeqEmbeddingSelectionWords.count(drawn([0])), "VoiceOver hears the count")
        XCTAssertEqual(controller.legendView.markedRows, [0])
        XCTAssertTrue(controller.saveSelectionButton.isEnabled)

        controller.selectLegendRow(1, adding: true)
        await settle(controller)
        XCTAssertEqual(controller.selection?.count, drawn([0, 1]))
        XCTAssertEqual(controller.selectionRequest()?.form, .labels(set: set.name, labels: [set.labels[0].name, set.labels[1].name]))

        controller.legendView.onRowToggle?(0)
        await settle(controller)
        XCTAssertEqual(controller.selection?.count, drawn([1]), "Space takes the focused row away")

        controller.cancelOperation(nil)
        await settle(controller)
        XCTAssertNil(controller.selection)
        XCTAssertEqual(controller.selectionField.stringValue, RNASeqEmbeddingSelectionWords.none)
        XCTAssertFalse(controller.saveSelectionButton.isEnabled)

        controller.selectAll(nil)
        await settle(controller)
        XCTAssertEqual(controller.selection?.count, shown.points.x.indices.filter { shown.points.isDrawn($0) }.count, "Command-A selects every drawn cell")
        guard case .polygon? = controller.selectionRequest()?.form else { return XCTFail("Command-A is named as a polygon") }

        let children = try XCTUnwrap(controller.plot.accessibilityChildren() as? [NSAccessibilityElement])
        let action = try XCTUnwrap(children[2].accessibilityCustomActions()?.first)
        XCTAssertEqual(action.name, RNASeqEmbeddingSelectionWords.selectAction)
        XCTAssertEqual(action.handler?(), true)
        await settle(controller)
        XCTAssertEqual(controller.selection?.rows, [2], "the legend child's action selects its label")
        XCTAssertEqual(controller.selection?.count, drawn([2]))
    }

    func testAShiftLassoAddsAndNoSingleCommandNamesIt() async throws {
        let (surface, controller, _) = try await open()
        defer { withExtendedLifetime(surface) {} }
        controller.selectLegendRow(0, adding: false)
        await settle(controller)
        let first = try XCTUnwrap(controller.selection?.count)
        controller.selectPolygon([.init(x: -1000, y: -1000), .init(x: 1000, y: -1000), .init(x: 1000, y: 1000)], mode: .add)
        await settle(controller)
        XCTAssertGreaterThan(try XCTUnwrap(controller.selection?.count), first)
        XCTAssertNil(controller.selectionRequest(), "a joined selection has no one command")
        XCTAssertEqual(controller.selectionNote.stringValue, RNASeqEmbeddingSelectionWords.noOneCommand)
        XCTAssertFalse(controller.pseudobulkSelectionButton.isEnabled)
    }

    /// Escape and Space as key events, which the tests above reach only through `cancelOperation` and `onRowToggle`
    /// (CM-SELECT-APP-SWIFT B3).
    func testEscapeAndSpaceAsKeyEventsReachThePlotAndTheLegend() async throws {
        let (surface, controller, _) = try await open()
        defer { withExtendedLifetime(surface) {} }
        func key(_ code: UInt16, _ characters: String) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        controller.selectLegendRow(0, adding: false)
        await settle(controller)
        let rowZero = try XCTUnwrap(controller.selection?.count)

        controller.plot.keyDown(with: try key(53, "\u{1B}"))
        await settle(controller)
        XCTAssertNil(controller.selection, "Escape with the plot focused clears the selection")

        controller.selectLegendRow(0, adding: false)
        await settle(controller)
        XCTAssertEqual(controller.selection?.count, rowZero)
        controller.legendView.keyDown(with: try key(53, "\u{1B}"))
        await settle(controller)
        XCTAssertNil(controller.selection, "Escape with the legend focused clears the selection")

        controller.legendView.keyDown(with: try key(49, " "))
        await settle(controller)
        XCTAssertEqual(controller.selection?.rows, [0], "Space selects the focused row, which is row 0 until the arrows move it")
        XCTAssertEqual(controller.selection?.count, rowZero)
    }

    /// The numbers the view works out for itself (CM-SELECT-APP-SWIFT SF1). They pin the code as it is.
    func testSampleCountsFollowSampleOrderAndOnlySamplesUnderTenGetALine() {
        // 30 cells in sample order: "a" holds cells 0..<12 and "b" holds cells 12..<30.
        let mask = (0..<30).map { $0 < 3 || (12..<22).contains($0) }
        let samples = [RNASeqCellMapDatabase.Sample(sample: 0, name: "a", cells: 12),
                       RNASeqCellMapDatabase.Sample(sample: 1, name: "b", cells: 18)]
        let counts = RNASeqEmbeddingSelection.sampleCounts(mask, samples: samples)
        XCTAssertEqual(counts, [RNASeqEmbeddingSelectionSample(sample: "a", selected: 3),
                                RNASeqEmbeddingSelectionSample(sample: "b", selected: 10)])
        func selection(_ samples: [RNASeqEmbeddingSelectionSample]) -> RNASeqEmbeddingSelection {
            RNASeqEmbeddingSelection(
                embedding: 0, mask: mask, count: samples.reduce(0) { $0 + $1.selected }, samples: samples, form: nil,
                rows: [], rowsColouring: nil, polygon: nil)
        }
        let words = selection(counts).underTenWords
        XCTAssertEqual(words.count, 1, "b holds 10 selected cells, which is not under 10")
        XCTAssertTrue(words.first?.hasPrefix("a holds 3 selected cells") == true, "\(words)")
        let one = selection([RNASeqEmbeddingSelectionSample(sample: "a", selected: 1)]).underTenWords
        XCTAssertEqual(one.count, 1)
        XCTAssertTrue(one.first?.hasPrefix("a holds 1 selected cell,") == true, "a single cell is singular: \(one)")
        XCTAssertEqual(selection([RNASeqEmbeddingSelectionSample(sample: "a", selected: 0)]).underTenWords, [],
                       "a sample with none selected gets no line")
    }

    func testALassoDrawnRoundAPixelSelectsTheCellThePlotReadsThere() async throws {
        let (surface, controller, _) = try await open()
        defer { withExtendedLifetime(surface) {} }
        let plot = controller.plot
        let raster = try XCTUnwrap(plot.raster)
        // The first pixel that reads a cell, then the middle of that cell's pixels in the rows and columns round it.
        var first: (column: Int, row: Int, cell: Int)?
        search: for row in 0..<raster.height {
            for column in 0..<raster.width {
                if let cell = plot.cell(at: plot.viewPoint(column: column, row: row)) {
                    first = (column, row, cell)
                    break search
                }
            }
        }
        let start = try XCTUnwrap(first, "the plot draws a cell")
        var hits: [(column: Int, row: Int)] = []
        for row in start.row..<min(start.row + 16, raster.height) {
            for column in max(start.column - 16, 0)..<min(start.column + 16, raster.width)
            where plot.cell(at: plot.viewPoint(column: column, row: row)) == start.cell {
                hits.append((column, row))
            }
        }
        let column = hits.map { $0.column }.reduce(0, +) / hits.count
        let row = hits.map { $0.row }.reduce(0, +) / hits.count
        let centre = plot.viewPoint(column: column, row: row)
        let corners = [CGPoint(x: centre.x - 3, y: centre.y - 3), CGPoint(x: centre.x + 3, y: centre.y - 3),
                       CGPoint(x: centre.x + 3, y: centre.y + 3), CGPoint(x: centre.x - 3, y: centre.y + 3)]
        controller.lasso(corners, modifiers: [])
        await settle(controller)
        let selection = try XCTUnwrap(controller.selection, "the lasso selected a cell")
        XCTAssertTrue(selection.mask[start.cell], "the cell the plot reads at that pixel lies inside a lasso drawn round the pixel")
        XCTAssertLessThan(selection.count, selection.mask.count, "a lasso 6 view points wide does not hold every cell")
    }

    func testTheLassoKeepsAtMostTheFormatPagesVertexCountByOneRule() {
        let drag = (0..<5_000).map { step -> CGPoint in
            let angle = Double(step) / 5_000 * 2 * .pi
            return CGPoint(x: 400 + 300 * cos(angle), y: 300 + 200 * sin(angle))
        }
        let once = RNASeqEmbeddingLasso.simplify(drag)
        XCTAssertLessThanOrEqual(once.count, RNASeqCellMapSelection.maximumVertices)
        XCTAssertGreaterThanOrEqual(once.count, RNASeqCellMapSelection.maximumVertices / 2)
        XCTAssertEqual(once, RNASeqEmbeddingLasso.simplify(drag), "the same drag gives the same polygon")
        XCTAssertEqual(once.first, drag.first)
        XCTAssertEqual(RNASeqEmbeddingLasso.simplify([.zero, CGPoint(x: 1, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 5, y: 5)]).count, 3,
                       "a point under 2 points from the last kept is dropped")
    }

    /// 1,000,000 cells against a lasso of 1,000 vertices off the main actor. The 50 ms bar holds only in an optimized build,
    /// so a Debug run prints its figure and asserts nothing.
    func testLassoMembershipAtOneMillionPointsOffTheMainActor() async throws {
        guard ProcessInfo.processInfo.environment["LUNGFISH_PERF_BENCH"] == "1" else { throw XCTSkip("set LUNGFISH_PERF_BENCH=1") }
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Float32 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float32(state >> 40) / Float32(1 << 24) * 200 - 100
        }
        var x = ContiguousArray<Float32>(), y = ContiguousArray<Float32>()
        for _ in 0..<1_000_000 { x.append(next()); y.append(next()) }
        let points = RNASeqCellMapPoints(embedding: 1, x: x, y: y)
        let lasso = (0..<1_000).map { step -> RNASeqCellMapSelection.Vertex in
            let angle = Float32(step) / 1_000 * 2 * .pi
            let radius: Float32 = step % 2 == 0 ? 80 : 55
            return .init(x: radius * cos(angle), y: radius * sin(angle))
        }
        let samples: [RNASeqCellMapDatabase.Sample] = []
        var times: [Double] = []
        for _ in 0..<5 {
            let seconds = await Task.detached { () -> Double in
                let start = DispatchTime.now().uptimeNanoseconds
                let made = RNASeqEmbeddingSelection.make(points: points, rule: .polygon(lasso), base: nil, mode: .replace, samples: samples)
                precondition(made.count > 0)
                return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            }.value
            times.append(seconds)
        }
        let median = times.sorted()[times.count / 2]
        print("lasso membership at 1,000,000 points: median \(median * 1_000) ms of \(times.map { $0 * 1_000 })")
        #if !DEBUG
        XCTAssertLessThan(median, 0.050)
        #endif
    }
}
