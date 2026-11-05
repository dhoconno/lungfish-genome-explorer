// BlastPaneSampleWordsTests.swift - A running search's pane names the sample the search is about
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane BLASTWORDS, W-21 and PARK. A pane that shows a search with no result says whose search it is, so a person who picks
// another row while it runs does not read it as that row's. No network, no process and no modal.

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
import XCTest

@MainActor
final class BlastPaneSampleWordsTests: XCTestCase {
    private var saved: SavedBlastSearchProject!
    private var actions: ClassifierResultActions!
    private var row: BlastSavedSearchRow!
    private let sample = "SRR12486983"

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        OperationCenter.useTemporaryFailureReportsForTesting()
        saved = try SavedBlastSearchProject()
        actions = ClassifierResultActions()
        row = BlastSavedSearchRow(sourceResultURL: try saved.result("result-A"), sample: sample, taxId: 11137, contig: nil)
    }

    override func tearDown() async throws {
        actions = nil
        saved?.remove()
        try await super.tearDown()
    }

    private func select(_ row: BlastSavedSearchRow?) async {
        actions.showSelection(count: 1, blastRow: row)
        await actions.savedBlastRestoreTask?.value
    }

    /// The words a person reads on the pane right now, from the labels that show.
    private var visibleWords: String {
        func fields(_ view: NSView) -> [NSTextField] {
            view.subviews.flatMap { sub -> [NSTextField] in
                (sub as? NSTextField).map { [$0] + fields(sub) } ?? fields(sub)
            }
        }
        return fields(actions.blastDrawer).filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue).joined(separator: " | ")
    }

    /// A search file of `row`, as `blast submit` leaves it while every send waits.
    private func saveSearch(of row: BlastSavedSearchRow, rid: String = "WALK4") throws {
        let folder = saved.project.appendingPathComponent("blast-verifications/live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let request = BlastVerificationRequest(
            taxonName: "Viruses", taxId: row.taxId ?? 0, sequences: [(id: "read_1", sequence: "ACGT")], database: "core_nt"
        )
        var file = BlastSearchFile(
            origin: .standIn, createdAt: Date(timeIntervalSince1970: 1_800_000_000), submitArgv: [], facts: BlastSearchFile.Facts(request),
            query: BlastSubmissionRecord.Query(fileName: "query.fasta", sha256: "x", sequenceCount: 1), formSHA256: "x"
        )
        file.state = .waiting
        file.copies[0].rid = rid
        file.copies[0].state = .live
        file.spentAt = file.createdAt
        file.lineage = BlastSubmissionRecord.Lineage(sourceResult: row.sourceResultURL.path, sample: row.sample, taxId: row.taxId, contig: row.contig)
        try BlastSearchStore(folder: folder).save(file)
    }

    /// The progress pane of a run names its sample, since the row picked may be another one's.
    func testTheProgressPaneNamesTheSampleOfItsSearch() async throws {
        await select(row)
        actions.showBlastLoading(phase: .submitting, requestId: nil)

        guard case .loading = actions.blastDrawer.displayState else { return XCTFail("the pane is not on the run's progress: \(visibleWords)") }
        XCTAssertTrue(visibleWords.contains(sample), "the progress pane names no sample: \(visibleWords)")
    }

    /// The waiting pane of a search that has gone out names its sample, beside its request ID.
    func testTheWaitingPaneNamesTheSampleOfItsSearch() async throws {
        try saveSearch(of: row)
        await select(row)

        guard case .waiting = actions.blastDrawer.displayState else { return XCTFail("the pane is not on the waiting search: \(visibleWords)") }
        XCTAssertTrue(visibleWords.contains(sample), "the waiting pane names no sample: \(visibleWords)")
        XCTAssertTrue(visibleWords.contains("WALK4"), "the request ID went missing: \(visibleWords)")
    }
}
