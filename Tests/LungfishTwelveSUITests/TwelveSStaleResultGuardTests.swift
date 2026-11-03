// TwelveSStaleResultGuardTests.swift - A result replaced on disk is not exported, and a failed read shows words
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane STALE12S, ruling BIO-12S-STALE-EXPORT.
//
// Fix B. The viewer's file Export asks the leaf to read the bundle on disk, and the leaf takes no rows from the
// screen. If another run replaced the result under the same name after the viewer opened it, the file would hold
// the new result's numbers under the old result's title. The viewer therefore compares the result tables it
// opened (the size and modification time of each table the export reads) with the tables on disk when the save
// panel answers, and refuses in words when they differ. It does not compare the bundle's run record, since a
// metadata import replaces that file and a metadata edit appends to it (SampleMetadataBundleImportService), which
// would refuse a healthy result.
//
// Fix C. The first click on Unresolved reads the unresolved table. A read that fails, or a table the manifest
// names that is not on disk, shows words, leaves the table empty and lets a later click read it again.

import AppKit
import XCTest
@testable import LungfishCore
import LungfishKit
import LungfishTestSupport
@testable import LungfishIO
@testable import LungfishTwelveSUI

@MainActor
private final class StaleGuardFailureSpy: ExportFailurePresenting {
    private(set) var messages: [String] = []

    func presentExportFailure(title: String, message: String, in window: NSWindow?) {
        messages.append(message)
    }
}

@MainActor
final class TwelveSStaleResultGuardTests: XCTestCase {
    private var folder: URL!

    private static let header = "sequence_id\tsequence\tread_count\tsample_counts\tchimera_status\tnote\n"
    private static let unresolvedTable = header
        + "unresolved_1\tACGTACGT\t20\tSampleA:20\tcandidate\t\n"
        + "unresolved_2\tTGCATGCA\t10\tSampleA:10\tnot_detected\t\n"

    override func setUpWithError() throws {
        folder = try TestTempDirectory.make(prefix: "twelve-s-stale")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(folder)
    }

    // MARK: - Fix B, the file Export

    /// Another run replaced a result table after the viewer opened the result. The save panel answered, and no row
    /// begins, no file is written and the person reads why.
    func testExportRefusesAfterAResultTableChanged() throws {
        let opened = try openResult(unresolvedTable: Self.unresolvedTable, loadUnresolvedRows: true)
        let snapshot = try XCTUnwrap(opened.controller.exportSnapshot())
        let output = folder.appendingPathComponent("replaced.csv")
        let known = Set(OperationCenter.shared.items.map(\.id))
        try "the counts of another run\n".write(
            to: opened.bundle.appendingPathComponent("sample-target-counts.tsv"), atomically: true, encoding: .utf8
        )

        let begun = opened.controller.exportAfterSavePanel(
            snapshot: snapshot, format: .csv, outputURL: output, runner: Self.failingRunner
        )

        XCTAssertNil(begun, "no row begins")
        XCTAssertEqual(opened.presenter.messages.count, 1, "the person reads one message")
        let words = opened.presenter.messages.first ?? ""
        XCTAssertTrue(words.contains("changed on disk"), words)
        XCTAssertTrue(words.contains("No file was written"), words)
        XCTAssertTrue(words.contains("replaced.csv"), "the message names the file: \(words)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(exportRows(since: known).count, 0, "no Operations row began")
    }

    /// The false-refusal guard. A result nothing replaced exports as before.
    func testExportGoesAheadWhenTheResultTablesAreUnchanged() async throws {
        let opened = try openResult(unresolvedTable: Self.unresolvedTable, loadUnresolvedRows: true)
        try await assertTheExportBegins(opened)
    }

    /// The false-refusal guard for the edit a person makes in the app. A metadata import replaces the bundle's run
    /// record, and a metadata edit appends to it. Neither changes a result table, so the export goes ahead.
    func testExportGoesAheadAfterTheRunRecordIsRewrittenByAMetadataImport() async throws {
        let opened = try openResult(unresolvedTable: Self.unresolvedTable, loadUnresolvedRows: true)
        try #"{"workflowName":"Sample metadata import"}"#.write(
            to: opened.bundle.appendingPathComponent(".lungfish-provenance.json"), atomically: true, encoding: .utf8
        )
        try await assertTheExportBegins(opened)
    }

    private func assertTheExportBegins(
        _ opened: (controller: TwelveSAmpliconResultViewController, bundle: URL, presenter: StaleGuardFailureSpy)
    ) async throws {
        let snapshot = try XCTUnwrap(opened.controller.exportSnapshot())
        let known = Set(OperationCenter.shared.items.map(\.id))
        let begun = try XCTUnwrap(
            opened.controller.exportAfterSavePanel(
                snapshot: snapshot, format: .csv, outputURL: folder.appendingPathComponent("out.csv"),
                runner: Self.failingRunner
            ),
            "the export row begins"
        )
        defer { OperationCenter.shared.clearItem(id: begun.operationID) }
        XCTAssertEqual(exportRows(since: known).count, 1)
        _ = await begun.task.value
        XCTAssertFalse(
            opened.presenter.messages.contains { $0.contains("changed on disk") },
            "the stand-in leaf fails, and the only message is its failure: \(opened.presenter.messages)"
        )
    }

    // MARK: - Fix C, the unresolved table

    /// A table that cannot be read shows words, leaves the rows empty and is read again on the next click.
    func testAnUnreadableUnresolvedTableShowsWordsAndIsReadAgainOnTheNextClick() throws {
        let opened = try openResult(unresolvedTable: nil, loadUnresolvedRows: false)
        let table = opened.bundle.appendingPathComponent("unresolved-sequences.tsv")
        try FileManager.default.createDirectory(at: table, withIntermediateDirectories: false)

        opened.controller.showUnresolvedForTesting()

        XCTAssertEqual(opened.presenter.messages.count, 1, "the failure shows words")
        let words = opened.presenter.messages.first ?? ""
        XCTAssertTrue(words.contains("could not be read"), words)
        XCTAssertTrue(words.contains("does not mean"), "the words say an empty table is not none: \(words)")
        XCTAssertNil(opened.controller.testingUnresolvedSequenceID(at: 0), "the table stays empty")

        try FileManager.default.removeItem(at: table)
        try Self.unresolvedTable.write(to: table, atomically: true, encoding: .utf8)
        opened.controller.showUnresolvedForTesting()

        XCTAssertEqual(opened.controller.testingUnresolvedSequenceID(at: 0), "unresolved_1", "a later click reads it")
        XCTAssertEqual(opened.presenter.messages.count, 1, "no second message once it reads")
    }

    /// The manifest names a table that is not on disk, which the loader reads as no sequences.
    func testAMissingUnresolvedTableShowsWords() throws {
        let opened = try openResult(unresolvedTable: nil, loadUnresolvedRows: false)

        opened.controller.showUnresolvedForTesting()

        XCTAssertEqual(opened.presenter.messages.count, 1, "the missing table shows words")
        XCTAssertTrue((opened.presenter.messages.first ?? "").contains("could not be read"))
        XCTAssertNil(opened.controller.testingUnresolvedSequenceID(at: 0))
    }

    /// The false-alarm guard. A result with no unresolved sequences has a table with a header only, and shows no words.
    func testAnUnresolvedTableWithNoRowsShowsNoWords() throws {
        let opened = try openResult(unresolvedTable: Self.header, loadUnresolvedRows: false)

        opened.controller.showUnresolvedForTesting()

        XCTAssertEqual(opened.presenter.messages, [])
        XCTAssertNil(opened.controller.testingUnresolvedSequenceID(at: 0))
    }

    // MARK: - Fixtures

    /// A leaf that fails at once, so a test needs no `lungfish-cli` and a begun row ends quickly.
    private static var failingRunner: CLIViewerExportRunner {
        CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false"))
    }

    private func exportRows(since known: Set<UUID>) -> [OperationCenter.Item] {
        OperationCenter.shared.items.filter { $0.title == "Export 12S Results" && !known.contains($0.id) }
    }

    /// A viewer opened on a bundle folder that holds every table the manifest names. The tables hold text only,
    /// since the viewer reads their stamps and the stand-in leaf reads nothing.
    private func openResult(
        unresolvedTable: String?,
        loadUnresolvedRows: Bool
    ) throws -> (controller: TwelveSAmpliconResultViewController, bundle: URL, presenter: StaleGuardFailureSpy) {
        let bundle = folder.appendingPathComponent("fixture.lungfish12s", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for name in ["targets.tsv", "sample-target-counts.tsv", "samples.tsv", "read-fate.json", ".lungfish-provenance.json"] {
            try "the \(name) of the run\n".write(
                to: bundle.appendingPathComponent(name), atomically: true, encoding: .utf8
            )
        }
        if let unresolvedTable {
            try unresolvedTable.write(
                to: bundle.appendingPathComponent("unresolved-sequences.tsv"), atomically: true, encoding: .utf8
            )
        }
        let controller = TwelveSAmpliconResultViewController()
        let presenter = StaleGuardFailureSpy()
        controller.exportFailurePresenter = presenter
        _ = controller.view
        controller.configure(
            result: TwelveSFixtures.twoSampleResult(bundleURL: bundle, loadUnresolvedRows: loadUnresolvedRows)
        )
        return (controller, bundle, presenter)
    }
}
