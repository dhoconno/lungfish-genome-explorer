// InspectorRNASeqResultTests.swift - The Inspector names an open RNA-seq result (5.6 lane TV-INSPECT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Bundle tab of a bulk, single-cell or cell map result shows the result's facts and never "No Bundle Loaded"
// (5.6 A3). A cell map's fact lines of 5.5 V5 show there from first open, whichever of the view's refresh and the
// surface's loaded hook comes first, follow the embedding, and clear when the map closes or a reread fails. Each test
// reads what an AX client reads from the hosted Document section, by identifier and in order. Each expected cell map
// value is built from the result's manifest and its cell map file and checked against both the Inspector row and the
// view's line (BIO 4), so the check keeps its meaning after TV-CELLMAP takes the lines out of the view.

import AppKit
import LungfishCore
import LungfishIO
import LungfishTestSupport
import SwiftUI
import XCTest
@testable import LungfishApp
@testable import LungfishRNASeqUI
@testable import LungfishWorkflow

@MainActor
final class InspectorRNASeqResultTests: XCTestCase {
    struct Row: Equatable, CustomStringConvertible {
        var id: String
        var label: String
        var value: String
        var description: String { "\(id) [\(label)] \(value)" }
    }

    private var root: URL!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "InspectorRNASeqResult")
    }

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// The committed smoke single-cell result, copied into the test's folder.
    private func singleCell() throws -> URL {
        let name = "Smoke single-cell.lungfishrnaseq"
        let url = root.appendingPathComponent(name, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            let committed = RNASeqFixtures.root.appendingPathComponent("cell-map-smoke/\(name)", isDirectory: true)
            try FileManager.default.copyItem(at: committed, to: url)
        }
        return url
    }

    /// A cell map of the smoke single-cell result with two imported embeddings, UMAP then t-SNE, and one imported
    /// label set, each from its own given file, written by the one writer with a record that lists its outputs as
    /// `lungfish-cli rnaseq cell-map import` lists them (`RNASeqCellMapImport.files`).
    private func cellMap() throws -> URL {
        let parent = try singleCell()
        let given = try TestTempDirectory.make(prefix: "InspectorRNASeqResult-given")
        defer { TestTempDirectory.cleanup(given) }
        var files: [RNASeqResultWriter.CellMapRequest.GivenFile] = []
        for (name, text) in [("umap.tsv", "barcode\tUMAP_1\tUMAP_2\n"), ("tsne.tsv", "barcode\ttSNE_1\ttSNE_2\n"),
                             ("clusters.tsv", "barcode\tclusters\n")] {
            let url = given.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            files.append(.init(url: url, sample: "", tool: "Seurat"))
        }
        let all = Array(Int32(1)...12)
        let drawn = all.filter { $0 != 4 }
        let labelled = all.filter { $0 != 4 && $0 != 9 }
        let request = RNASeqResultWriter.CellMapRequest(
            name: "Two embeddings", parent: parent, origin: .init(kind: .imported, tool: "Seurat", toolVersion: "5.5.1"),
            givenFiles: files,
            embeddings: [
                .init(name: "UMAP", method: "UMAP", source: .imported, sourceFile: "source/1/umap.tsv", otherCounts: false,
                      dimensions: 2, cells: drawn, values: drawn.flatMap { [Double($0) * 0.5, Double($0 % 5)] }),
                .init(name: "t-SNE", method: "t-SNE", source: .imported, sourceFile: "source/2/tsne.tsv", otherCounts: false,
                      dimensions: 2, cells: all, values: all.flatMap { [Double($0), -Double($0)] }),
            ],
            labelSets: [.init(name: "clusters", source: .imported, sourceFile: "source/3/clusters.tsv", cells: labelled,
                              labels: labelled.map { String($0 % 3 + 1) })],
            createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let map = root.appendingPathComponent("Two embeddings.lungfishrnaseq", isDirectory: true)
        let writer = RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))
        _ = try writer.writeCellMap(request, to: map, availableBytes: { _ in Int64.max }, observe: nil) { summary in
            var envelope = ProvenanceEnvelope(workflowName: "RNA-seq cell map import", toolName: "lungfish-cli", toolVersion: "test")
            envelope.files = summary.outputs.map {
                ProvenanceFileDescriptor(path: map.appendingPathComponent($0.path).path, checksumSHA256: $0.sha256, role: .output)
            }
            return envelope
        }
        return map
    }

    // MARK: - Expected rows

    private static let headerKeys = [("name", "Name"), ("modality", "Modality"), ("origin", "Origin"), ("route", "Route"),
                                     ("samples", "Samples")]
    private static let cellMapKeys = [("parent-result", "Parent result"), ("embedding", "Embedding"), ("source", "Source"),
                                      ("labels", "Labels"), ("cells-drawn", "Cells drawn")]

    /// The header's rows for the result at `url`, its values the facts the manifest writes (`RNASeqResultFacts`).
    private func expectedHeader(_ url: URL) throws -> [Row] {
        let facts = RNASeqResultFacts(result: try RNASeqResultBundle.load(from: url)).rows
        XCTAssertEqual(facts.map(\.label), Self.headerKeys.map(\.1), "the header's facts keep their order")
        return zip(Self.headerKeys, facts).map { key, fact in Row(id: "inspector-rnaseq-result-\(key.0)", label: key.1, value: fact.value) }
    }

    /// The five fact lines of 5.5 V5 for the embedding at `index`, coloured by the label set, each value built from what
    /// the manifest and the cell map file hold, with the ruled words of C4 and C10 whole.
    private func expectedCellMap(_ map: URL, embedding index: Int) throws -> [Row] {
        let result = try RNASeqResultBundle.load(from: map)
        let manifest = result.manifest
        let facts = try RNASeqCellMapLoader.snapshot(result: result, bundleURL: map).facts
        let embedding = facts.embeddings[index]
        let set = try XCTUnwrap(facts.labelSets.first)
        func source(_ file: String) throws -> String {
            let entry = try XCTUnwrap(manifest.sourceFiles.first { $0.path == file }, "the manifest lists \(file)")
            return "Imported from \(URL(fileURLWithPath: file).lastPathComponent) (sha256 \(entry.sha256.prefix(12))), not computed by LGE"
        }
        let parent = try XCTUnwrap(manifest.parent?.path)
        let values = [
            "\(URL(fileURLWithPath: parent).deletingPathExtension().lastPathComponent) (\(parent))",
            "\(embedding.name), method \(embedding.method ?? RNASeqResultBundle.notRecordedText)",
            try source(embedding.sourceFile),
            "\(set.name), i" + (try source(set.sourceFile)).dropFirst(),
            "\(embedding.cells) of \(facts.cellCount)",
        ]
        return zip(Self.cellMapKeys, values).map { key, value in Row(id: "inspector-rnaseq-cell-map-\(key.0)", label: key.1, value: value) }
    }

    // MARK: - Reading

    /// Hosts the Document section of `split`'s Inspector in a window, as the Bundle tab draws it.
    private func hostDocument(of split: MainSplitViewController) -> NSWindow {
        let window = AccessibilityTreeProbe.host(DocumentSection(viewModel: split.inspectorController.viewModel.documentSectionViewModel))
        windows.append(window)
        return window
    }

    /// The RNA-seq rows an AX client reads in `window`, in order.
    private func rows(in window: NSWindow) -> [Row] {
        AccessibilityTreeProbe.all(in: window).compactMap { element in
            guard let id = AccessibilityTreeProbe.identifier(element), id.hasPrefix("inspector-rnaseq-") else { return nil }
            return Row(id: id, label: AccessibilityTreeProbe.label(element) ?? "", value: AccessibilityTreeProbe.value(element) ?? "")
        }
    }

    private func saysNoBundleLoaded(_ window: NSWindow) -> Bool {
        !AccessibilityTreeProbe.elements(in: window, labelled: "No Bundle Loaded").isEmpty
            || AccessibilityTreeProbe.all(in: window).contains { AccessibilityTreeProbe.value($0) == "No Bundle Loaded" }
    }

    /// Waits until the hosted rows equal `expected`, and fails with what an AX client read when they never do.
    private func assertRows(_ window: NSWindow, _ expected: [Row], _ message: String, file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil(budget: .lookup) { self.rows(in: window) == expected }
        XCTAssertEqual(rows(in: window), expected, message, file: file, line: line)
        XCTAssertFalse(saysNoBundleLoaded(window), "\(message): the Bundle tab reads No Bundle Loaded", file: file, line: line)
    }

    private func split() -> MainSplitViewController {
        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        return split
    }

    private func resultController(_ split: MainSplitViewController) -> RNASeqResultViewController? {
        split.viewerController.children.lazy.compactMap { $0 as? RNASeqResultViewController }.first
    }

    private func settle(_ controller: RNASeqCellMapViewController) async {
        while let work = controller.work {
            await work.value
            if controller.work == work { return }
        }
    }

    /// Opens `url` through the registered-bundle route, as a click on its sidebar row does, and returns its cell map view
    /// once one has drawn, nil for a bulk or single-cell result.
    @discardableResult
    private func open(_ url: URL, in split: MainSplitViewController, cellMap: Bool) async throws -> RNASeqCellMapViewController? {
        split.displayContent(for: RoutingSafetyNetItems.scanned(url))
        await waitUntil(budget: .lookup) {
            guard let shown = self.resultController(split), shown.facts != nil else { return false }
            return !cellMap || shown.cellMap?.snapshot != nil
        }
        let shown = try XCTUnwrap(resultController(split), "\(url.lastPathComponent) shows no RNA-seq view")
        guard cellMap else { return nil }
        let controller = try XCTUnwrap(shown.cellMap, "\(url.lastPathComponent) shows no cell map view")
        await settle(controller)
        return controller
    }

    private func openMap(_ url: URL, in split: MainSplitViewController) async throws -> RNASeqCellMapViewController {
        let controller = try await open(url, in: split, cellMap: true)
        return try XCTUnwrap(controller)
    }
}

// MARK: - Item 1, the Bundle tab names the result

extension InspectorRNASeqResultTests {
    func testTheBundleTabShowsTheFactsOfABulkASingleCellAndACellMapResultAndNeverNoBundleLoaded() async throws {
        let (bulk, _) = try RoutingSafetyNetFixtures.rnaseqResultBundle(in: root.appendingPathComponent("Bulk", isDirectory: true))
        let single = try singleCell()
        let map = try cellMap()
        for (url, isMap) in [(bulk, false), (single, false), (map, true)] {
            let split = split()
            let window = hostDocument(of: split)
            try await open(url, in: split, cellMap: isMap)
            await assertRows(window, try expectedHeader(url) + (isMap ? try expectedCellMap(map, embedding: 0) : []), url.lastPathComponent)
            XCTAssertEqual(split.inspectorController.viewModel.selectedTab, .bundle)
            XCTAssertTrue(split.inspectorController.viewModel.documentSectionViewModel.hasAnyContent, "hasAnyContent counts the result")
        }
    }
}

// MARK: - Item 2, the cell map's fact lines

extension InspectorRNASeqResultTests {
    /// What the route does before it shows a registered kind (`MainSplitViewController+SidebarKindRoute.swift`).
    private func enterAsTheRouteDoes(_ url: URL, _ split: MainSplitViewController) {
        split.clearInspectorKeepingRowIdentity()
        split.inspectorController.updateProvenanceTarget(url: url, sidebarType: .registeredBundle, displayName: url.lastPathComponent)
    }

    /// The App's own load passes the cell map it read, so the view's first refresh comes before the loaded hook (SWIFT
    /// OBJECT 1). The rows still show, with no embedding change.
    func testACellMapPresentedWithItsOutcomeShowsItsRowsWithNoEmbeddingChange() async throws {
        let map = try cellMap()
        let split = split()
        let window = hostDocument(of: split)
        let surface = RNASeqResultSurface()
        split.viewerController.wireRNASeqResult(surface)
        enterAsTheRouteDoes(map, split)
        let outcome = RNASeqResultSurface.read(map)
        guard case .loaded(let result) = outcome else { return XCTFail("the cell map reads") }
        surface.present(outcome, bundleURL: map, cellMap: await RNASeqCellMapLoader.load(result: result, bundleURL: map))
        await assertRows(window, try expectedHeader(map) + expectedCellMap(map, embedding: 0), "refresh before the loaded hook")
        withExtendedLifetime(surface) {}
    }

    /// With no cell map passed the view reads its own after the loaded hook, the reverse order.
    func testACellMapPresentedWithNoOutcomeShowsItsRowsOnceItsOwnReadEnds() async throws {
        let map = try cellMap()
        let split = split()
        let window = hostDocument(of: split)
        let surface = RNASeqResultSurface()
        split.viewerController.wireRNASeqResult(surface)
        enterAsTheRouteDoes(map, split)
        surface.present(RNASeqResultSurface.read(map), bundleURL: map)
        await settle(try XCTUnwrap(surface.controller.cellMap))
        await assertRows(window, try expectedHeader(map) + expectedCellMap(map, embedding: 0), "the loaded hook before refresh")
        withExtendedLifetime(surface) {}
    }

    func testTheCellMapRowsFollowTheEmbedding() async throws {
        let map = try cellMap()
        let split = split()
        let window = hostDocument(of: split)
        let controller = try await openMap(map, in: split)
        await assertRows(window, try expectedHeader(map) + expectedCellMap(map, embedding: 0), "UMAP on show")
        controller.chooseEmbedding(try XCTUnwrap(controller.snapshot?.facts.embeddings[1].embedding))
        await settle(controller)
        await assertRows(window, try expectedHeader(map) + expectedCellMap(map, embedding: 1), "t-SNE on show")
    }

    /// BIO 4. Each cell map row equals the value built from the manifest and the file, and the view keeps beside it only
    /// Cells drawn and its imported-from line (C17, C4a).
    func testEachCellMapRowAndTheViewsLineEqualWhatTheManifestAndTheFileHold() async throws {
        let map = try cellMap()
        let split = split()
        let window = hostDocument(of: split)
        let controller = try await openMap(map, in: split)
        let expected = try expectedCellMap(map, embedding: 0)
        await assertRows(window, try expectedHeader(map) + expected, "cell map rows")
        var lines: [String: String] = [:]
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, !field.accessibilityIdentifier().isEmpty { lines[field.accessibilityIdentifier()] = field.stringValue }
            view.subviews.forEach(walk)
        }
        walk(controller.view)
        // TV-CELLMAP: the parent (C17), the embedding with its method recorded (C17), the source (C4) and the labels (C10) left
        // the view for the Inspector. Cells drawn stays, and on a map of one sample that leaves cells out it opens with the
        // Inspector's value and goes on with the left-out words (C6a).
        let leftTheView: Set<String> = ["parent-result", "embedding", "source", "labels"]
        for row in expected {
            let key = row.id.replacingOccurrences(of: "inspector-rnaseq-cell-map-", with: "")
            let id = "rnaseq-cell-map-fact-" + key
            if leftTheView.contains(key) {
                XCTAssertNil(lines[id], "the view no longer lays \(id)")
            } else {
                XCTAssertTrue(lines[id]?.hasPrefix(row.value) == true, "the view's \(id) line opens with \(row.value): \(lines[id] ?? "none")")
            }
        }
        // C4a: the view's line is the Inspector's Source value with its sha256 cut out, the one string cut once.
        let source = try XCTUnwrap(expected.first { $0.id == "inspector-rnaseq-cell-map-source" }).value
        XCTAssertEqual(lines["rnaseq-cell-map-imported"],
                       source.replacingOccurrences(of: #" \(sha256 [0-9a-f]+\)"#, with: "", options: .regularExpression))
    }

    /// QA 2. One assertion by id and string for each cell map row, its value counted from the fixture's own bytes.
    func testEachCellMapRowByIdAndString() async throws {
        let map = try cellMap()
        let split = split()
        let window = hostDocument(of: split)
        try await open(map, in: split, cellMap: true)
        await waitUntil(budget: .lookup) { self.rows(in: window).count == 10 }
        let shown = Dictionary(rows(in: window).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func sha(_ text: String) -> String { String(RNASeqResultBundle.sha256Hex(Data(text.utf8)).prefix(12)) }
        XCTAssertEqual(shown["inspector-rnaseq-cell-map-parent-result"]?.label, "Parent result")
        XCTAssertEqual(shown["inspector-rnaseq-cell-map-parent-result"]?.value, "Smoke single-cell (Smoke single-cell.lungfishrnaseq)")
        XCTAssertEqual(shown["inspector-rnaseq-cell-map-embedding"]?.label, "Embedding")
        XCTAssertEqual(shown["inspector-rnaseq-cell-map-embedding"]?.value, "UMAP, method UMAP")
        XCTAssertEqual(shown["inspector-rnaseq-cell-map-source"]?.label, "Source")
        XCTAssertEqual(shown["inspector-rnaseq-cell-map-source"]?.value,
                       "Imported from umap.tsv (sha256 \(sha("barcode\tUMAP_1\tUMAP_2\n"))), not computed by LGE")
        XCTAssertEqual(shown["inspector-rnaseq-cell-map-labels"]?.label, "Labels")
        XCTAssertEqual(shown["inspector-rnaseq-cell-map-labels"]?.value,
                       "clusters, imported from clusters.tsv (sha256 \(sha("barcode\tclusters\n"))), not computed by LGE")
        XCTAssertEqual(shown["inspector-rnaseq-cell-map-cells-drawn"]?.label, "Cells drawn")
        XCTAssertEqual(shown["inspector-rnaseq-cell-map-cells-drawn"]?.value, "11 of 12")
    }

    /// The writer lists each given file with its sha256 in the record, and the Provenance tab draws them (5.5 V5).
    func testTheProvenanceTabListsTheCellMapsSourceFilesWithTheirSHA256() async throws {
        let map = try cellMap()
        let split = split()
        try await open(map, in: split, cellMap: true)
        let provenance = split.inspectorController.viewModel.provenanceSectionViewModel
        await waitUntil(budget: .lookup) { !provenance.isLoading && !provenance.fileRows.isEmpty }
        let manifest = try RNASeqResultBundle.load(from: map).manifest
        XCTAssertEqual(manifest.sourceFiles.map(\.path), ["source/1/umap.tsv", "source/2/tsne.tsv", "source/3/clusters.tsv"])
        for file in manifest.sourceFiles {
            XCTAssertTrue(provenance.fileRows.contains { $0.path.hasSuffix("/" + file.path) && $0.checksumSHA256 == file.sha256 },
                          "the Provenance tab lists \(file.path) with its sha256: \(provenance.fileRows.map(\.path))")
        }
    }
}

// MARK: - Item 3, the clears

extension InspectorRNASeqResultTests {
    func testASwitchToATreeWithARereadPendingLeavesNoCellMapRows() async throws {
        let map = try cellMap()
        let tree = try RoutingSafetyNetFixtures.phylogeneticTreeBundle(in: root.appendingPathComponent("Trees", isDirectory: true))
        let split = split()
        let window = hostDocument(of: split)
        let document = split.inspectorController.viewModel.documentSectionViewModel
        let controller = try await openMap(map, in: split)
        await assertRows(window, try expectedHeader(map) + expectedCellMap(map, embedding: 0), "the cell map open")
        let embeddings = try XCTUnwrap(controller.snapshot?.facts.embeddings)
        controller.chooseEmbedding(embeddings[1].embedding)
        split.displayContent(for: RoutingSafetyNetItems.scanned(tree))
        await waitUntil(budget: .lookup) { document.phylogeneticTreeDocument != nil }
        await settle(controller)
        XCTAssertNotNil(document.phylogeneticTreeDocument, "the tree's block shows")
        // A choice on the view that has gone reaches the Inspector no more, so it cannot clear the tree's block.
        controller.chooseEmbedding(embeddings[0].embedding)
        await settle(controller)
        XCTAssertNotNil(document.phylogeneticTreeDocument, "a view left behind publishes nothing over the tree")
        await waitUntil(budget: .standard) { self.rows(in: window).isEmpty }
        XCTAssertEqual(rows(in: window), [])
    }

    func testASwitchFromATreeOrAGenotypeResultToAnRNASeqResultClearsTheirState() async throws {
        let map = try cellMap()
        let tree = try RoutingSafetyNetFixtures.phylogeneticTreeBundle(in: root.appendingPathComponent("Trees", isDirectory: true))
        // With calls, so the genotype viewer shows. Without them the workbook's Quick Look preview shows, and its
        // QLPreviewView asserts when a window-less test deactivates it.
        let genotype = try RoutingSafetyNetFixtures.genotypeResultBundle(in: root.appendingPathComponent("Genotypes", isDirectory: true), withCalls: true)
        let shows: [(URL, (DocumentSectionViewModel) -> Bool)] = [
            (tree, { $0.phylogeneticTreeDocument != nil }), (genotype, { $0.genotypeResultDocument != nil }),
        ]
        for (other, isShown) in shows {
            let split = split()
            let window = hostDocument(of: split)
            let document = split.inspectorController.viewModel.documentSectionViewModel
            split.displayContent(for: RoutingSafetyNetItems.scanned(other))
            await waitUntil(budget: .lookup) { isShown(document) }
            XCTAssertTrue(isShown(document), "\(other.lastPathComponent) shows its block first")
            try await open(map, in: split, cellMap: true)
            await assertRows(window, try expectedHeader(map) + expectedCellMap(map, embedding: 0), "after \(other.lastPathComponent)")
            XCTAssertNil(document.phylogeneticTreeDocument)
            XCTAssertNil(document.genotypeResultDocument)
        }
    }

    func testAProjectSwitchClearsTheRNASeqResult() async throws {
        let demo = root.appendingPathComponent("Demo.lungfish", isDirectory: true)
        let second = root.appendingPathComponent("Second.lungfish", isDirectory: true)
        _ = try DocumentManager.shared.createProject(at: demo, name: "Demo")
        _ = try DocumentManager.shared.createProject(at: second, name: "Second")
        let (bulk, _) = try RoutingSafetyNetFixtures.rnaseqResultBundle(in: demo.appendingPathComponent("RNASeq", isDirectory: true))
        let session = ProjectSession()
        try session.openProject(at: demo)
        let split = MainSplitViewController(projectSession: session)
        _ = split.view
        split.applyProjectSessionState()
        let window = hostDocument(of: split)
        try await open(bulk, in: split, cellMap: false)
        await assertRows(window, try expectedHeader(bulk), "the result open")
        try session.openProject(at: second)
        split.applyProjectSessionState()
        XCTAssertFalse(split.inspectorController.viewModel.documentSectionViewModel.hasAnyContent)
        await waitUntil(budget: .standard) { self.rows(in: window).isEmpty }
        XCTAssertEqual(rows(in: window), [], "no row of the old project's result stays")
    }

    func testAFailedRereadEmptiesTheCellMapRowsAndKeepsTheHeader() async throws {
        let map = try cellMap()
        let split = split()
        let window = hostDocument(of: split)
        let controller = try await openMap(map, in: split)
        let header = try expectedHeader(map)
        await assertRows(window, header + (try expectedCellMap(map, embedding: 0)), "the cell map open")
        // Each read after the first opens the cell map file again, so with the file gone the next one fails.
        try FileManager.default.moveItem(at: map.appendingPathComponent(RNASeqCellMap.filename), to: root.appendingPathComponent("aside.sqlite"))
        controller.chooseEmbedding(try XCTUnwrap(controller.snapshot?.facts.embeddings[1].embedding))
        await settle(controller)
        XCTAssertNotNil(controller.failureWords, "the view says the reread failed")
        await assertRows(window, header, "after a failed reread")
    }

    /// The App drops lines of a result that is not the Inspector's RNA-seq target, lines and empty lines alike, so a
    /// view left behind cannot change what replaced it.
    func testCellMapLinesOfAResultThatIsNotTheTargetAreDropped() async throws {
        let map = try cellMap()
        let other = try singleCell()
        let split = split()
        let window = hostDocument(of: split)
        let document = split.inspectorController.viewModel.documentSectionViewModel
        try await open(map, in: split, cellMap: true)
        let shown = try expectedHeader(map) + expectedCellMap(map, embedding: 0)
        await assertRows(window, shown, "the cell map open")
        split.inspectorController.updateRNASeqCellMapFacts([(label: "Cells drawn", value: "1 of 1")], bundleURL: other)
        split.inspectorController.updateRNASeqCellMapFacts([], bundleURL: other)
        XCTAssertEqual(document.rnaseqResultDocument?.bundleURL, map.standardizedFileURL)
        XCTAssertEqual(document.rnaseqResultDocument?.cellMap.map(\.value), try expectedCellMap(map, embedding: 0).map(\.value))
        await assertRows(window, shown, "after lines of another result")
    }

    /// A FASTQ dataset or a classifier result sets no document of its own, so the RNA-seq rows go with the RNA-seq view
    /// and never stand over the dataset or result that replaced it.
    func testAFASTQOrClassifierResultAfterACellMapLeavesNoRNASeqRow() async throws {
        let map = try cellMap()
        let (fastq, _) = try await RoutingSafetyNetFixtures.fastqBundle(in: root.appendingPathComponent("Reads", isDirectory: true))
        let czId = try RoutingSafetyNetFixtures.czIdResult(named: "cornea-czid.lungfishtax", in: root.appendingPathComponent("Imports", isDirectory: true))
        for other in [fastq, czId] {
            let name = other.lastPathComponent
            let split = split()
            let window = hostDocument(of: split)
            let inspector = split.inspectorController.viewModel
            let controller = try await openMap(map, in: split)
            await assertRows(window, try expectedHeader(map) + expectedCellMap(map, embedding: 0), "the cell map open before \(name)")
            split.displayContent(for: RoutingSafetyNetItems.scanned(other))
            await waitUntil(budget: .lookup) { self.resultController(split) == nil }
            XCTAssertNil(resultController(split), "\(name) replaces the RNA-seq view")
            await settle(controller)
            await waitUntil(budget: .standard) { inspector.documentSectionViewModel.rnaseqResultDocument == nil && self.rows(in: window).isEmpty }
            XCTAssertNil(inspector.documentSectionViewModel.rnaseqResultDocument, "\(name): the RNA-seq state goes with its view")
            XCTAssertEqual(rows(in: window), [], "\(name): no RNA-seq row stays")
        }
    }
}
