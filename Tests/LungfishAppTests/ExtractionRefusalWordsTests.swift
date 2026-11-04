// ExtractionRefusalWordsTests.swift - The extraction actions refuse in words and not with a beep (Phase 3.2, UWORDS)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishKit

/// The ten guard beeps of the extraction actions showed no words. Each refusal is now a `FailureReport`, checked here
/// by meaning, so no alert opens in this test and the tier cannot hang.
final class ExtractionRefusalWordsTests: XCTestCase {
    private func allReports() -> [(name: String, report: FailureReport)] {
        let unreadable = CocoaError(.fileReadUnknown)
        return [
            ("no sequence", ExtractionRefusalReports.noSequence(step: "Copy the annotation as FASTA")),
            ("no region", ExtractionRefusalReports.noRegion(step: "Copy the visible region as FASTA")),
            ("no protein", ExtractionRefusalReports.noProtein(step: "Copy the translation as FASTA")),
            ("no document sequence", ExtractionRefusalReports.noDocumentSequence(step: "Extract the region into a bundle")),
            ("nothing loaded", ExtractionRefusalReports.nothingToExtract(selected: 2, leftOut: [])),
            ("none could be extracted", ExtractionRefusalReports.nothingToExtract(
                selected: 1, leftOut: [(name: "geneA", error: unreadable)]
            )),
        ]
    }

    func testEveryRefusalSaysWhatWasMissingAndWhatToTry() {
        for (name, report) in allReports() {
            XCTAssertTrue(report.title.hasPrefix("Could not "), "\(name): the title names the step: \(report.title)")
            XCTAssertTrue(report.whatHappened.hasSuffix("."), "\(name): what happened reads as a sentence: \(report.whatHappened)")
            XCTAssertTrue(
                report.whatHappened.contains("no ") || report.whatHappened.contains("could not")
                    || report.whatHappened.contains("no longer"),
                "\(name): what happened says what was missing: \(report.whatHappened)"
            )
            let firstWord = report.nextStep.split(separator: " ").first.map(String.init) ?? ""
            XCTAssertTrue(
                ["Open", "Select", "Check"].contains(firstWord),
                "\(name): the next step starts with something to do: \(report.nextStep)"
            )
            XCTAssertTrue(report.nextStep.hasSuffix("."), "\(name): the next step reads as a sentence: \(report.nextStep)")
        }
    }

    func testARefusalNamesTheAnnotationsThatCouldNotBeExtracted() {
        let report = ExtractionRefusalReports.nothingToExtract(
            selected: 4,
            leftOut: (1...4).map { (name: "gene\($0)", error: CocoaError(.fileReadUnknown)) }
        )
        XCTAssertTrue(report.whatHappened.contains("\"gene1\", \"gene2\", \"gene3\" and 1 more"), report.whatHappened)
        XCTAssertTrue(report.whatHappened.contains("4 selected annotations"), report.whatHappened)
        XCTAssertNotNil(report.details, "the first error stays behind Show Details")
    }

    func testNoExtractionActionBeepsAnymore() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/Viewer/ViewerViewController+Extraction.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("NSSound.beep()"), "a refusal with no words is S2, so the actions show a report")
    }
}
