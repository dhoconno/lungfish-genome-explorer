// DatabaseBrowserFailureReportsTests.swift - The database browser's failure alert (ALERT-PRESENTER)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishKit
import XCTest
@testable import LungfishApp

@MainActor
final class DatabaseBrowserFailureReportsTests: XCTestCase {
    private let raw = "ALERTTest raw error text"

    private func assertAlert(
        _ error: any Error, body: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let alert = FailurePresenter.alert(for: DatabaseBrowserFailureReports.importAccessionList(error))
        XCTAssertEqual(alert.messageText, "Could not import the accession list", file: file, line: line)
        XCTAssertEqual(alert.informativeText, body, file: file, line: line)
        XCTAssertEqual(
            (alert.accessoryView as? FailureDetailsView)?.textView.string.contains(error.localizedDescription), true,
            "the error's own text goes to the details", file: file, line: line
        )
    }

    func testARefusalWhileADownloadRunsSaysSoAndNamesTheWait() {
        assertAlert(
            DatabaseServiceError.invalidQuery(reason: DatabaseBrowserFailureReports.downloadRunning),
            body: "A download is still running, so the accession list was not imported.\n\n"
                + "Wait for the download to finish, then import the accession list again."
        )
    }

    func testAFileWithNoSRAAccessionsKeepsTheBrowsersSentence() {
        assertAlert(
            DatabaseServiceError.invalidQuery(reason: DatabaseBrowserFailureReports.noSRAAccessions),
            body: "No valid SRA accessions were found in the selected file.\n\n"
                + "Check that the file lists SRA run accessions, then import it again."
        )
    }

    func testAnAccessionListInTheWrongSearchModeNamesTheModes() {
        assertAlert(
            DatabaseServiceError.invalidQuery(reason: DatabaseBrowserFailureReports.wrongSearchMode),
            body: "Accession lists are supported in SRA Runs and GenBank Nucleotide mode.\n\n"
                + "Switch to SRA Runs or GenBank Nucleotide search, then import the accession list again."
        )
    }

    func testAnyOtherRefusalKeepsItsSentenceAndNamesTheFileAndTheSearchType() {
        assertAlert(
            DatabaseServiceError.invalidQuery(reason: raw),
            body: "\(raw)\n\nCheck the file and the search type, then import the accession list again."
        )
    }

    func testAnyOtherErrorIsWordedInGeneralTermsAndKeepsItsTextOutOfTheBody() {
        let error = NSError(domain: "ALERTTestDomain", code: 7, userInfo: [NSLocalizedDescriptionKey: raw])
        assertAlert(
            error,
            body: "Lungfish could not read the accession list, so nothing was imported.\n\n"
                + "Check that the file can be read and holds a list of accessions, then import it again."
        )
    }
}
