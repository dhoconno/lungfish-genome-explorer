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

    func testBothArchivesFailingLogsTodaysLineWithTwoPeriodsAndAColon() async throws {
        let reason = await bothArchivesFailedReason(SRAPreparationUnavailableClient())
        XCTAssertTrue(reason.hasSuffix("."), "the two-archive reason already ends with a period: \(reason)")

        let lines = try await outageLines()
        XCTAssertEqual(lines.count, 1)
        let line = try XCTUnwrap(lines.first)
        XCTAssertEqual(line.level, .info)
        XCTAssertEqual(line.message, "Could not detect SRA import settings: \(reason). Choose the settings manually.")
        XCTAssertTrue(line.message.contains(".. "), "today's line shows two periods in a row")
    }
}
