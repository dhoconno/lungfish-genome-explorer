// RNASeqResultSurfaceTests.swift - The RNA-seq result surface shows what the manifest wrote and nothing else
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import XCTest
@testable import LungfishRNASeqUI
@testable import LungfishWorkflow

final class RNASeqResultSurfaceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rnaseq-surface-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// A two-sample bulk result made by the one writer, so the folder is what the CLI writes.
    private func writeResult() throws -> URL {
        let table = RNASeqCountTable(sampleIDs: ["S1", "S2"], rows: [
            RNASeqCountTable.Row(id: "G1", counts: [10, 20]),
            RNASeqCountTable.Row(id: "G2", counts: [0, 5]),
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
        let envelope = ProvenanceEnvelope(workflowName: "RNA-seq import", toolName: "lungfish-cli", toolVersion: "test")
        let writer = RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))
        return try writer.write(request, to: root.appendingPathComponent("two-sample.lungfishrnaseq", isDirectory: true), envelope: envelope)
    }

    @MainActor
    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allSubviews(of: $0) }
    }

    /// The text of every labelled field, by accessibility id.
    @MainActor
    private func texts(in view: NSView) -> [String: String] {
        var found: [String: String] = [:]
        for case let field as NSTextField in allSubviews(of: view) {
            let id = field.accessibilityIdentifier()
            if !id.isEmpty { found[id] = field.stringValue }
        }
        return found
    }

    /// Path, size, modification time and bytes of every item under the folder.
    private func snapshot(_ folder: URL) throws -> [String: String] {
        var items: [String: String] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys))
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            let relative = String(url.path.dropFirst(folder.path.count))
            if values.isDirectory == true {
                items[relative] = "directory"
            } else {
                let digest = try RNASeqResultBundle.sha256Hex(fileAt: url)
                items[relative] = "\(digest) \(values.fileSize ?? -1) \(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            }
        }
        return items
    }

    @MainActor
    func testTheHeaderShowsTheFactsTheManifestWrote() throws {
        let url = try writeResult()
        let surface = RNASeqResultSurface()
        surface.present(RNASeqResultSurface.read(url), bundleURL: url)
        let view = surface.viewController.view
        let text = texts(in: view)
        XCTAssertEqual(text["rnaseq-result-name"], "Two sample test")
        XCTAssertEqual(text["rnaseq-result-modality"], "bulk")
        XCTAssertEqual(text["rnaseq-result-origin"], "imported, salmon 1.10.0")
        XCTAssertEqual(text["rnaseq-result-route"], "salmon-selective-alignment, salmon 1.10.0")
        XCTAssertEqual(text["rnaseq-result-samples"], "2")
        XCTAssertEqual(view.accessibilityIdentifier(), "rnaseq-result-view")
        XCTAssertEqual(surface.surfaceKind, .bundle(.rnaseqResult))
        XCTAssertNil(surface.controller.failureWords)
    }

    @MainActor
    func testTheLoadedHookGetsTheFactsAndTheFolder() throws {
        let url = try writeResult()
        let surface = RNASeqResultSurface()
        var seen: [(RNASeqResultFacts, URL)] = []
        surface.onLoaded = { facts, folder in seen.append((facts, folder)) }
        surface.present(RNASeqResultSurface.read(url), bundleURL: url)
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.0.name, "Two sample test")
        XCTAssertEqual(seen.first?.0.sampleCount, 2)
        XCTAssertEqual(seen.first?.1, url)
    }

    @MainActor
    func testABulkResultHostsTheBulkViewAndASingleCellResultTheSingleCellView() throws {
        let url = try writeResult()
        let surface = RNASeqResultSurface()
        surface.present(RNASeqResultSurface.read(url), bundleURL: url)
        XCTAssertNotNil(surface.controller.bulk)
        XCTAssertNil(surface.controller.singleCell)
        XCTAssertEqual(surface.controller.bulk?.view.accessibilityIdentifier(), "rnaseq-bulk-view")
        XCTAssertEqual(surface.controller.bulk?.bundleURL, url)

        guard case .loaded(var result) = RNASeqResultSurface.read(url) else { return XCTFail("the fixture did not load") }
        result.manifest.modality = .singleCell
        let other = RNASeqResultSurface()
        other.controller.show(.loaded(result), bundleURL: url)
        XCTAssertNil(other.controller.bulk)
        XCTAssertEqual(other.controller.singleCell?.view.accessibilityIdentifier(), "rnaseq-single-cell-view")
        XCTAssertEqual(other.controller.children.count, 1)
    }

    @MainActor
    func testANewerSchemaShowsItsWordsAndThrowsNothing() throws {
        let url = try writeResult()
        let manifestURL = url.appendingPathComponent(RNASeqResultManifest.filename)
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        // Schema 2 is the cell map's (5.5 L2), so the first newer schema is 3.
        manifest["schemaVersion"] = 3
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let words = "This RNA-seq result was written by a newer LGE (schema 3). Open it with that version or a later one."
        XCTAssertEqual(RNASeqResultSurface.read(url), .failed(words))
        let surface = RNASeqResultSurface()
        var loaded = false
        surface.onLoaded = { _, _ in loaded = true }
        surface.present(RNASeqResultSurface.read(url), bundleURL: url)
        XCTAssertEqual(texts(in: surface.viewController.view)["rnaseq-result-failure"], words)
        XCTAssertEqual(surface.controller.failureWords, words)
        XCTAssertNil(surface.controller.facts)
        XCTAssertFalse(loaded, "a result that did not load tells the App nothing")
        XCTAssertNil(surface.controller.bulk)
    }

    @MainActor
    func testAMissingOrUnreadableManifestShowsItsWords() throws {
        let words = "The RNA-seq result has no readable manifest."
        let missing = try writeResult()
        try FileManager.default.removeItem(at: missing.appendingPathComponent(RNASeqResultManifest.filename))
        XCTAssertEqual(RNASeqResultSurface.read(missing), .failed(words))

        let broken = root.appendingPathComponent("broken.lungfishrnaseq", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: broken.appendingPathComponent(RNASeqResultManifest.filename))
        let surface = RNASeqResultSurface()
        surface.present(RNASeqResultSurface.read(broken), bundleURL: broken)
        XCTAssertEqual(texts(in: surface.viewController.view)["rnaseq-result-failure"], words)
    }

    @MainActor
    func testShowingAResultWritesNothingAndOffersNothingToEdit() throws {
        let url = try writeResult()
        let before = try snapshot(url)
        XCTAssertFalse(before.isEmpty)
        let surface = RNASeqResultSurface()
        surface.present(RNASeqResultSurface.read(url), bundleURL: url)
        let views = allSubviews(of: surface.viewController.view)
        XCTAssertFalse(views.isEmpty)
        XCTAssertEqual(try snapshot(url), before, "opening a result changes no file and adds none")
        XCTAssertFalse(views.contains { $0 is NSButton }, "the leaf offers no button")
        XCTAssertTrue(views.compactMap { $0 as? NSTextField }.allSatisfy { !$0.isEditable || $0 is NSSearchField },
                      "no field is editable but the bulk view's gene search, which edits no file")
        XCTAssertFalse(views.contains { ($0 as? NSTextView)?.isEditable == true })
    }

    /// A host with the surface registered, as the viewer makes it, and the hook that tells the App.
    @MainActor
    private func makeHost(onLoaded: @escaping @MainActor (RNASeqResultFacts, URL) -> Void) -> (ViewportHost, NSViewController) {
        let parent = NSViewController()
        parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let registry = SurfaceRegistry()
        registry.register(.bundle(.rnaseqResult), factory: RNASeqResultSurface.factory { $0.onLoaded = onLoaded })
        return (ViewportHost(registry: registry, containerView: parent.view, parentController: parent), parent)
    }

    @MainActor
    func testAShowThroughTheHostInstallsTheResultAndTellsTheAppOnce() async throws {
        let url = try writeResult()
        var told = 0
        let (host, parent) = makeHost { _, _ in told += 1 }
        let outcome = await host.show(kind: .bundle(.rnaseqResult), input: url).value
        guard case .committed = outcome else { return XCTFail("the show ended \(outcome)") }
        XCTAssertEqual(told, 1)
        XCTAssertEqual(parent.children.count, 1)
    }

    /// The guard after the detached read (`Task.checkCancellation()` in `RNASeqResultSurface.load`) keeps a late
    /// load from telling the App about a result the person has already left.
    @MainActor
    func testALoadThatAClearCancelledPresentsNothingAndTellsTheAppNothing() async throws {
        let url = try writeResult()
        var told = 0
        let (host, parent) = makeHost { _, _ in told += 1 }
        let task = host.show(kind: .bundle(.rnaseqResult), input: url)
        host.clear()
        let outcome = await task.value
        guard case .refused = outcome else { return XCTFail("the show ended \(outcome)") }
        XCTAssertEqual(told, 0, "a load that a clear cancelled tells the App nothing")
        XCTAssertTrue(parent.children.isEmpty)
    }

    @MainActor
    func testAnInputThatIsNoURLIsRefusedAndInstallsNothing() async {
        let (host, parent) = makeHost { _, _ in }
        _ = await host.show(kind: .bundle(.rnaseqResult), input: "not a url").value
        guard case .failed = host.lastOutcome else { return XCTFail("a wrong input must fail") }
        XCTAssertTrue(parent.children.isEmpty)
    }
}
