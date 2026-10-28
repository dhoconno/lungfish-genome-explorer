// MainWindowFailureReportsTests.swift - The main window's failure alerts (ALERT-PRESENTER)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishKit
@testable import LungfishApp

/// Checks one failure alert built by `FailurePresenter.alert(for:)`. The title
/// names the step, the body is two paragraphs with no raw error text, and the
/// error's text is only in the details area.
@MainActor
func assertFailureAlert(
    _ report: FailureReport,
    title: String,
    rawErrorText: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let alert = FailurePresenter.alert(for: report)
    XCTAssertEqual(alert.messageText, title, file: file, line: line)
    let paragraphs = alert.informativeText.components(separatedBy: "\n\n")
    XCTAssertEqual(paragraphs.count, 2, "what happened, then the next step", file: file, line: line)
    XCTAssertTrue(paragraphs.allSatisfy { !$0.isEmpty }, file: file, line: line)
    XCTAssertFalse(alert.informativeText.contains(rawErrorText), "raw error text stays out of the body", file: file, line: line)
    let details = alert.accessoryView as? FailureDetailsView
    XCTAssertNotNil(details, "the error goes to the details area", file: file, line: line)
    XCTAssertEqual(details?.isExpanded, false, file: file, line: line)
    XCTAssertTrue(details?.textView.string.contains(rawErrorText) ?? false, file: file, line: line)
}

/// An error whose text reads like a tool's raw output.
func rawFailureError(_ text: String = "posix_spawn ENOENT /tmp/x.lock") -> NSError {
    NSError(domain: "ALERTTestDomain", code: 7, userInfo: [NSLocalizedDescriptionKey: text])
}

@MainActor
final class MainWindowFailureReportsTests: XCTestCase {
    func testReplaceExistingFASTQBundle() {
        assertFailureAlert(
            MainWindowFailureReports.replaceExistingFASTQBundle(rawFailureError()),
            title: "Could not replace the existing FASTQ bundle",
            rawErrorText: "posix_spawn ENOENT /tmp/x.lock"
        )
    }

    func testImportFASTQFile() {
        assertFailureAlert(
            MainWindowFailureReports.importFASTQFile(rawFailureError()),
            title: "Could not import the FASTQ file",
            rawErrorText: "posix_spawn ENOENT /tmp/x.lock"
        )
    }

    func testImportPairedFASTQFilesNamesTheSample() {
        assertFailureAlert(
            MainWindowFailureReports.importPairedFASTQFiles(sampleName: "S12", rawFailureError()),
            title: "Could not import the FASTQ files of S12",
            rawErrorText: "posix_spawn ENOENT /tmp/x.lock"
        )
    }

    func testSplitONTReadsBySamplePointsToTheOperationsLog() {
        let report = MainWindowFailureReports.splitONTReadsBySample(rawFailureError())
        assertFailureAlert(report, title: "Could not split the ONT reads by sample", rawErrorText: "posix_spawn ENOENT /tmp/x.lock")
        XCTAssertTrue(report.nextStep.contains("Operations panel"))
    }

    func testDemultiplexReadsByBarcodePointsToTheOperationsLog() {
        let report = MainWindowFailureReports.demultiplexReadsByBarcode(rawFailureError())
        assertFailureAlert(report, title: "Could not demultiplex the reads by barcode", rawErrorText: "posix_spawn ENOENT /tmp/x.lock")
        XCTAssertTrue(report.nextStep.contains("Operations panel"))
    }

    func testImportONTRunFolder() {
        assertFailureAlert(
            MainWindowFailureReports.importONTRunFolder(rawFailureError()),
            title: "Could not import the ONT run folder",
            rawErrorText: "posix_spawn ENOENT /tmp/x.lock"
        )
    }

    func testImportVCFFiles() {
        assertFailureAlert(
            MainWindowFailureReports.importVCFFiles(rawFailureError()),
            title: "Could not import the VCF files",
            rawErrorText: "posix_spawn ENOENT /tmp/x.lock"
        )
    }

    func testReadFASTQFile() {
        assertFailureAlert(
            MainWindowFailureReports.readFASTQFile(rawFailureError()),
            title: "Could not read the FASTQ file",
            rawErrorText: "posix_spawn ENOENT /tmp/x.lock"
        )
    }

    func testOpenFileNamesTheFile() {
        assertFailureAlert(
            MainWindowFailureReports.openFile(named: "reads.gb", rawFailureError()),
            title: "Could not open reads.gb",
            rawErrorText: "posix_spawn ENOENT /tmp/x.lock"
        )
    }
}
