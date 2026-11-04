// BlastStandInStateTests.swift - Where a stand-in run keeps the files BLAST shares across processes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane BLASTNET, N1 (ARCH-BLAST-RESILIENCE item 21 and section 7). The root here is a folder of this test's
// own, so nothing reaches the real root and no test exports LUNGFISH_STORAGE_ROOT.

import Foundation
import XCTest
@testable import LungfishCore

final class BlastStandInStateTests: XCTestCase {
    private static let origin = [BlastServiceEndpoints.standInOriginVariable: "http://127.0.0.1:9"]
    private var scratch: URL!
    private var root: URL!
    private var state: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("blast-standin-state-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        root = scratch.appendingPathComponent("root", isDirectory: true)
        state = scratch.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func sharedFolder(_ environment: [String: String]) -> URL {
        BlastStandInState.sharedFolder(environment: environment, storageRoot: root)
    }

    private func standIn(state value: String) -> [String: String] {
        Self.origin.merging([BlastStandInState.stateVariable: value]) { $1 }
    }

    func testARunWithNoStandInUsesTheRootsFolder() {
        XCTAssertEqual(sharedFolder([:]).path, root.appendingPathComponent("blast").path)
        XCTAssertEqual(
            sharedFolder([BlastStandInState.stateVariable: state.path]).path,
            root.appendingPathComponent("blast").path,
            "the state variable counts only with a stand-in origin"
        )
        XCTAssertNil(BlastStandInState(environment: [BlastStandInState.stateVariable: state.path]))
    }

    func testANamedStateFolderTakesThePlaceOfTheRootsFolder() {
        XCTAssertEqual(sharedFolder(standIn(state: state.path)).path, state.path)
    }

    func testAStandInWithNoStateGetsAFolderOfItsOwnOutsideTheRoot() {
        XCTAssertEqual(sharedFolder(Self.origin), BlastStandInState.processFolder)
        XCTAssertEqual(sharedFolder(standIn(state: "")), BlastStandInState.processFolder, "an empty value is no value")
        XCTAssertFalse(BlastStandInState.processFolder.path.hasPrefix(root.path))
    }

    /// An origin a debug build will not use still sends nothing to NCBI, so it keeps the run away from the root too.
    func testAnOriginThatIsNotLoopbackStaysAwayFromTheRoot() {
        let environment = [BlastServiceEndpoints.standInOriginVariable: "https://blast.ncbi.nlm.nih.gov"]
        XCTAssertEqual(sharedFolder(environment), BlastStandInState.processFolder)
    }

    func testAStateFolderNamedInsideTheRootIsNotUsed() throws {
        let inside = root.appendingPathComponent("blast", isDirectory: true)
        XCTAssertEqual(sharedFolder(standIn(state: inside.path)), BlastStandInState.processFolder)
        XCTAssertEqual(sharedFolder(standIn(state: root.path)), BlastStandInState.processFolder)

        let link = scratch.appendingPathComponent("link-to-root", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let throughLink = link.appendingPathComponent("blast", isDirectory: true)
        XCTAssertEqual(sharedFolder(standIn(state: throughLink.path)), BlastStandInState.processFolder)

        let sibling = scratch.appendingPathComponent("root-beside", isDirectory: true)
        XCTAssertEqual(sharedFolder(standIn(state: sibling.path)).path, sibling.path, "a like name is not inside")
    }

    func testTheManagedLedgerFollowsTheStandInState() async throws {
        let ledger = FileBlastSubmissionLedger.managedStorageDefault(environment: standIn(state: state.path))

        try await ledger.reserve(count: 3, kind: .first, at: Date(), limit: 50)

        let reread = FileBlastSubmissionLedger(fileURL: state.appendingPathComponent(FileBlastSubmissionLedger.fileName))
        let counted = await reread.events(at: Date()).map(\.count)
        XCTAssertEqual(counted, [3], "a second reader of the state folder sees the first one's reads")
    }

    func testAStandInLedgerWritesNothingUnderTheRoot() async throws {
        let folder = sharedFolder(standIn(state: root.appendingPathComponent("blast", isDirectory: true).path))
        let ledger = FileBlastSubmissionLedger(fileURL: folder.appendingPathComponent(FileBlastSubmissionLedger.fileName))
        defer { try? FileManager.default.removeItem(at: BlastStandInState.processFolder) }

        try await ledger.reserve(count: 1, kind: .first, at: Date(), limit: 50)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
}
