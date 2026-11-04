// BlastSourceStampTests.swift - A late result lands only while its source is the run it was sent from
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane BLASTCOLLECT, gap 6 of C3 (ARCH-BLAST-RESILIENCE section 6, UX-BLAST-WORDS Every route, Replaced file). A search can
// wait for hours, and a source can be run again in that time. A verdict about the old run's reads must not land on the
// new run's row. An empty stamp holds, so a folder with no root record had no guard at all. No network and no process.

import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest

final class BlastSourceStampTests: XCTestCase {
    private var saved: SavedBlastSearchProject!
    private var source: URL!
    private var row: BlastSavedSearchRow!
    /// The document the viewer of each route loads. A folder from before root records holds only this.
    private let documents = ["classification-result.json", "esviritu-result.json", "taxtriage-result.json", "manifest.json"]

    override func setUpWithError() throws {
        saved = try SavedBlastSearchProject()
        source = try saved.result("result-A")
        row = BlastSavedSearchRow(sourceResultURL: source, sample: "S1", taxId: 7, contig: "NC_1")
    }

    override func tearDownWithError() throws {
        saved?.remove()
    }

    private var rootRecord: URL {
        source.appendingPathComponent(BundleKindDescriptor.SidecarNaming.rootRecordFileName)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    /// A result that came back for a search stamped `stamp`, as `blast submit` leaves its folder.
    private func saveLateResult(stamp: String?) throws {
        let recordURL = try saved.saveRecord(rid: "RID-LATE", sourceResult: "result-A", sample: "S1", taxId: 7, contig: "NC_1")
        let request = BlastVerificationRequest(
            taxonName: "Taxon", taxId: 7, sequences: [(id: "read_1", sequence: "ACGT")], database: "core_nt"
        )
        var file = BlastSearchFile(
            origin: .standIn, createdAt: Date(timeIntervalSince1970: 1_800_000_000), submitArgv: [], facts: BlastSearchFile.Facts(request),
            query: BlastSubmissionRecord.Query(fileName: "query.fasta", sha256: "x", sequenceCount: 1), formSHA256: "x"
        )
        file.state = .done
        file.copies[0].rid = "RID-LATE"
        file.lineage = BlastSubmissionRecord.Lineage(sourceResult: source.path, sample: "S1", taxId: 7, contig: "NC_1")
        file.sourceStamp = stamp
        try BlastSearchStore(folder: recordURL.deletingLastPathComponent()).save(file)
    }

    private func lookupLands() -> Bool {
        let row = self.row!
        let found = BlastVerificationArchive.newestSearch(in: saved.project) { lineage, url in
            row.isSource(of: lineage, recordAt: url)
        }
        if case .saved = found { return true }
        return false
    }

    /// Each route's document gives a folder with no root record a stamp, so its guard is not empty.
    func testAFolderFromBeforeRootRecordsStillTellsOneRunFromAnother() throws {
        for name in documents {
            let folder = try saved.result("old-\(name)")
            let document = folder.appendingPathComponent(name)
            try write("first run", to: document)
            let first = try XCTUnwrap(BlastVerificationArchive.sourceStamp(ofResult: folder), "\(name) gives no stamp, so the guard is empty")
            try write("second run", to: document)
            XCTAssertNotEqual(first, BlastVerificationArchive.sourceStamp(ofResult: folder), name)
        }
    }

    func testALateResultOfAReplacedFolderWithNoRootRecordStaysOffTheRow() throws {
        let document = source.appendingPathComponent("esviritu-result.json")
        try write("first run", to: document)
        try saveLateResult(stamp: BlastVerificationArchive.sourceStamp(ofResult: source))
        XCTAssertTrue(lookupLands(), "the same run's source lands")

        try write("second run", to: document)

        XCTAssertFalse(lookupLands(), "a verdict about the old run's reads stays off the new run's row")
    }

    /// A viewer can give an older folder its first root record while a search waits. That is the same run.
    func testARecordWrittenLaterIntoAnOlderFolderIsNoNewRun() throws {
        try write("first run", to: source.appendingPathComponent("manifest.json"))
        try saveLateResult(stamp: BlastVerificationArchive.sourceStamp(ofResult: source))

        try write(#"{"id":"11111111-1111-1111-1111-111111111111","status":"completed"}"#, to: rootRecord)

        XCTAssertTrue(lookupLands(), "the same run's result still lands")
    }

    /// A database build rewrites the root record of the run it reads (`BuildDbCommand+TaxTriageCore.swift`), and the
    /// record keeps its ID, so that result stays on its row. A new run writes a new ID.
    func testARecordRewrittenForItsOwnRunHoldsAndANewRunDoesNot() throws {
        try write(#"{"id":"11111111-1111-1111-1111-111111111111","status":"running"}"#, to: rootRecord)
        let sent = try XCTUnwrap(BlastVerificationArchive.sourceStamp(ofResult: source))
        try saveLateResult(stamp: sent)

        try write(#"{"id":"11111111-1111-1111-1111-111111111111","status":"completed","steps":[]}"#, to: rootRecord)
        XCTAssertEqual(BlastVerificationArchive.sourceStamp(ofResult: source), sent, "one run, one stamp")
        XCTAssertTrue(lookupLands())

        try write(#"{"id":"22222222-2222-2222-2222-222222222222","status":"completed"}"#, to: rootRecord)
        XCTAssertNotEqual(BlastVerificationArchive.sourceStamp(ofResult: source), sent)
        XCTAssertFalse(lookupLands(), "a new run replaced the source")
    }
}
