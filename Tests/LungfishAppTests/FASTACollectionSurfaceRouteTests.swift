// FASTACollectionSurfaceRouteTests.swift - The FASTA collection on the surface host, its way back and every way out (Phase 3.2 lane FASTA)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A collection is the one kind a person leaves on purpose and comes back to, so these tests read what a slip would cost:
// the place in the list, the numbers, and a search left running. Each search here is a test's own runner in place of
// `blast submit`, so nothing reaches NCBI.

import AppKit
import LungfishCore
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow

/// What a file that does not read says. A real read throws this kind of error, not a `SurfaceError`.
private struct DamagedFASTAFile: LocalizedError {
    var errorDescription: String? { "genome.fasta ends in the middle of a record" }
}

/// A surface whose load fails on the file, so the collection's show never installs.
@MainActor
private final class RefusingCollectionSurface: ResultViewport {
    let controller = NSViewController()
    var viewController: NSViewController { controller }
    var surfaceKind: SurfaceKind { .view(.fastaCollection) }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        throw DamagedFASTAFile()
    }
}

/// A search that waits for the test at each step, and that a cancel ends at once.
private final class HeldSearch: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func wait() async throws {
        for await _ in stream { break }
        try Task.checkCancellation()
    }

    func release() {
        continuation.yield()
    }
}

@MainActor
final class FASTACollectionSurfaceRouteTests: XCTestCase {
    private var root: URL!
    private var hostDefaults: HostDefaultsRestorer!

    private let chromeVisible = AlignmentChrome(ruler: false, viewer: false, header: false, status: false)
    private let chromeCovered = AlignmentChrome(ruler: true, viewer: true, header: true, status: true)

    override func setUpWithError() throws {
        isolateAlignmentPaneDefaults()
    }

    override func setUp() async throws {
        try await super.setUp()
        OperationCenter.useTemporaryFailureReportsForTesting()
        root = try TestTempDirectory.make(prefix: "FASTACollectionRoute")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
        BlastConsentSheet.presenterForTesting = { _, send in send() }
    }

    override func tearDown() async throws {
        BlastConsentSheet.presenterForTesting = nil
        hostDefaults.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - Opening

    func testACollectionOpensThroughTheHostInAFreshWindow() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!

        harness.select(try makeCollectionRow().item)

        let collection = try await shownCollection(in: viewer)
        XCTAssertEqual(viewer.installedSurface?.surfaceKind, .view(.fastaCollection), "the collection is not on the surface host")
        XCTAssertEqual(AlignmentChrome(viewer), chromeCovered, "the genomics chrome shows under the collection")
        XCTAssertEqual(viewer.contentMode, .genomics)
        XCTAssertEqual(names(in: collection), ["seq_long", "seq_mid", "seq_short"])
    }

    /// The numbers a person reads, taken from the base and the same after the move: one row a record, and each record's length.
    func testTheCountAndEachLengthOfTheFixtureDoNotChange() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }

        harness.select(try makeCollectionRow().item)

        let collection = try await shownCollection(in: harness.split.viewerController)
        XCTAssertEqual(collection.testTableView.numberOfRows, 3)
        XCTAssertEqual(cells("length", in: collection), ["40 bp", "20 bp", "8 bp"])
        // GC is counted off the main thread since FASTALIST2 (W-34), so its cells read blank until the pass delivers.
        _ = await waitUntil(budget: .lookup) { !cells("gc", in: collection).contains("") }
        XCTAssertEqual(cells("gc", in: collection), ["50.0%", "40.0%", "100.0%"])
    }

    func testFASTACollectionContentStartsBelowTheToolbar() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!

        harness.select(try makeCollectionRow().item)

        let collection = try await shownCollection(in: viewer)
        harness.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(viewer.view.safeAreaInsets.top, 0, "the window has no toolbar inset, so this test cannot tell the two pins apart")
        let top = collection.view.convert(collection.view.bounds, to: nil).maxY
        let safeTop = viewer.view.convert(viewer.view.safeAreaRect, to: nil).maxY
        XCTAssertLessThanOrEqual(top, safeTop + 0.5, "the collection starts \(top - safeTop) points above the safe area")
    }

    // MARK: - The way back

    /// Back shows the list as the person left it. At the base it built a new list, so every one of these was lost.
    func testBackFindsTheListAsThePersonLeftItInAFreshWindow() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        try await assertBackKeepsThePlace(in: harness, row: try makeCollectionRow().item)
    }

    func testBackFindsTheListAsThePersonLeftItAfterAnotherKind() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.select(try await buildRow(of: "Kraken2", under: root))
        let kraken = await settle(harness, on: "Kraken2")
        XCTAssertTrue(kraken, "the Kraken2 row never opened")

        try await assertBackKeepsThePlace(in: harness, row: try makeCollectionRow().item)
    }

    /// The place in the list, read from the scroll view, in a list long enough to scroll.
    func testBackFindsTheScrollPlace() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let records = (0..<400).map { ">record_\($0)\nACGTACGTACGT\n" }.joined()
        harness.select(try makeCollectionRow(named: "long.fasta", records: records).item)
        let collection = try await shownCollection(in: viewer)
        harness.window.contentView?.layoutSubtreeIfNeeded()
        collection.testTableView.scrollRowToVisible(300)
        let place = try XCTUnwrap(collection.testTableView.enclosingScrollView).contentView.bounds.origin.y
        XCTAssertGreaterThan(place, 0, "the list did not scroll")

        open(row: 300, in: collection)
        viewer.testTapCollectionBackNavigation()
        harness.window.contentView?.layoutSubtreeIfNeeded()

        let back = try XCTUnwrap(viewer.fastaCollectionController, "Back did not bring the collection back")
        XCTAssertEqual(try XCTUnwrap(back.testTableView.enclosingScrollView).contentView.bounds.origin.y, place, accuracy: 0.5, "Back lost the scroll place")
    }

    func testTheBackButtonShowsWithOneSequenceAndGoesOnBack() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        harness.select(try makeCollectionRow().item)
        let collection = try await shownCollection(in: viewer)
        XCTAssertNil(viewer.collectionBackButton, "a back button shows over the list")

        open(row: 1, in: collection)

        XCTAssertEqual(viewer.collectionBackButton?.title, "All Sequences (3)")
        XCTAssertNotNil(viewer.collectionNavBar?.superview, "the back button is not on screen")
        XCTAssertNil(viewer.fastaCollectionController, "the list stays on screen over one sequence")
        XCTAssertNil(viewer.installedSurface, "a surface stays installed over one sequence")
        XCTAssertEqual(AlignmentChrome(viewer), chromeVisible, "one sequence shows with the chrome hidden")
        XCTAssertEqual(viewer.referenceFrame?.chromosome, "seq_mid", "the viewer draws another sequence")

        viewer.testTapCollectionBackNavigation()

        XCTAssertNil(viewer.collectionBackButton, "the back button stays over the list")
        XCTAssertNil(viewer.collectionNavBar, "the bar stays over the list")
        XCTAssertNotNil(viewer.fastaCollectionController, "Back did not bring the collection back")
        XCTAssertEqual(AlignmentChrome(viewer), chromeCovered, "the chrome shows over the list after Back")
    }

    func testBackKeepsTheFilesTheExportReads() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let row = try makeCollectionRow()
        harness.select(row.item)
        let collection = try await shownCollection(in: viewer)

        open(row: 0, in: collection)
        viewer.testTapCollectionBackNavigation()

        XCTAssertEqual(viewer.fastaCollectionSourceURLsForTesting, [row.url.standardizedFileURL])
        XCTAssertEqual(viewer.fastaExportSourceURLs(), [row.url.standardizedFileURL])
    }

    // MARK: - Every way out

    /// Each kind takes the list away, takes the back button away over one sequence, and lets go of the kept list.
    func testEveryKindOfTheMatrixTakesTheCollectionAndTheBackButtonAway() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let rest = try await buildRow(of: "Status only", under: root)
        let collectionRow = try makeCollectionRow().item

        for kind in ViewSwitchKinds.all where kind.name != "Status only" && kind.outcome != collectionOutcome {
            let row = try await buildRow(of: kind.name, under: root)
            harness.select(rest)
            let restedAlone = await settle(harness, on: "Status only")
            XCTAssertTrue(restedAlone, "the status row never opened before \(kind.name)")
            harness.select(row)
            let alone = await settle(harness, on: kind.name)
            XCTAssertTrue(alone, "\(kind.name) never opened from the status row")
            let chromeAlone = AlignmentChrome(viewer)

            harness.select(rest)
            let rested = await settle(harness, on: "Status only")
            XCTAssertTrue(rested, "the status row never opened before the collection and \(kind.name)")
            harness.select(collectionRow)
            weak var left = try await shownCollection(in: viewer)

            harness.select(row)

            let after = await settle(harness, on: kind.name)
            XCTAssertTrue(after, "\(kind.name) never opened after the collection")
            XCTAssertNil(viewer.fastaCollectionController, "\(kind.name) left the collection on screen")
            XCTAssertEqual(AlignmentChrome(viewer), chromeAlone, "\(kind.name) shows other chrome after the collection than alone")
            let released = await waitUntil(budget: .lookup) { left == nil }
            XCTAssertTrue(released, "the collection outlived \(kind.name)")

            harness.select(rest)
            let restedAgain = await settle(harness, on: "Status only")
            XCTAssertTrue(restedAgain, "the status row never opened before one sequence and \(kind.name)")
            harness.select(collectionRow)
            weak var kept: FASTACollectionViewController?
            do {
                let list = try await shownCollection(in: viewer)
                kept = list
                open(row: 0, in: list)
            }
            XCTAssertNotNil(viewer.collectionBackButton, "no back button before \(kind.name)")

            harness.select(row)

            let afterOne = await settle(harness, on: kind.name)
            XCTAssertTrue(afterOne, "\(kind.name) never opened after one sequence")
            XCTAssertNil(viewer.collectionBackButton, "\(kind.name) kept the back button")
            XCTAssertNil(viewer.collectionNavBar, "\(kind.name) kept the bar")
            XCTAssertEqual(AlignmentChrome(viewer), chromeAlone, "\(kind.name) shows other chrome after one sequence than alone")
            let keptReleased = await waitUntil(budget: .lookup) { kept == nil }
            XCTAssertTrue(keptReleased, "the kept list outlived \(kind.name)")
        }
    }

    func testASecondCollectionTakesNothingOfTheFirst() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        harness.select(try makeCollectionRow().item)
        weak var left: FASTACollectionViewController?
        do {
            let first = try await shownCollection(in: viewer)
            first.testFilter("mid")
            first.testSelectRows([0])
            left = first
        }

        harness.select(try makeCollectionRow(named: "other.fasta", records: ">other_a\nACGT\n>other_b\nGGCC\n").item)

        let found = await waitUntil(budget: .lookup) {
            viewer.fastaCollectionController.map { self.names(in: $0) == ["other_a", "other_b"] } ?? false
        }
        XCTAssertTrue(found, "the second collection never showed")
        XCTAssertEqual(viewer.fastaCollectionController?.testTableView.selectedRowIndexes.count, 0, "the first collection's selection stayed")
        XCTAssertEqual(viewer.children.filter { $0 is FASTACollectionViewController }.count, 1)
        let released = await waitUntil(budget: .lookup) { left == nil }
        XCTAssertTrue(released, "the first collection outlived the second")
    }

    func testAProjectSwitchTakesTheCollectionAndTheBackButtonAway() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        harness.select(try makeCollectionRow().item)
        _ = try await shownCollection(in: viewer)

        harness.split.resetWindowForProjectChange()

        XCTAssertNil(viewer.fastaCollectionController, "a project switch left the collection on screen")
        XCTAssertEqual(AlignmentChrome(viewer), chromeVisible, "a project switch left chrome hidden")

        harness.select(try makeCollectionRow(named: "second.fasta", records: Self.records).item)
        open(row: 0, in: try await shownCollection(in: viewer))
        harness.split.resetWindowForProjectChange()

        XCTAssertNil(viewer.collectionBackButton, "a project switch kept the back button")
        XCTAssertNil(viewer.collectionNavBar, "a project switch kept the bar")
    }

    func testClosingTheWindowLeavesNoCollectionBehind() async throws {
        let row = try makeCollectionRow().item
        weak var weakSplit: MainSplitViewController?
        weak var weakCollection: FASTACollectionViewController?
        do {
            let harness = try ViewSwitchWindowHarness()
            harness.select(row)
            weakCollection = try await shownCollection(in: harness.split.viewerController)
            weakSplit = harness.split
            // Not `harness.close()`: it clears the viewport through the host, which would remove the collection even if the
            // window's own close left it behind.
            harness.controller.close()
            harness.split.invalidateDisplayRequest()
        }
        let gone = await waitUntil(budget: .lookup) { weakSplit == nil }
        XCTAssertTrue(gone, "the window's split controller outlived the close")
        let released = await waitUntil(budget: .lookup) { weakCollection == nil }
        XCTAssertTrue(released, "the collection outlived the window")
    }

    func testClosingTheWindowOverOneSequenceLetsGoOfTheKeptList() async throws {
        let row = try makeCollectionRow().item
        weak var weakSplit: MainSplitViewController?
        weak var weakCollection: FASTACollectionViewController?
        do {
            let harness = try ViewSwitchWindowHarness()
            harness.select(row)
            let collection = try await shownCollection(in: harness.split.viewerController)
            weakCollection = collection
            weakSplit = harness.split
            open(row: 0, in: collection)
            harness.controller.close()
            harness.split.invalidateDisplayRequest()
        }
        let gone = await waitUntil(budget: .lookup) { weakSplit == nil }
        XCTAssertTrue(gone, "the window's split controller outlived the close")
        let released = await waitUntil(budget: .lookup) { weakCollection == nil }
        XCTAssertTrue(released, "the kept list outlived the window")
    }

    // MARK: - A collection that does not read

    /// The base has no such path. The surface can refuse now, and the words are the file's own.
    func testACollectionThatDoesNotOpenSaysWhatToTry() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        viewer.surfaceHost.registry.register(.view(.fastaCollection)) { RefusingCollectionSurface() }

        harness.select(try makeCollectionRow().item)

        let said = await waitUntil(budget: .lookup) { viewer.statusBar.positionLabel.stringValue.hasPrefix("Unable to open the FASTA collection. ") }
        let words = viewer.statusBar.positionLabel.stringValue
        XCTAssertTrue(said, "the status line never said the collection did not open: \(words)")
        XCTAssertEqual(words, "Unable to open the FASTA collection. genome.fasta ends in the middle of a record. Select the item again.")
        XCTAssertNil(viewer.fastaCollectionController, "a refused collection is on screen")
        XCTAssertEqual(AlignmentChrome(viewer), chromeVisible, "a refused collection left the chrome hidden")
    }

    /// The base logged each failure and said nothing to the person.
    func testASelectionWhereNoFileReadsSaysWhatToTry() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let gone = [root.appendingPathComponent("gone-a.fasta"), root.appendingPathComponent("gone-b.fasta")]

        harness.split.handleMultipleItemsSelected(gone.map { SidebarItem(title: $0.lastPathComponent, type: .sequence, url: $0) })

        let said = await waitUntil(budget: .lookup) { viewer.statusBar.positionLabel.stringValue.hasPrefix("Unable to open the FASTA collection. ") }
        let words = viewer.statusBar.positionLabel.stringValue
        XCTAssertTrue(said, "the status line never said the selection did not read: \(words)")
        XCTAssertTrue(words.contains("gone-a.fasta"), "the words do not name a file: \(words)")
        XCTAssertTrue(words.hasSuffix(" Select the item again."), "the words give no next step: \(words)")
    }

    /// The base showed the rest of the selection with no word that a file was missing, under a count that read as whole.
    func testASelectionWithOneFileThatDoesNotReadNamesIt() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let good = try makeCollectionRow()
        let gone = root.appendingPathComponent("gone.fasta")

        harness.split.handleMultipleItemsSelected([good.item, SidebarItem(title: gone.lastPathComponent, type: .sequence, url: gone)])

        let collection = try await shownCollection(in: viewer)
        XCTAssertEqual(collection.testTableView.numberOfRows, 3, "the file that read is not all there")
        let sheetShown = await waitUntil(budget: .lookup) { harness.window.attachedSheet != nil }
        XCTAssertTrue(sheetShown, "nothing told the person that gone.fasta did not read")
        if let sheet = harness.window.attachedSheet {
            let words = textFields(in: sheet.contentView).map(\.stringValue).joined(separator: " ")
            XCTAssertTrue(words.contains("gone.fasta"), "the sheet does not name the file: \(words)")
            harness.window.endSheet(sheet)
        }
    }

    /// The base opened the list from memory, with numbers of a file nobody can check.
    func testACollectionWhoseFileHasGoneSaysWhatToTry() throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let row = try makeCollectionRow()
        try FileManager.default.removeItem(at: row.url)

        viewer.displayDocument(try twoRecordDocument(at: row.url))

        XCTAssertEqual(
            viewer.statusBar.positionLabel.stringValue,
            "Unable to open the FASTA collection. genome.fasta is no longer where it was opened from. Check that the file is still in the project folder and that its drive is connected, then select it again."
        )
        XCTAssertNil(viewer.fastaCollectionController, "a list whose file has gone is on screen")
    }

    func testACollectionWhoseFileIsLockedSaysWhatToTry() throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let row = try makeCollectionRow()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: row.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: row.url.path) }

        viewer.displayDocument(try twoRecordDocument(at: row.url))

        XCTAssertEqual(
            viewer.statusBar.positionLabel.stringValue,
            "Unable to open the FASTA collection. This Mac does not allow genome.fasta to be read. Check the file's permissions in Finder, then select it again."
        )
        XCTAssertNil(viewer.fastaCollectionController, "a locked list is on screen")
    }

    /// A project sequence's URL spells a name in the project and no file (`ProjectDocumentLoader.swift:17`), so it has nothing to check.
    func testAProjectSequenceHasNoFileToCheckAndStillOpens() throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let document = try twoRecordDocument(at: root.appendingPathComponent("no-such-file.fasta"))
        document.projectSequenceID = UUID()

        viewer.displayDocument(document)

        XCTAssertNotNil(viewer.fastaCollectionController, "a project sequence was refused for a file it never had")
    }

    /// The list is in memory on the way back, so a file gone meanwhile does not take it from the person.
    func testTheWayBackReadsNoFile() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let row = try makeCollectionRow()
        harness.select(row.item)
        open(row: 0, in: try await shownCollection(in: viewer))
        try FileManager.default.removeItem(at: row.url)

        viewer.testTapCollectionBackNavigation()

        XCTAssertNotNil(viewer.fastaCollectionController, "Back did not bring the list back")
        XCTAssertEqual(viewer.fastaCollectionSourceURLsForTesting, [], "the export would read a file that has gone")
    }

    // MARK: - A search left running

    /// Leaving ended the search at the base, through the hide's cancel. Only NCBI's answer or the person ends one.
    func testASearchStaysRunningWhenAPersonGoesToAnotherKindAndComesBackOnItsRow() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let started = HeldSearch()
        let answer = HeldSearch()
        viewer.fastaBlastVerificationRunner = { _, progress in
            try await started.wait()
            progress(0.5, "Waiting for BLAST results")
            try await answer.wait()
            return self.blastResult(rid: "RID-LEFT")
        }
        harness.select(try makeCollectionRow().item)
        let collection = try await shownCollection(in: viewer)

        let row = try send(from: collection)
        defer { clear(row) }
        harness.select(try await buildRow(of: "Kraken2", under: root))
        let moved = await settle(harness, on: "Kraken2")
        XCTAssertTrue(moved, "Kraken2 never opened")

        XCTAssertEqual(item(row)?.state, .running, "leaving the collection ended the search")
        started.release()
        let reported = await waitUntil(budget: .lookup) { self.item(row)?.detail == "Waiting for BLAST results" }
        XCTAssertTrue(reported, "the row froze when the person left: \(item(row)?.detail ?? "no row")")
        answer.release()
        let done = await waitUntil(budget: .lookup) { self.item(row)?.state == .completed }
        XCTAssertTrue(done, "the row reads \(String(describing: item(row)?.state))")
        XCTAssertEqual(item(row)?.detail, "Results ready for 1 sequence")
    }

    /// Each way out leaves the row running: the shim itself, one sequence opened from the list, a project switch and a close.
    func testEveryWayOutLeavesARunningSearch() async throws {
        let ways: [(String, (ViewSwitchWindowHarness, FASTACollectionViewController) -> Void)] = [
            ("the shim", { harness, _ in harness.split.viewerController.clearSurface(ifShowing: .view(.fastaCollection)) }),
            ("one sequence", { [self] _, collection in open(row: 0, in: collection) }),
            ("a project switch", { harness, _ in harness.split.resetWindowForProjectChange() }),
            ("a window close", { harness, _ in harness.controller.close() }),
        ]
        for (name, leave) in ways {
            let harness = try ViewSwitchWindowHarness()
            defer { harness.close() }
            let viewer = harness.split.viewerController!
            let answer = HeldSearch()
            viewer.fastaBlastVerificationRunner = { _, _ in
                try await answer.wait()
                return self.blastResult(rid: "RID-WAY")
            }
            harness.select(try makeCollectionRow(named: "\(UUID().uuidString).fasta", records: Self.records).item)
            let collection = try await shownCollection(in: viewer)
            let row = try send(from: collection)
            defer { clear(row) }

            leave(harness, collection)

            XCTAssertEqual(item(row)?.state, .running, "\(name) ended the search")
            answer.release()
            let done = await waitUntil(budget: .lookup) { self.item(row)?.state == .completed }
            XCTAssertTrue(done, "after \(name) the row reads \(String(describing: item(row)?.state))")
        }
    }

    /// A search left running in one collection is not the next collection's to end. Its first line cancels its own run only.
    func testASearchInAnotherCollectionLeavesTheFirstRunning() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let firstAnswer = HeldSearch()
        viewer.fastaBlastVerificationRunner = { request, _ in
            if request.taxonName == "seq_long" { try await firstAnswer.wait() }
            return self.blastResult(rid: "RID-\(request.taxonName)")
        }
        harness.select(try makeCollectionRow().item)
        let first = try await shownCollection(in: viewer)
        let firstRow = try send(from: first)
        defer { clear(firstRow) }

        harness.select(try makeCollectionRow(named: "other.fasta", records: ">other_a\nACGTACGTACGTACGTACGT\n>other_b\nGGCCGGCC\n").item)
        let moved = await waitUntil(budget: .lookup) {
            viewer.fastaCollectionController.map { self.names(in: $0) == ["other_a", "other_b"] } ?? false
        }
        XCTAssertTrue(moved, "the second collection never showed")
        let second = try XCTUnwrap(viewer.fastaCollectionController)
        let secondRow = try send(from: second)
        defer { clear(secondRow) }

        XCTAssertEqual(item(firstRow)?.state, .running, "the second collection's search ended the first")
        let secondDone = await waitUntil(budget: .lookup) { self.item(secondRow)?.state == .completed }
        XCTAssertTrue(secondDone, "the second search reads \(String(describing: item(secondRow)?.state))")
        firstAnswer.release()
        let firstDone = await waitUntil(budget: .lookup) { self.item(firstRow)?.state == .completed }
        XCTAssertTrue(firstDone, "the first search reads \(String(describing: item(firstRow)?.state))")
    }

    /// A search that answers while one sequence shows is on the pane Back brings.
    func testASearchThatAnswersOverOneSequenceIsOnThePaneAfterBack() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let answer = HeldSearch()
        viewer.fastaBlastVerificationRunner = { _, _ in
            try await answer.wait()
            return self.blastResult(rid: "RID-BACK")
        }
        harness.select(try makeCollectionRow().item)
        let collection = try await shownCollection(in: viewer)
        let row = try send(from: collection)
        defer { clear(row) }

        open(row: 0, in: collection)
        answer.release()
        let done = await waitUntil(budget: .lookup) { self.item(row)?.state == .completed }
        XCTAssertTrue(done, "the row reads \(String(describing: item(row)?.state))")
        viewer.testTapCollectionBackNavigation()

        let pane = try XCTUnwrap(viewer.fastaCollectionController, "Back did not bring the collection back")
        let landed = await waitUntil(budget: .lookup) {
            if case .results(let shown, _)? = pane.testBlastDrawerTab?.displayState { return shown.rid == "RID-BACK" }
            return false
        }
        XCTAssertTrue(landed, "the pane reads \(String(describing: pane.testBlastDrawerTab?.displayState))")
        XCTAssertTrue(pane.testBlastDrawerIsOpen, "the pane is closed after Back")
    }

    func testAPersonsCancelEndsASearchLeftRunning() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let answer = HeldSearch()
        viewer.fastaBlastVerificationRunner = { _, _ in
            try await answer.wait()
            return self.blastResult(rid: "unused")
        }
        harness.select(try makeCollectionRow().item)
        let collection = try await shownCollection(in: viewer)
        let row = try send(from: collection)
        defer { clear(row) }
        open(row: 0, in: collection)

        OperationCenter.shared.cancel(id: row)

        let cancelled = await waitUntil(budget: .lookup) { self.item(row)?.state == .cancelled }
        XCTAssertTrue(cancelled, "the row reads \(String(describing: item(row)?.state))")
    }

    /// A second Verify from one list is a new search and not the end of the first. Each answer lands on its own row.
    func testASecondSearchFromOneListLeavesTheFirstRunning() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let held = HeldSearch()
        let collection = try await collectionHolding(held, in: harness)
        let first = try send(from: collection)
        let second = try send(from: collection, row: 1)
        defer { clear(first); clear(second) }

        XCTAssertEqual(item(first)?.state, .running, "a second Verify from the same list ended the first search")
        let paneMoved = await waitUntil(budget: .lookup) { self.shownRID(on: collection) == "RID-seq_mid" }
        XCTAssertTrue(paneMoved, "the pane reads \(String(describing: collection.testBlastDrawerTab?.displayState))")
        held.release()
        let firstDone = await waitUntil(budget: .lookup) { self.item(first)?.state == .completed }
        XCTAssertTrue(firstDone, "the first search reads \(String(describing: item(first)?.state))")
        XCTAssertEqual(shownRID(on: collection), "RID-seq_mid", "the older answer took the pane")
    }

    /// Another row, a sort or a filter is not a Cancel. The search keeps its pane and runs on, and its answer lands there.
    func testSelectingSortingOrFilteringLeavesASearchRunning() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let held = HeldSearch()
        let collection = try await collectionHolding(held, in: harness)
        let row = try send(from: collection)
        defer { clear(row) }

        let changes: [(String, () -> Void)] = [
            ("selecting another row", { collection.testSelectRows([1]) }),
            ("filtering", { collection.testFilter("m") }),
            ("sorting", { collection.testSort(column: "length", ascending: true) }),
        ]
        for (name, change) in changes {
            change()
            XCTAssertEqual(item(row)?.state, .running, "\(name) ended the search")
            XCTAssertTrue(collection.testBlastDrawerIsOpen, "\(name) closed the search's pane")
        }
        held.release()
        let done = await waitUntil(budget: .lookup) { self.item(row)?.state == .completed }
        XCTAssertTrue(done, "the search reads \(String(describing: item(row)?.state))")
        XCTAssertEqual(shownRID(on: collection), "RID-seq_long", "the answer never reached the pane")
    }

    // MARK: - Support

    private static let records = ">seq_long first\nACGTACGTACGTACGTACGTACGTACGTACGTACGTACGT\n>seq_mid second\nAATTGGCCAATTGGCCAATT\n>seq_short third\nGGCCGGCC\n"
    private let collectionOutcome = "FASTACollectionViewController in genomics"

    /// A FASTA file with three records in a project, and the row the sidebar's scan gives it.
    private func makeCollectionRow(
        named name: String = "genome.fasta", records: String = FASTACollectionSurfaceRouteTests.records
    ) throws -> (url: URL, item: SidebarItem) {
        let folder = root.appendingPathComponent("\(UUID().uuidString).lungfish/Inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try records.write(to: url, atomically: true, encoding: .utf8)
        return (url, RoutingSafetyNetItems.scanned(url))
    }

    private func twoRecordDocument(at url: URL) throws -> LoadedDocument {
        let document = LoadedDocument(url: url, type: .fasta)
        document.sequences = [
            try LungfishCore.Sequence(name: "first", alphabet: .dna, bases: "AACCGGTT"),
            try LungfishCore.Sequence(name: "second", alphabet: .dna, bases: "ATATAT"),
        ]
        return document
    }

    /// Waits until the collection shows, whichever way it reached the viewer.
    private func shownCollection(
        in viewer: ViewerViewController, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> FASTACollectionViewController {
        _ = await waitUntil(budget: .lookup) { viewer.fastaCollectionController != nil }
        return try XCTUnwrap(viewer.fastaCollectionController, "the collection never showed", file: file, line: line)
    }

    private func assertBackKeepsThePlace(in harness: ViewSwitchWindowHarness, row: SidebarItem) async throws {
        let viewer = harness.split.viewerController!
        harness.select(row)
        let collection = try await shownCollection(in: viewer)
        collection.testSort(column: "length", ascending: true)
        XCTAssertEqual(names(in: collection), ["seq_short", "seq_mid", "seq_long"])
        collection.testFilter("seq_")
        collection.testSelectRows([1])
        collection.testFilter("m")
        XCTAssertEqual(names(in: collection), ["seq_mid"], "the filter did not narrow the list")
        collection.testSelectRows([0])

        open(row: 0, in: collection)
        XCTAssertEqual(viewer.referenceFrame?.chromosome, "seq_mid", "the viewer draws another sequence")
        viewer.testTapCollectionBackNavigation()

        let back = try XCTUnwrap(viewer.fastaCollectionController, "Back did not bring the collection back")
        XCTAssertEqual(names(in: back), ["seq_mid"], "Back lost the filter")
        XCTAssertEqual(back.testTableView.selectedRowIndexes, IndexSet(integer: 0), "Back lost the selection")
        back.testFilter("")
        XCTAssertEqual(names(in: back), ["seq_short", "seq_mid", "seq_long"], "Back lost the sort")
        XCTAssertEqual(viewer.installedSurface?.surfaceKind, .view(.fastaCollection), "Back left the host out")
    }

    /// Opens `row` as a double-click does, through the table's Open Row action.
    private func open(row: Int, in collection: FASTACollectionViewController) {
        collection.open(row: row)
    }

    /// Sends one row of the list (the first unless told), past the consent sheet, and returns the search's row.
    private func send(from collection: FASTACollectionViewController, row index: Int = 0) throws -> UUID {
        let before = Set(OperationCenter.shared.items.map(\.id))
        let sequence = try LungfishCore.Sequence(name: names(in: collection)[index], alphabet: .dna, bases: "ACGTACGTACGTACGTACGT")
        collection.onBlastRequested?([sequence])
        return try XCTUnwrap(OperationCenter.shared.items.first { !before.contains($0.id) }?.id, "the search made no row")
    }

    /// A collection whose search for `seq_long` waits for `held`, and whose other searches answer at once with their own name.
    private func collectionHolding(_ held: HeldSearch, in harness: ViewSwitchWindowHarness) async throws -> FASTACollectionViewController {
        let viewer = harness.split.viewerController!
        viewer.fastaBlastVerificationRunner = { request, _ in
            if request.taxonName == "seq_long" { try await held.wait() }
            return self.blastResult(rid: "RID-\(request.taxonName)")
        }
        harness.select(try makeCollectionRow().item)
        return try await shownCollection(in: viewer)
    }

    private func shownRID(on collection: FASTACollectionViewController) -> String? {
        guard case .results(let shown, _)? = collection.testBlastDrawerTab?.displayState else { return nil }
        return shown.rid
    }

    private func item(_ id: UUID) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.id == id }
    }

    private func clear(_ id: UUID) {
        OperationCenter.shared.cancel(id: id)
        OperationCenter.shared.acknowledgeCancellation(id: id)
        OperationCenter.shared.clearItem(id: id)
    }

    private func names(in collection: FASTACollectionViewController) -> [String] {
        cells("name", in: collection)
    }

    private func cells(_ columnID: String, in collection: FASTACollectionViewController) -> [String] {
        let table = collection.testTableView
        guard let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == columnID }) else { return [] }
        return (0..<table.numberOfRows).map { row in
            let cell = table.view(atColumn: column, row: row, makeIfNecessary: true)
            return textFields(in: cell).first?.stringValue ?? ""
        }
    }

    private func textFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        return ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap { textFields(in: $0) }
    }

    private func blastResult(rid: String) -> BlastVerificationResult {
        BlastVerificationResult(
            taxonName: "seq", taxId: 0,
            readResults: [BlastReadResult(
                id: "seq", verdict: .verified, topHitOrganism: "Macaca mulatta", topHitAccession: "AB123456",
                percentIdentity: 99.5, eValue: 0, matchesQueriedTaxon: true
            )],
            submittedAt: Date(), completedAt: Date(), rid: rid, blastProgram: "megablast", database: "core_nt"
        )
    }

    /// Waits until the window shows `name`'s kind: what is installed, whatever mode it sits in.
    private func settle(_ harness: ViewSwitchWindowHarness, on name: String) async -> Bool {
        guard let kind = ViewSwitchKinds.all.first(where: { $0.name == name }),
              let shown = kind.outcome.components(separatedBy: " in ").first else { return false }
        let paths = SafetyNetPathRenderer(root: root)
        return await waitUntil(budget: .lookup) {
            ViewSwitchKinds.outcome(of: RoutingObserver.observe(harness.split, paths: paths, loaded: [])).hasPrefix(shown + " in ")
        }
    }
}
