// FASTACollectionSavedBlastTests.swift - A FASTA list shows a BLAST search that waits for its selection (Phase 3.2 lane LASTROWS, O1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// FASTA-BLAST-WAITING-NOT-ON-ROW. A search sent from a list is saved in the project under the file the list came from, with
// the IDs and bases it sent and no sample, taxon or contig. Every other route finds its search again through
// `BlastVerificationArchive.newestSearch`. These tests write the files `blast submit` leaves and read the list's pane. A stand-in
// leaf is the only thing that ever answers, so nothing reaches NCBI.

import AppKit
import LungfishCore
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow

@MainActor
final class FASTACollectionSavedBlastTests: XCTestCase {
    private var root: URL!
    private var hostDefaults: HostDefaultsRestorer!

    override func setUpWithError() throws {
        isolateAlignmentPaneDefaults()
    }

    override func setUp() async throws {
        try await super.setUp()
        OperationCenter.useTemporaryFailureReportsForTesting()
        root = try TestTempDirectory.make(prefix: "FASTACollectionSavedBlast")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
    }

    override func tearDown() async throws {
        hostDefaults.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    private static let records = ">seq_long first\nACGTACGTACGTACGTACGTACGTACGTACGTACGTACGT\n>seq_mid second\nAATTGGCCAATTGGCCAATT\n>seq_short third\nGGCCGGCC\n"
    private static let longSequence = (id: "seq_long", sequence: "ACGTACGTACGTACGTACGTACGTACGTACGTACGTACGT")

    // MARK: - O1, a search that waits

    /// Pick the sequences a search was sent for, pick others, pick them again, go to another kind and come back, and open a
    /// new window over the same files (a relaunch). The pane reads waiting whenever the sequences are picked.
    func testRowWithASearchWaitingShowsItAfterReselectAndRelaunch() async throws {
        let list = try makeList()
        try saveSearch(in: list.project, source: list.url, sequences: [Self.longSequence])
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        harness.select(list.item)
        let first = try await shownCollection(in: viewer)
        XCTAssertFalse(isWaiting(first), "with nothing picked the list names no row, so it shows no search")

        first.testSelectRows([0])
        let shown = await waitUntil(budget: .lookup) { self.isWaiting(first) }
        try require(shown, "the pane reads \(String(describing: first.testBlastDrawerTab?.displayState))")
        XCTAssertEqual(first.testBlastDrawerTab?.waitingPane.headingLabel.stringValue, "Still waiting at NCBI")
        XCTAssertTrue(first.testBlastDrawerIsOpen, "a search waiting for the picked sequences is not left on a closed pane")

        first.testSelectRows([1])
        XCTAssertFalse(first.testBlastDrawerIsOpen, "other sequences show their own detail and not this search")
        first.testSelectRows([0])
        let again = await waitUntil(budget: .lookup) { self.isWaiting(first) }
        try require(again, "picking the sequences again did not bring the search back")

        harness.select(try await buildRow(of: "Kraken2", under: root))
        let moved = await settle(harness, on: "Kraken2")
        try require(moved, "Kraken2 never opened")
        harness.select(list.item)
        let second = try await shownCollection(in: viewer)
        XCTAssertFalse(second === first, "Back from another kind builds a new list")
        second.testSelectRows([0])
        let afterKind = await waitUntil(budget: .lookup) { self.isWaiting(second) }
        try require(afterKind, "the new list reads \(String(describing: second.testBlastDrawerTab?.displayState))")

        let relaunched = try ViewSwitchWindowHarness()
        defer { relaunched.close() }
        relaunched.select(list.item)
        let third = try await shownCollection(in: relaunched.split.viewerController)
        third.testSelectRows([0])
        let afterRelaunch = await waitUntil(budget: .lookup) { self.isWaiting(third) }
        try require(afterRelaunch, "a relaunched window reads \(String(describing: third.testBlastDrawerTab?.displayState))")
    }

    /// The saved result of the search lands on the pane of the picked sequences when the monitor collects it.
    func testALateResultLandsOnTheRowOfAFastaList() async throws {
        let list = try makeList()
        let folder = try saveSearch(in: list.project, source: list.url, sequences: [Self.longSequence])
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.select(list.item)
        let collection = try await shownCollection(in: harness.split.viewerController)
        collection.testSelectRows([0])
        let waiting = await waitUntil(budget: .lookup) { self.isWaiting(collection) }
        try require(waiting, "the search never showed as waiting")

        try saveRecord(in: folder, source: list.url, sequences: [Self.longSequence], rid: "RID-LATE")
        var file = try BlastSearchStore(folder: folder).load()
        file.state = .done
        try BlastSearchStore(folder: folder).save(file)
        BlastSearchNews.post()

        let landed = await waitUntil(budget: .lookup) {
            if case .results(let result, _)? = collection.testBlastDrawerTab?.displayState { return result.rid == "RID-LATE" }
            return false
        }
        XCTAssertTrue(landed, "the pane reads \(String(describing: collection.testBlastDrawerTab?.displayState))")
    }

    // MARK: - How a row is keyed, and what it never shows

    /// A row in a list is the list's file and the IDs and bases picked, in any order, and nothing else. A list has no taxon.
    func testAKeyIsTheListsFileAndTheIDsAndBasesPicked() throws {
        let list = try makeList()
        let other = try makeList(project: list.project, named: "other.fasta")
        let mid = (id: "seq_mid", sequence: "AATTGGCCAATTGGCCAATT")
        try saveSearch(in: list.project, source: list.url, sequences: [Self.longSequence, mid])

        func isFound(_ sequences: [(id: String, sequence: String)], of source: URL) -> Bool {
            let picked = sequences.map { BlastSavedSearchRow.QuerySequence(id: $0.id, sequence: $0.sequence) }
            guard let row = BlastSavedSearchRow.fastaSelection(sequences: picked, sourceURL: source) else { return false }
            let found = BlastVerificationArchive.newestSearch(in: list.project) { lineage, url in
                row.isSource(of: lineage, recordAt: url)
            }
            if case .live? = found { return true }
            return false
        }
        XCTAssertTrue(isFound([Self.longSequence, mid], of: list.url), "the sequences sent, from the file they came from")
        XCTAssertTrue(isFound([mid, Self.longSequence], of: list.url), "in any order")
        XCTAssertFalse(isFound([Self.longSequence], of: list.url), "a part of what was sent is another query")
        XCTAssertFalse(isFound([Self.longSequence, (id: "seq_mid", sequence: "AATTGGCCAATTGGCCAATA")], of: list.url), "the same ID over other bases")
        XCTAssertFalse(isFound([Self.longSequence, mid], of: other.url), "the same sequences from another file")
        XCTAssertFalse(isFound([], of: list.url), "nothing picked names no row")
    }

    /// A second list holds no search, so it shows nothing. That holds for another file with the very same sequences, and for
    /// the same file with other sequences picked.
    func testASecondListThatHoldsNoSearchShowsNothing() async throws {
        let list = try makeList()
        try saveSearch(in: list.project, source: list.url, sequences: [Self.longSequence])
        let other = try makeList(project: list.project, named: "other.fasta")
        let secondWindow = try ViewSwitchWindowHarness()
        defer { secondWindow.close() }
        secondWindow.select(other.item)
        let second = try await shownCollection(in: secondWindow.split.viewerController)
        second.testSelectRows([0])
        let lookedForOther = second.savedBlastRestorer
        await lookedForOther?.restoreTask?.value
        XCTAssertNotNil(lookedForOther?.restoreTask, "the look-up never ran")
        XCTAssertFalse(second.testBlastDrawerIsOpen, "the second list shows another file's search")
        XCTAssertFalse(isWaiting(second))

        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.select(list.item)
        let first = try await shownCollection(in: harness.split.viewerController)
        first.testSelectRows([1])
        let lookedForSame = first.savedBlastRestorer
        await lookedForSame?.restoreTask?.value
        XCTAssertNotNil(lookedForSame?.restoreTask, "the look-up never ran")
        XCTAssertFalse(first.testBlastDrawerIsOpen, "other sequences of the same file show this search")
        XCTAssertFalse(isWaiting(first))
    }

    /// A late result is for the sequences it was sent for. It never shows over other sequences, and it shows when they are
    /// picked again.
    func testALateResultNeverShowsOverOtherSequencesAndShowsWhenTheyArePickedAgain() async throws {
        let list = try makeList()
        let folder = try saveSearch(in: list.project, source: list.url, sequences: [Self.longSequence])
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.select(list.item)
        let collection = try await shownCollection(in: harness.split.viewerController)
        collection.testSelectRows([0])
        let waiting = await waitUntil(budget: .lookup) { self.isWaiting(collection) }
        try require(waiting, "the search never showed as waiting")
        collection.testSelectRows([1])
        await collection.savedBlastRestorer?.restoreTask?.value

        try saveRecord(in: folder, source: list.url, sequences: [Self.longSequence], rid: "RID-LATE")
        var file = try BlastSearchStore(folder: folder).load()
        file.state = .done
        try BlastSearchStore(folder: folder).save(file)
        BlastSearchNews.post()
        await collection.savedBlastRestorer?.restoreTask?.value
        XCTAssertFalse(collection.testBlastDrawerIsOpen, "a late result showed over other sequences")

        collection.testSelectRows([0])
        await collection.savedBlastRestorer?.restoreTask?.value
        guard case .results(let result, _)? = collection.testBlastDrawerTab?.displayState else {
            return XCTFail("the pane reads \(String(describing: collection.testBlastDrawerTab?.displayState))")
        }
        XCTAssertEqual(result.rid, "RID-LATE")
    }

    // MARK: - Re-run BLAST on a restored result (LASTROWS fix round, BIO B1)

    /// Re-run BLAST on a result the list restored repeats the sequences picked. A list opened again has sent nothing, so it had no
    /// request to repeat, and a list that sent other sequences last repeated those on the pane of the picked ones.
    func testReRunOnARestoredResultRepeatsThePickedSequences() async throws {
        let list = try makeList()
        let folder = try saveSearch(in: list.project, source: list.url, sequences: [Self.longSequence])
        try saveRecord(in: folder, source: list.url, sequences: [Self.longSequence], rid: "RID-SAVED")
        var file = try BlastSearchStore(folder: folder).load()
        file.state = .done
        try BlastSearchStore(folder: folder).save(file)

        BlastConsentSheet.presenterForTesting = { _, send in send() }
        let rowsBefore = Set(OperationCenter.shared.items.map(\.id))
        defer {
            BlastConsentSheet.presenterForTesting = nil
            for item in OperationCenter.shared.items where !rowsBefore.contains(item.id) { OperationCenter.shared.clearItem(id: item.id) }
        }
        var sent: [[String]] = []
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        viewer.fastaBlastVerificationRunner = { request, _ in
            let ids = request.sequences.map { $0.id }
            sent.append(ids)
            let at = Date(timeIntervalSince1970: 1_800_000_100)
            return BlastVerificationResult(
                taxonName: "FASTA fixture", taxId: 0, totalReads: 0, verifiedCount: 0, ambiguousCount: 0,
                unverifiedCount: 0, errorCount: 0, readResults: [], submittedAt: at.addingTimeInterval(-60),
                completedAt: at, rid: "RID-SENT-" + ids.joined(separator: ","), blastProgram: "blastn", database: "core_nt"
            )
        }
        harness.select(list.item)
        let collection = try await shownCollection(in: viewer)
        func shownRID() -> String? {
            if case .results(let result, _)? = collection.testBlastDrawerTab?.displayState { return result.rid }
            return nil
        }
        func pane() -> String { String(describing: collection.testBlastDrawerTab?.displayState) }

        // A list opened again has sent nothing. Its pane shows the saved result of the sequences picked.
        collection.testSelectRows([0])
        let restored = await waitUntil(budget: .lookup) { shownRID() == "RID-SAVED" }
        try require(restored, "the saved result never showed, the pane reads \(pane())")
        collection.onBlastRerunRequested?()
        let sentOnce = await waitUntil(budget: .lookup) { sent.count == 1 }
        XCTAssertEqual(sent, [["seq_long"]], "Re-run on a restored result sent other sequences, or none")
        if sentOnce { _ = await waitUntil(budget: .lookup) { shownRID() == "RID-SENT-seq_long" } }

        // A list that sent other sequences last repeats the ones picked now, and not the last it sent.
        collection.testSelectRows([1])
        XCTAssertEqual(collection.selectedSequences().map(\.name), ["seq_mid"])
        let sentBefore = sent.count
        collection.onBlastRequested?(collection.selectedSequences())
        let sentOther = await waitUntil(budget: .lookup) { sent.count == sentBefore + 1 && shownRID() == "RID-SENT-seq_mid" }
        try require(sentOther, "the search of the other sequence never ended, the pane reads \(pane())")
        collection.testSelectRows([0])
        let restoredAgain = await waitUntil(budget: .lookup) { shownRID() == "RID-SAVED" }
        try require(restoredAgain, "the saved result did not show again, the pane reads \(pane())")
        collection.onBlastRerunRequested?()
        let rerun = await waitUntil(budget: .lookup) { sent.count == sentBefore + 2 }
        try require(rerun, "Re-run on a restored result sent nothing")
        XCTAssertEqual(sent.last, ["seq_long"], "Re-run repeated the last send and not the sequences picked")
    }

    // MARK: - A pick the send refuses (LASTROWS fix round, BIO SF1)

    /// The send refuses more than its cap, so no search of such a pick can exist. A pick over the cap builds no key and shows no
    /// search, while a pick of exactly the cap still shows its search. A search over the cap is written by hand, since no send can
    /// write one, to give the pick over the cap something it would wrongly show.
    func testAPickOverTheSendCapBuildsNoKeyAndShowsNoSearch() async throws {
        let cap = ViewerViewController.blastSequenceLimit
        let many = (0...cap).map { (id: String(format: "seq_%03d", $0), sequence: "ACGTACGTACGTACGTACGT") }
        let list = try makeList(records: many.map { ">\($0.id)\n\($0.sequence)\n" }.joined())
        try saveSearch(in: list.project, source: list.url, sequences: many)
        try saveSearch(in: list.project, source: list.url, sequences: Array(many.prefix(cap)))
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.select(list.item)
        let collection = try await shownCollection(in: harness.split.viewerController)

        collection.testSelectRows(Array(0...cap))
        XCTAssertEqual(collection.selectedSequences().count, cap + 1)
        await collection.savedBlastRestorer?.restoreTask?.value
        XCTAssertNil(collection.savedBlastRestorer, "a pick the send refuses built a key")
        XCTAssertFalse(collection.testBlastDrawerIsOpen, "a pick the send refuses showed a search")

        collection.testSelectRows(Array(0..<cap))
        let atCap = await waitUntil(budget: .lookup) { self.isWaiting(collection) }
        XCTAssertTrue(atCap, "a pick of exactly the cap lost its search, the pane reads \(String(describing: collection.testBlastDrawerTab?.displayState))")
    }

    // MARK: - Support

    /// Ends the test at the first wait that timed out, since the steps after it would only wait again.
    private func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        struct Unmet: Error {}
        guard condition else {
            XCTFail(message())
            throw Unmet()
        }
    }

    private func isWaiting(_ collection: FASTACollectionViewController) -> Bool {
        if case .waiting? = collection.testBlastDrawerTab?.displayState { return true }
        return false
    }

    /// A project with a FASTA of three records in `Inputs`, and the row the sidebar's scan gives it.
    private func makeList(
        project existing: URL? = nil, named name: String = "genome.fasta", records: String = FASTACollectionSavedBlastTests.records
    ) throws -> (project: URL, url: URL, item: SidebarItem) {
        let project = existing ?? root.appendingPathComponent("\(UUID().uuidString).lungfish", isDirectory: true)
        let folder = project.appendingPathComponent("Inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try records.write(to: url, atomically: true, encoding: .utf8)
        return (project, url, RoutingSafetyNetItems.scanned(url))
    }

    /// The search file `blast submit` leaves for `sequences` sent from the list at `source`. The FASTA plan records the file and
    /// no sample, taxon or contig, and the leaf keeps its query beside the search.
    @discardableResult
    private func saveSearch(
        in project: URL, source: URL, sequences: [(id: String, sequence: String)], rid: String = "RID-FASTA-WAIT"
    ) throws -> URL {
        let folder = project.appendingPathComponent("blast-verifications/fasta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let request = BlastVerificationRequest(taxonName: "FASTA fixture", taxId: 0, sequences: sequences, database: "core_nt")
        var file = BlastSearchFile(
            origin: .standIn, createdAt: Date(timeIntervalSince1970: 1_800_000_000), submitArgv: [],
            facts: BlastSearchFile.Facts(request),
            query: BlastSubmissionRecord.Query(
                fileName: BlastSubmissionRecord.queryFileName, sha256: "x", sequenceCount: sequences.count
            ),
            formSHA256: "x"
        )
        file.state = .waiting
        file.copies[0].rid = rid
        file.copies[0].state = .live
        file.spentAt = file.createdAt
        file.lineage = BlastSubmissionRecord.Lineage(
            sourceResult: "@/Inputs/\(source.lastPathComponent)", sample: nil, taxId: nil, contig: nil
        )
        try BlastSearchStore(folder: folder).save(file)
        let query = sequences.map { ">\($0.id)\n\($0.sequence)\n" }.joined()
        try Data(query.utf8).write(to: folder.appendingPathComponent(BlastSubmissionRecord.queryFileName))
        return folder
    }

    /// The record the monitor saves in the search's folder when NCBI answers.
    private func saveRecord(in folder: URL, source: URL, sequences: [(id: String, sequence: String)], rid: String) throws {
        let completedAt = Date(timeIntervalSince1970: 1_800_000_100)
        let result = BlastVerificationResult(
            taxonName: "FASTA fixture", taxId: 0, totalReads: 0, verifiedCount: 0, ambiguousCount: 0,
            unverifiedCount: 0, errorCount: 0, readResults: [], submittedAt: completedAt.addingTimeInterval(-60),
            completedAt: completedAt, rid: rid, blastProgram: "blastn", database: "core_nt"
        )
        let record = BlastSubmissionRecord(
            savedAt: completedAt,
            query: .init(fileName: BlastSubmissionRecord.queryFileName, sha256: "0", sequenceCount: sequences.count),
            lineage: .init(sourceResult: "@/Inputs/\(source.lastPathComponent)", sample: nil, taxId: nil, contig: nil),
            search: .init(BlastVerificationRequest(taxonName: "FASTA fixture", taxId: 0, sequences: sequences, database: "core_nt")),
            result: result
        )
        try BlastSubmissionRecord.encoder.encode(record).write(to: folder.appendingPathComponent(BlastSubmissionRecord.recordFileName))
    }

    /// Waits until the list shows, whichever way it reached the viewer.
    private func shownCollection(
        in viewer: ViewerViewController, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> FASTACollectionViewController {
        _ = await waitUntil(budget: .lookup) { viewer.fastaCollectionController != nil }
        return try XCTUnwrap(viewer.fastaCollectionController, "the collection never showed", file: file, line: line)
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
