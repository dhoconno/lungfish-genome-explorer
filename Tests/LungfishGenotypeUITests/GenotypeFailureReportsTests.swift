// GenotypeFailureReportsTests.swift - The genotype result view's failure alerts (ALERT-PRESENTER)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishKit
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeFailureReportsTests: XCTestCase {
    private let raw = "posix_spawn ENOENT /tmp/x.lock"

    private func rawError() -> NSError {
        NSError(domain: "ALERTTestDomain", code: 7, userInfo: [NSLocalizedDescriptionKey: raw])
    }

    /// The title names the step, the body holds no raw text, the details hold it, and the words keep the prose rules.
    private func assertPlainWords(_ report: FailureReport, title: String, file: StaticString = #filePath, line: UInt = #line) {
        let alert = FailurePresenter.alert(for: report)
        XCTAssertEqual(alert.messageText, title, file: file, line: line)
        XCTAssertFalse(alert.informativeText.contains(raw), "raw error text stays out of the body", file: file, line: line)
        let details = alert.accessoryView as? FailureDetailsView
        XCTAssertEqual(details?.textView.string.contains(raw), true, file: file, line: line)
        for text in [report.title, report.whatHappened, report.nextStep] {
            XCTAssertFalse(text.contains("\u{2014}") || text.contains(";") || text.contains(":"), "prose rule in \(text)", file: file, line: line)
        }
    }

    func testExportGenotypeView() {
        let report = GenotypeFailureReports.exportGenotypeView(rawError())
        assertPlainWords(report, title: "Could not export the genotype view")
        XCTAssertFalse(report.nextStep.contains("Operations panel"))
    }

    func testExportGenotypeViewFromTheExportCommandPointsToTheOperationsLog() {
        let report = GenotypeFailureReports.exportGenotypeView(CLIViewerExportRunner.Failure(message: raw))
        assertPlainWords(report, title: "Could not export the genotype view")
        XCTAssertTrue(report.nextStep.contains("Operations panel"))
    }

    func testExportManualHaplotypeDefinitions() {
        let report = GenotypeFailureReports.exportManualHaplotypeDefinitions(rawError())
        assertPlainWords(report, title: "Could not export the manual haplotype definitions")
        XCTAssertFalse(report.nextStep.contains("Operations panel"))
    }

    func testExportManualHaplotypeDefinitionsFromTheExportCommandPointsToTheOperationsLog() {
        let report = GenotypeFailureReports.exportManualHaplotypeDefinitions(CLIViewerExportRunner.Failure(message: raw))
        assertPlainWords(report, title: "Could not export the manual haplotype definitions")
        XCTAssertTrue(report.nextStep.contains("Operations panel"))
    }
}
