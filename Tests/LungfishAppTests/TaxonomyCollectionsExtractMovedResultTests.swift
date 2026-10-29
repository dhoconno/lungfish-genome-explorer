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

import AppKit
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
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
    }

    /// The result views save their column layouts to `UserDefaults.standard` under the result's path.
    private var hostDefaults: HostDefaultsRestorer?

    override func tearDown() async throws {
        viewer = nil
        hostDefaults?.restore()
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

    // MARK: - BLAST that cannot start (walk WF-3, the fix round of lane PROJECT-ROOT)

    /// ARCH should-fix 2 of the PROJECT-ROOT review. A result made in another project, opened in a project that
    /// no longer holds its reads, refuses BLAST Matching Reads in words that name them. Run in the BLAST popover
    /// first marks the search begun (`beginBlastVerification`) and then calls the closure the viewer wired, so a
    /// refusal has to end the run as every other BLAST failure does: no Operations row, no run left in flight,
    /// and the words in the BLAST tab as well as in the alert. At the lane head the alert showed the words and
    /// the run flag stayed set, so saved verifications of other taxa stopped coming back and the tab stayed bare.
    /// The drawer route (`displayTaxonomyFromDatabase`) has the same four lines and the same fix.
    func testBlastOnAResultWhoseReadsAreNotInTheProjectRefusesInWordsAndLeavesNoRunInFlight() throws {
        _ = NSApplication.shared // The refusal's alert reads NSApp.keyWindow.
        let batch = try TwoSampleKraken2Batch(in: root)
        let result = try Self.resultWhoseReadsAreNotInTheProject(batch.sampleADirectory)
        let viewer = ViewerViewController()
        _ = viewer.view
        viewer.displayTaxonomyResult(result)
        self.viewer = viewer
        let taxonomy = try XCTUnwrap(viewer.taxonomyViewController)
        let node = try XCTUnwrap(result.tree.node(taxId: 11))
        let before = Set(OperationCenter.shared.items.map(\.id))

        taxonomy.beginBlastVerification(for: node) // what Run in the popover does first
        taxonomy.onBlastVerification?(node, 10)

        assertBlastRefused(by: taxonomy, before: before, startingWith: "The reads this result came from")
        let words = blastTabText(of: taxonomy).first { $0.hasPrefix("The reads this result came from") }
        XCTAssertTrue(words?.contains("are not in this project") == true, "the words name what is missing: \(String(describing: words))")
        XCTAssertTrue(words?.hasSuffix("then choose BLAST Matching Reads….") == true, "the words end with the BLAST menu item: \(String(describing: words))")
    }

    /// ARCH Backlog B12 (S2). On the drawer route Run resolves the classification record of the sample shown. A
    /// sample whose folder holds none returned with a log line only, with the run flag the popover had set still
    /// set and no words. It ends the run now, and the BLAST tab says which record is missing and what to try.
    func testBlastOnASampleWithoutItsClassificationRecordSaysSoAndLeavesNoRunInFlight() throws {
        _ = NSApplication.shared // The refusal's alert reads NSApp.keyWindow.
        let batch = try TwoSampleKraken2Batch(in: root)
        try FileManager.default.removeItem(at: Self.sidecar(of: batch.sampleADirectory))
        let (taxonomy, node) = try openSampleA(of: batch)
        let before = Set(OperationCenter.shared.items.map(\.id))

        taxonomy.beginBlastVerification(for: node) // what Run in the popover does first
        taxonomy.onBlastVerification?(node, 10)

        let words = "BLAST Matching Reads could not start because LGE could not find this sample's classification record. "
            + "Run the classification again to rebuild it."
        assertBlastRefused(by: taxonomy, before: before, startingWith: "BLAST Matching Reads could not start because")
        XCTAssertTrue(blastTabText(of: taxonomy).contains(words), "the BLAST tab says what is missing: \(blastTabText(of: taxonomy))")
    }

    /// The same for a record that is there and cannot be read. The words carry the load's own reason, and the
    /// reason's full stop is not doubled before "Run the classification again".
    func testBlastOnASampleWhoseClassificationRecordCannotBeReadGivesTheReasonAndLeavesNoRunInFlight() throws {
        _ = NSApplication.shared // The refusal's alert reads NSApp.keyWindow.
        let batch = try TwoSampleKraken2Batch(in: root)
        try Data("not a classification record".utf8).write(to: Self.sidecar(of: batch.sampleADirectory))
        let (taxonomy, node) = try openSampleA(of: batch)
        let before = Set(OperationCenter.shared.items.map(\.id))

        taxonomy.beginBlastVerification(for: node) // what Run in the popover does first
        taxonomy.onBlastVerification?(node, 10)

        let start = "BLAST Matching Reads could not start because LGE could not read this sample's classification record: "
        let end = ". Run the classification again to rebuild it."
        assertBlastRefused(by: taxonomy, before: before, startingWith: start)
        let words = try XCTUnwrap(blastTabText(of: taxonomy).first { $0.hasPrefix(start) })
        XCTAssertTrue(words.hasSuffix(end), "the words end with what to try: \(words)")
        let reason = words.dropFirst(start.count).dropLast(end.count)
        XCTAssertFalse(reason.isEmpty, "the words give the reason the record could not be read: \(words)")
        XCTAssertFalse(words.contains(".."), "the reason's own full stop is not doubled: \(words)")
    }

    private static func sidecar(of folder: URL) -> URL {
        folder.appendingPathComponent(ClassificationResult.sidecarFilename)
    }

    /// The batch opened the way the sidebar does, with sample A shown and one of its species at hand.
    private func openSampleA(of batch: TwoSampleKraken2Batch) throws -> (TaxonomyViewController, TaxonNode) {
        let taxonomy = try harness.openFromSidebar(batch, showing: [TwoSampleKraken2Batch.sampleA])
        let node = try XCTUnwrap(taxonomy.testTableView.tree?.node(taxId: 11))
        XCTAssertEqual(taxonomy.owningSampleId(for: node), TwoSampleKraken2Batch.sampleA, "the species belongs to the sample shown")
        return (taxonomy, node)
    }

    /// What a BLAST that cannot start leaves behind. No Operations row began, the taxonomy view holds no run in
    /// flight, and the BLAST tab shows words that begin with `start`.
    private func assertBlastRefused(
        by taxonomy: TaxonomyViewController, before: Set<UUID>, startingWith start: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            Set(OperationCenter.shared.items.map(\.id)), before, "a refusal begins no Operations row", file: file, line: line
        )
        XCTAssertFalse(
            taxonomy.isBlastRunInFlight, "the refusal ends the run as every other BLAST failure does", file: file, line: line
        )
        XCTAssertFalse(
            taxonomy.blastRunIsActive, "no run stays active, so saved verifications of other taxa come back", file: file, line: line
        )
        let texts = blastTabText(of: taxonomy)
        XCTAssertTrue(texts.contains { $0.hasPrefix(start) }, "the BLAST tab shows the words, it shows \(texts)", file: file, line: line)
    }

    /// The text of every label in the BLAST tab. The tab keeps its failure text in a private label, so this reads
    /// what a person reads. A drawer that was never opened shows nothing.
    private func blastTabText(of taxonomy: TaxonomyViewController) -> [String] {
        func labels(under view: NSView) -> [String] {
            ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap { labels(under: $0) }
        }
        return taxonomy.testCollectionsDrawer.map { labels(under: $0.blastResultsTab) } ?? []
    }

    /// The result stored in `folder`, with the place its reads lack set as `ClassificationResult.load` sets it for a
    /// result opened in a project that does not hold the reads the run took.
    private static func resultWhoseReadsAreNotInTheProject(_ folder: URL) throws -> ClassificationResult {
        let stored = try ClassificationResult.load(from: folder)
        var config = stored.config
        config.sourceMissingFromProject = "Imports/SRR12486983.lungfishfastq"
        return ClassificationResult(
            config: config, tree: stored.tree, reportURL: stored.reportURL, outputURL: stored.outputURL,
            brackenURL: stored.brackenURL, profileOutcome: stored.profileOutcome, runtime: stored.runtime,
            toolVersion: stored.toolVersion, provenanceId: stored.provenanceId,
            fragmentComposition: stored.fragmentComposition, readPairingContract: stored.readPairingContract
        )
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
