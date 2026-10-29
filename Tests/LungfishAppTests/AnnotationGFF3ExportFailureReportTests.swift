// AnnotationGFF3ExportFailureReportTests.swift - Failure words of the GFF3 annotation export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishKit
@testable import LungfishApp

/// Collects what `startAnnotationGFF3Export` reports, on the main actor.
@MainActor
private final class GFF3ReportBox {
    var completions: [String] = []
    var failures: [FailureReport] = []
}

@MainActor
final class AnnotationGFF3ExportFailureReportTests: XCTestCase {
    private let raw = "posix_spawn ENOENT /tmp/x.selection"

    private func rawError() -> any Error {
        NSError(domain: "RawDomain", code: 7, userInfo: [NSLocalizedDescriptionKey: raw])
    }

    func testPrepareAnnotationExportPointsToTheFolderAndNoOperationsRow() {
        let report = AppFailureReports.prepareAnnotationExport(rawError())
        assertFailureAlert(report, title: "Could not prepare the annotations for export", rawErrorText: raw)
        XCTAssertTrue(report.nextStep.contains("folder you chose"))
        XCTAssertFalse(report.nextStep.contains("Operations panel"))
    }

    func testExportAnnotationsPointsToTheOperationsLog() {
        let report = AppFailureReports.exportAnnotations(rawError())
        assertFailureAlert(report, title: "Could not export the annotations", rawErrorText: raw)
        XCTAssertTrue(report.nextStep.contains("Operations panel"))
    }

    /// A document's annotations are written beside the chosen output before the row begins. When that write fails
    /// the person gets the step that failed, and the error's own text stays out of the body.
    func testAnExportThatCannotWriteItsSelectionReportsTheStepAndKeepsTheRawErrorOutOfTheBody() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gff3-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("blocker")
        try Data("not a folder".utf8).write(to: blocker)
        let box = GFF3ReportBox()
        AppDelegate().startAnnotationGFF3Export(
            annotations: [],
            source: .init(kind: .openDocument, urls: [directory.appendingPathComponent("doc.gb")], name: "doc"),
            outputURL: blocker.appendingPathComponent("out.gff3"),
            report: { title, _ in box.completions.append(title) },
            reportFailure: { box.failures.append($0) }
        )
        XCTAssertEqual(box.completions, [])
        XCTAssertEqual(box.failures.count, 1)
        let report = try XCTUnwrap(box.failures.first)
        assertFailureAlert(report, title: "Could not prepare the annotations for export", rawErrorText: "blocker")
    }
}
