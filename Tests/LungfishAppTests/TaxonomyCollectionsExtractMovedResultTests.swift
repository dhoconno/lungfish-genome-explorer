// TaxonomyCollectionsExtractMovedResultTests.swift - Extract on a Kraken2 result that was renamed or copied
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane W4 (OBS-W4, a Stable blocker of the 2026-10-24 walk, row 69). A classification run stores the
// absolute folder it wrote into in `classification-result.json`. Extract built `--result` and `--output-dir`
// from that stored folder, so a result renamed in the app failed with "Classification result not found" and a
// result in a copied project extracted from, and wrote into, the original project. These tests copy a project
// or rename a result the way the walk did, press Extract on the drawer's own hook through the two routes that
// open a Kraken2 result, and read the command the Operations row records. The launch goes to a command that
// fails at once, so no extraction runs and the row's beginning is what they read.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

extension TwoSampleKraken2Batch {
    /// The batch as it sits in `projectURL`, a copy of the folder `init(in:)` built it in.
    init(copiedTo projectURL: URL) {
        self.projectURL = projectURL
        batchURL = projectURL.appendingPathComponent("Analyses/kraken2-batch", isDirectory: true)
        sampleADirectory = batchURL.appendingPathComponent(Self.sampleA, isDirectory: true)
        sampleBDirectory = batchURL.appendingPathComponent(Self.sampleB, isDirectory: true)
    }
}

@MainActor
final class TaxonomyCollectionsExtractMovedResultTests: XCTestCase {
    private var root: URL!
    private let harness = DrawerExtractHarness()
    /// The viewer owns the display and the extraction callback holds it weakly, so the test keeps it.
    private var viewer: ViewerViewController?

    override func setUp() async throws {
        harness.isolate(for: self)
        root = try TestTempDirectory.make(prefix: "taxonomy-collections-moved")
    }

    override func tearDown() async throws {
        viewer = nil
        if let root { TestTempDirectory.cleanup(root) }
    }

    /// The red test of OBS-W4 for the route the sidebar takes. A project is copied while the original stays, as
    /// the demo project of the walk is, and the copy is opened with sample A shown. Extract names the copy's
    /// folder for sample A in `--result` and `--output-dir`. At the base both named the original project, so the
    /// extraction read from and wrote into a project that is not the one on screen.
    func testExtractFromACopiedProjectNamesTheCopysFolders() async throws {
        let original = try TwoSampleKraken2Batch(in: root)
        try Self.storeAbsoluteOutputDirectory(in: original.sampleADirectory)
        try Self.storeAbsoluteOutputDirectory(in: original.sampleBDirectory)
        let copiedProject = root.appendingPathComponent("Copy.lungfish", isDirectory: true)
        try FileManager.default.copyItem(at: original.projectURL, to: copiedProject)
        let copy = TwoSampleKraken2Batch(copiedTo: copiedProject)
        let taxonomy = try harness.openFromSidebar(copy, showing: [TwoSampleKraken2Batch.sampleA])
        let collection = TaxaCollectionFixtures.collection
        let before = Set(OperationCenter.shared.items.map(\.id))

        try harness.pressExtract(collection, on: taxonomy)

        let command = try await recordedCommand(of: collection, excluding: before)
        let parsed = try RecordedCLICommand.parse(command, as: ExtractTaxaCollectionSubcommand.self)
        assertCommand(parsed, names: copy.sampleADirectory, collection: collection)
        XCTAssertFalse(command.contains(original.projectURL.path), "no argument names the original project: \(command)")
    }

    /// The red test of OBS-W4 for a result displayed alone. The folder of a result is renamed after its run, as
    /// row 69 of the walk did in the app, and the renamed folder is loaded and shown. Extract names the renamed
    /// folder. At the base it named the folder the run stored, which is gone, and the command failed with
    /// "Classification result not found".
    func testExtractFromARenamedResultNamesTheRenamedFolder() async throws {
        let batch = try TwoSampleKraken2Batch(in: root)
        try Self.storeAbsoluteOutputDirectory(in: batch.sampleADirectory)
        let renamed = batch.batchURL.appendingPathComponent("sample-A-renamed", isDirectory: true)
        try FileManager.default.moveItem(at: batch.sampleADirectory, to: renamed)
        let result = try ClassificationResult.load(from: renamed)
        let viewer = ViewerViewController()
        _ = viewer.view
        viewer.displayTaxonomyResult(result)
        self.viewer = viewer
        let taxonomy = try XCTUnwrap(viewer.taxonomyViewController)
        let collection = TaxaCollectionFixtures.collection
        let before = Set(OperationCenter.shared.items.map(\.id))

        try harness.pressExtract(collection, on: taxonomy)

        let command = try await recordedCommand(of: collection, excluding: before)
        let parsed = try RecordedCLICommand.parse(command, as: ExtractTaxaCollectionSubcommand.self)
        assertCommand(parsed, names: renamed, collection: collection)
    }

    // MARK: - Reading the row

    /// The command the row of `collection`'s Extract recorded, read once the row has begun and again after it ended.
    private func recordedCommand(of collection: TaxaCollection, excluding before: Set<UUID>) async throws -> String {
        let began = await DrawerExtractHarness.waitForNewRow(titled: "Extract \(collection.name)", excluding: before)
        let id = try XCTUnwrap(began, "Extract began no Operations row")
        let command = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == id }?.cliCommand)
        await DrawerExtractHarness.waitUntilEnded(id)
        return command
    }

    private func assertCommand(
        _ parsed: ExtractTaxaCollectionSubcommand, names folder: URL, collection: TaxaCollection,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            URL(fileURLWithPath: parsed.result).resolvingSymlinksInPath().path,
            folder.resolvingSymlinksInPath().path,
            "--result is the folder the result was opened from", file: file, line: line
        )
        XCTAssertEqual(
            URL(fileURLWithPath: parsed.outputDirectory).resolvingSymlinksInPath().path,
            folder.appendingPathComponent("extracted-\(collection.id)").resolvingSymlinksInPath().path,
            "--output-dir is inside that folder", file: file, line: line
        )
    }

    /// Stores the absolute folder in the sidecar of `folder` the way a classification run does. The fixture
    /// writes `.`, which follows the folder wherever it goes and so hides the defect.
    private static func storeAbsoluteOutputDirectory(in folder: URL) throws {
        let sidecar = folder.appendingPathComponent(ClassificationResult.sidecarFilename)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        var config = try XCTUnwrap(object["config"] as? [String: Any])
        config["outputDirectory"] = folder.absoluteString
        object["config"] = config
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: sidecar)
    }
}
