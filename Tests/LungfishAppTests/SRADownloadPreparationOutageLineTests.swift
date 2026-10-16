// SRADownloadPreparationOutageLineTests.swift - The words of the SRA preparation's outage line
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// When ENA and NCBI both fail, the preparation still offers the manual settings and logs one line
// at info that says why it could not detect them. The tests read that line from the row's log,
// which is what the Operations panel shows.

import AppKit
import XCTest
import LungfishCore
import LungfishKit
import LungfishTestSupport
@testable import LungfishApp

@MainActor
final class SRADownloadPreparationOutageLineTests: XCTestCase {
    /// The reason the lookup reports when both archives fail, read from the lookup itself.
    private func bothArchivesFailedReason(_ client: any HTTPClient) async -> String {
        do {
            _ = try await SRARunMetadataLookup(ena: ENAService(httpClient: client), ncbi: NCBIService(httpClient: client))
                .lookUpRuns(["SRR9000001"])
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    /// Drives a preparation whose archives are both down to the manual settings sheet and returns
    /// the outage lines of its row's log.
    private func outageLines() async throws -> [OperationLogEntry] {
        let (parent, browser) = SRAPreparationFixtures.makeWindows()
        defer { parent.close() }
        let model = SRAPreparationFixtures.makeModel(client: SRAPreparationUnavailableClient())
        model.downloadPresentationWindow = parent
        model.onDownloadStarted = { parent.endSheet(browser) }
        let id = try SRAPreparationFixtures.startPreparation(model)
        defer { SRAPreparationFixtures.end(id) }
        await waitUntil(timeout: .seconds(10)) { parent.attachedSheet?.contentViewController is FASTQImportConfigSheet }
        XCTAssertTrue(parent.attachedSheet?.contentViewController is FASTQImportConfigSheet,
                      "the manual settings still open when no archive answers")
        let row = try XCTUnwrap(SRAPreparationFixtures.row(id))
        return row.logEntries.filter { $0.message.hasPrefix("Could not detect SRA import settings") }
    }

    func testBothArchivesFailingLogsTheReasonInOneSentenceWithOnePeriod() async throws {
        let reason = await bothArchivesFailedReason(SRAPreparationUnavailableClient())
        XCTAssertTrue(reason.hasSuffix(".") && !reason.hasSuffix(".."),
                      "the two-archive reason already ends with one period: \(reason)")

        let lines = try await outageLines()
        XCTAssertEqual(lines.count, 1)
        let line = try XCTUnwrap(lines.first)
        XCTAssertEqual(line.level, .info)
        XCTAssertEqual(line.message, "Could not detect SRA import settings. \(reason) Choose the settings manually.")
        XCTAssertFalse(line.message.contains(".."), "the reason's period is not doubled")
        XCTAssertFalse(line.message.replacingOccurrences(of: reason, with: "").contains(":"),
                       "the words around the reason hold no colon")
    }

    func testTheReasonEndsInExactlyOnePeriodWhetherTheErrorTextHasOneOrNot() {
        let frame = { (reason: String) in "Could not detect SRA import settings. \(reason) Choose the settings manually." }
        let cases: [(error: String, reason: String)] = [
            ("The Internet connection appears to be offline.", "The Internet connection appears to be offline."),
            ("The Internet connection appears to be offline", "The Internet connection appears to be offline."),
            ("ENA returned HTTP 500 (server error), and NCBI timed out..", "ENA returned HTTP 500 (server error), and NCBI timed out."),
            ("The archive stopped answering...", "The archive stopped answering."),
            ("  The archive stopped answering. \n", "The archive stopped answering."),
            ("Is the archive down?", "Is the archive down?"),
        ]
        for item in cases {
            let line = DatabaseBrowserViewModel.sraOutageLine(reason: item.error)
            XCTAssertEqual(line, frame(item.reason), "error text \(item.error.debugDescription)")
            XCTAssertFalse(line.contains(".."), "error text \(item.error.debugDescription)")
            XCTAssertFalse(line.contains(":"), "error text \(item.error.debugDescription)")
        }
    }

    func testAnEmptyReasonLeavesItsSentenceOut() {
        for empty in ["", " ", ".", " . \n"] {
            XCTAssertEqual(
                DatabaseBrowserViewModel.sraOutageLine(reason: empty),
                "Could not detect SRA import settings. Choose the settings manually.",
                "error text \(empty.debugDescription)")
        }
    }
}
