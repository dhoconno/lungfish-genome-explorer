// AssemblyContigsNoHeaderTests.swift - A contigs file that holds bytes and no contig is refused, and the strip keeps no stored numbers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane ALERTS (W-30, rulings WALK-UX item 7 and WALK-BIO item 6). ASM-7 case (b) of the walk: a contigs file
// that opens but holds no FASTA header gave the catalog zero rows and no error. No alert came, the strip kept the stored
// Contigs, Total bp and N50 over an empty table, and the action bar said "Select contigs to materialize". A non-empty file
// that yields no contig now gets the refusal of case (a), a file that cannot be opened, and neither case leaves stored
// numbers on the strip. An empty file from an assembler that found nothing is not refused.

import AppKit
import LungfishCore
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishAssemblyUI
@testable import LungfishWorkflow

@MainActor
final class AssemblyContigsNoHeaderTests: XCTestCase {
    private struct CannotOpen: LocalizedError {
        var errorDescription: String? { "Duplicate contig name in FASTA index: contig_7" }
    }

    /// Two lines of plain text, as the walk wrote over a SPAdes `contigs.fasta`. No line starts with `>`.
    private static let plainText = "This file holds two lines of plain text.\nNo line of it starts with a greater-than sign.\n"

    private func makeViewer() -> AssemblyResultViewController {
        _ = NSApplication.shared
        let viewer = AssemblyResultViewController()
        _ = viewer.view
        return viewer
    }

    /// A result whose stored statistics still describe the two contigs it was made from, while its contigs file now holds
    /// `text`. That is the state of the walk: the numbers come from the result's JSON and the table from the file.
    private func makeResult(contigsFileHolds text: String? = nil) throws -> AssemblyResult {
        let result = try makeAssemblyResult()
        let project = result.outputDirectory.deletingLastPathComponent().deletingLastPathComponent()
        addTeardownBlock { try? FileManager.default.removeItem(at: project) }
        if let text {
            try text.write(to: result.contigsPath, atomically: true, encoding: .utf8)
        }
        return result
    }

    private func open(_ result: AssemblyResult, in viewer: AssemblyResultViewController) async {
        viewer.configure(result: result)
        await viewer.loadTask?.value
    }

    // MARK: - Case (b), a file with bytes and no contig

    func testPlainTextContigsRefuseAndClearTheStrip() async throws {
        let result = try makeResult(contigsFileHolds: Self.plainText)
        let viewer = makeViewer()
        var failures: [FailureReport] = []
        viewer.failurePresenter = { failures.append($0) }

        await open(result, in: viewer)

        let failure = try XCTUnwrap(failures.first, "a contigs file with bytes and no contig is refused with words")
        XCTAssertEqual(failures.count, 1, "one alert, not one for each step of the load")
        XCTAssertEqual(
            failure.body,
            AssemblyFailureReports.contigsNotOpened(CannotOpen()).body,
            "the same refusal as a contigs file that cannot be opened (ASM-7 case a)"
        )
        let details = failure.details ?? ""
        XCTAssertTrue(details.contains("contigs.fasta"), "the details name the file: \(details)")
        XCTAssertTrue(details.contains("no contig"), "the details say what the file lacks: \(details)")
        XCTAssertTrue(viewer.testSummaryStrip.isHidden, "no stored Contigs, Total bp or N50 over an empty table")
        XCTAssertTrue(viewer.testContigTableView.displayedRows.isEmpty, "no row on screen")
    }

    func testAFileOfBlankLinesIsRefusedToo() async throws {
        let result = try makeResult(contigsFileHolds: "\n\n\n")
        let viewer = makeViewer()
        var failures: [FailureReport] = []
        viewer.failurePresenter = { failures.append($0) }

        await open(result, in: viewer)

        XCTAssertEqual(failures.count, 1, "three bytes are not an assembler that found nothing")
        XCTAssertTrue(viewer.testSummaryStrip.isHidden)
    }

    // MARK: - An assembler that found nothing

    func testAnEmptyContigsFileFromAnAssemblerThatFoundNothingIsNotRefused() async throws {
        let result = try makeEmptyAssemblyResult(outcome: .completed)
        let project = result.outputDirectory.deletingLastPathComponent().deletingLastPathComponent()
        addTeardownBlock { try? FileManager.default.removeItem(at: project) }
        let viewer = makeViewer()
        var failures: [FailureReport] = []
        viewer.failurePresenter = { failures.append($0) }

        await open(result, in: viewer)

        XCTAssertTrue(failures.isEmpty, "an empty file holds no bytes to refuse: \(failures.map(\.body))")
        XCTAssertFalse(viewer.testSummaryStrip.isHidden, "the stored zero counts are true of an empty file")
        XCTAssertEqual(viewer.testSummaryStrip.value(for: "assembly-result-summary-contigs"), "0")
    }

    // MARK: - Case (a), a file that cannot be opened

    func testAContigsFileThatCannotBeOpenedLeavesNoStoredNumbersEither() async throws {
        let result = try makeResult()
        let viewer = makeViewer()
        viewer.catalogLoader = { _ in throw CannotOpen() }
        var failures: [FailureReport] = []
        viewer.failurePresenter = { failures.append($0) }

        await open(result, in: viewer)

        XCTAssertEqual(failures.count, 1, "the alert of case (a) is unchanged")
        XCTAssertTrue(viewer.testSummaryStrip.isHidden, "no stored Contigs, Total bp or N50 over an empty table")
    }

    // MARK: - The strip comes back

    func testTheStripReturnsForAGoodResultThatFollowsARefusedOne() async throws {
        let broken = try makeResult(contigsFileHolds: Self.plainText)
        let good = try makeResult()
        let viewer = makeViewer()
        viewer.failurePresenter = { _ in }

        await open(broken, in: viewer)
        XCTAssertTrue(viewer.testSummaryStrip.isHidden, "the refused result shows no numbers")

        await open(good, in: viewer)
        XCTAssertFalse(viewer.testSummaryStrip.isHidden, "a result that loads shows its numbers again")
        XCTAssertEqual(viewer.testSummaryStrip.value(for: "assembly-result-summary-contigs"), "2")
    }
}
