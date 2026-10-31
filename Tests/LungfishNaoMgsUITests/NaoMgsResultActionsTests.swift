// NaoMgsResultActionsTests.swift - NAO-MGS's bar is the shared classifier action bar
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane ADOPT (plan exit check 4, O86, UX-3E-LABELS). NAO-MGS adopts `ClassifierResultActions`. Its bar holds
// Verify with BLAST…, Extract Reads… and BLAST Results in the ruling's titles, VoiceOver labels and hints, BLAST Results
// reopens the BLAST results a person closed, and a BLAST run that cannot start says why in the results pane (R12)
// instead of a beep and an alert. The view has no defaults seam and these tests touch none.

import AppKit
import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
import SQLite3
import XCTest
@testable import LungfishNaoMgsUI

@MainActor
final class NaoMgsResultActionsTests: XCTestCase {

    /// The bar's three shared buttons read the ruling's words. At the base the bar had no BLAST Results button.
    func testBarHoldsTheSharedButtonsInTheRulingsWords() throws {
        let vc = NaoMgsResultViewController()
        isolateLayouts(vc)
        _ = vc.view
        let bar = vc.testActionBar

        XCTAssertEqual(bar.blastButton.title, "Verify with BLAST\u{2026}")
        XCTAssertEqual(bar.blastButton.accessibilityLabel(), "Verify with BLAST")
        XCTAssertEqual(bar.blastButton.accessibilityHelp()?.hasPrefix("Select a row to verify it with BLAST. "), true)
        XCTAssertEqual(
            bar.blastButton.accessibilityHelp()?.contains("Uses BLASTN without taxon restriction by default."), true
        )
        XCTAssertEqual(bar.extractButton.title, "Extract Reads\u{2026}")
        XCTAssertEqual(bar.extractButton.accessibilityLabel(), "Extract Reads")
        XCTAssertEqual(
            bar.extractButton.accessibilityHelp()?.hasPrefix("Select one or more rows to extract their reads. "), true
        )
        XCTAssertEqual(
            bar.extractButton.accessibilityHelp()?.contains("Opens a dialog to save the reads as FASTQ or FASTA"), true
        )

        let results = try Self.blastResultsButton(in: bar)
        XCTAssertEqual(results.title, "BLAST Results")
        XCTAssertEqual(results.accessibilityLabel(), "BLAST Results")
        XCTAssertEqual(results.toolTip, "Show or hide the BLAST results below the table.")
        XCTAssertEqual(results.accessibilityHelp(), "Shows or hides the BLAST results below the table.")
    }

    /// BLAST Results closes the results and reopens them as they were (U-3E-1).
    func testBlastResultsClosesAndReopensTheResults() throws {
        let vc = NaoMgsResultViewController()
        isolateLayouts(vc)
        _ = vc.view
        let button = try Self.blastResultsButton(in: vc.testActionBar)
        XCTAssertEqual(button.state, .off, "nothing is open when the viewer opens")

        vc.showBlastFailure("NCBI BLAST did not return a result.")
        let drawer = try XCTUnwrap(vc.testBlastDrawerContainer)
        XCTAssertFalse(drawer.isHidden)
        XCTAssertEqual(button.state, .on, "the button shows that the results are open")

        button.performClick(nil)
        XCTAssertTrue(drawer.isHidden, "the button closes the results")
        XCTAssertEqual(button.state, .off)

        button.performClick(nil)
        XCTAssertFalse(drawer.isHidden, "the button reopens the results a person closed")
        XCTAssertEqual(button.state, .on)
        XCTAssertEqual(drawer.blastResultsTab.emptyStateDetailText, "NCBI BLAST did not return a result.")
    }

    /// R12. A merged result keeps no reads of its own, so BLAST falls back to the sample's BAM, which is missing here.
    /// The results pane opens and says why, like the other five viewers. At the base NAO-MGS beeped and showed an
    /// alert titled BLAST Verify Unavailable.
    func testBlastThatCannotStartSaysWhyInTheResultsPane() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("naomgs-result-actions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("hits.sqlite")
        do {
            _ = try NaoMgsDatabase.create(at: url, hits: [Self.hit(read: 1), Self.hit(read: 2)])
        }
        try Self.execute("DELETE FROM virus_hits", in: url)
        let database = try NaoMgsDatabase(at: url)
        let manifest = NaoMgsManifest(
            sampleName: "sample-A", sourceFilePath: "/tmp/naomgs.tsv", hitCount: 2,
            taxonCount: 1, topTaxon: "Taxon 0", topTaxonId: 1_000
        )

        let vc = NaoMgsResultViewController()
        isolateLayouts(vc)
        vc.testDisableMiniBAMLoading = true
        var submitted = 0
        vc.onBlastVerification = { _, _, _ in submitted += 1 }
        vc.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 480)
        let window = NSWindow(contentRect: vc.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = vc.view
        defer {
            window.attachedSheet.map { window.endSheet($0) }
            window.orderOut(nil)
            window.contentView = nil
        }
        vc.configure(database: database, manifest: manifest, bundleURL: root)
        XCTAssertTrue(
            waitUntilOnRunLoop(budget: .lookup) { vc.testDisplayedTaxonOrder.count == 1 },
            "the taxon table did not load"
        )

        vc.testingVerifyWithBlast(row: 0, readCount: 5)

        XCTAssertEqual(submitted, 0, "nothing can be submitted without the reads")
        XCTAssertNil(window.attachedSheet, "no alert, the results pane says why")
        let drawer = try XCTUnwrap(vc.testBlastDrawerContainer, "the BLAST results open to say why BLAST could not start")
        XCTAssertFalse(drawer.isHidden)
        let words = drawer.blastResultsTab.emptyStateDetailText
        XCTAssertTrue(words.contains("could not be found"), words)
    }

    /// SF1 of the UX review of lane ADOPT. Verify with BLAST first reads the taxon's reads out of the result database.
    /// When that lookup threw, the viewer only logged, so the button did nothing and said nothing. The results pane now
    /// opens and says the lookup failed. The hits table is dropped after the viewer opened the database, since opening
    /// a database checks that the table exists.
    func testBlastWhoseReadLookupFailsSaysWhyInTheResultsPane() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("naomgs-result-actions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("hits.sqlite")
        do {
            _ = try NaoMgsDatabase.create(at: url, hits: [Self.hit(read: 1), Self.hit(read: 2)])
        }
        let database = try NaoMgsDatabase(at: url)
        let manifest = NaoMgsManifest(
            sampleName: "sample-A", sourceFilePath: "/tmp/naomgs.tsv", hitCount: 2,
            taxonCount: 1, topTaxon: "Taxon 0", topTaxonId: 1_000
        )

        let vc = NaoMgsResultViewController()
        isolateLayouts(vc)
        vc.testDisableMiniBAMLoading = true
        var submitted = 0
        vc.onBlastVerification = { _, _, _ in submitted += 1 }
        vc.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 480)
        let window = NSWindow(contentRect: vc.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = vc.view
        defer {
            window.attachedSheet.map { window.endSheet($0) }
            window.orderOut(nil)
            window.contentView = nil
        }
        vc.configure(database: database, manifest: manifest, bundleURL: root)
        XCTAssertTrue(
            waitUntilOnRunLoop(budget: .lookup) { vc.testDisplayedTaxonOrder.count == 1 },
            "the taxon table did not load"
        )
        try Self.execute("DROP TABLE virus_hits", in: url)
        // An open handle learns of a schema change made through another connection when it next runs a statement.
        // Until then it prepares the lookup against the table it remembers, and the lookup reads as no rows.
        _ = try database.fetchSamples()

        vc.testingVerifyWithBlast(row: 0, readCount: 5)

        XCTAssertEqual(submitted, 0, "nothing can be submitted without the reads")
        XCTAssertNil(window.attachedSheet, "no alert, the results pane says why")
        let drawer = try XCTUnwrap(
            vc.testBlastDrawerContainer, "the BLAST results open to say why the reads could not be read"
        )
        XCTAssertFalse(drawer.isHidden)
        let words = drawer.blastResultsTab.emptyStateDetailText
        XCTAssertTrue(words.hasPrefix("Reading this taxon's reads from the result database failed"), words)
    }

    // MARK: - Fixture

    private static func blastResultsButton(in bar: ClassifierActionBar) throws -> NSButton {
        try XCTUnwrap(
            buttons(in: bar).first { $0.accessibilityIdentifier() == "classifier-result-blast-results" },
            "NAO-MGS's bar has no BLAST Results button of the shared component"
        )
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { subview -> [NSButton] in
            (subview as? NSButton).map { [$0] } ?? buttons(in: subview)
        }
    }

    private static func execute(_ sql: String, in url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(db) }
        // The viewer's read handle may still be open on this file, so a schema change waits for its reader to finish.
        sqlite3_busy_timeout(db, 5_000)
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func hit(read: Int) -> NaoMgsVirusHit {
        NaoMgsVirusHit(
            sample: "sample-A", seqId: "read-\(read)", taxId: 1_000,
            bestAlignmentScore: 120, cigar: "100M", queryStart: 0, queryEnd: 100,
            refStart: read * 100, refEnd: read * 100 + 100,
            readSequence: String(repeating: "A", count: 100), readQuality: String(repeating: "I", count: 100),
            subjectSeqId: "NC_000001.1", subjectTitle: "Taxon 0 genome",
            bitScore: 200, eValue: 1e-50, percentIdentity: 99, editDistance: 1,
            fragmentLength: 300, isReverseComplement: false, pairStatus: "CP", queryLength: 100
        )
    }
}
