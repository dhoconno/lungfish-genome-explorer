import XCTest
@testable import LungfishApp

final class TaxTriageWizardSheetTests: XCTestCase {
    func testStandalonePresentationUsesSharedWizardShellContract() {
        let presentation = TaxTriageStandalonePresentation(
            initialFileCount: 1,
            inputDisplayName: "sample-a",
            sampleCount: 1,
            canRun: false,
            validationMessage: "Checking prerequisites..."
        )

        XCTAssertEqual(presentation.title, "TaxTriage")
        XCTAssertEqual(presentation.subtitle, "End-to-end pathogen detection for metagenomic samples")
        XCTAssertEqual(presentation.accessoryText, "sample-a")
        XCTAssertEqual(presentation.size.width, 520)
        XCTAssertEqual(presentation.size.height, 520)
        XCTAssertEqual(presentation.statusText, "Checking prerequisites...")
        XCTAssertFalse(presentation.isPrimaryEnabled)
    }

    func testStandalonePresentationSummarizesMultipleSamplesWhenReady() {
        let presentation = TaxTriageStandalonePresentation(
            initialFileCount: 2,
            inputDisplayName: "2 FASTQ files",
            sampleCount: 2,
            canRun: true,
            validationMessage: nil
        )

        XCTAssertEqual(presentation.accessoryText, "2 samples")
        XCTAssertNil(presentation.statusText)
        XCTAssertTrue(presentation.isPrimaryEnabled)
    }

    func testAdvancedArgumentsParseErrorDetectsUnterminatedQuote() {
        // Regression test for AS31: performRun() silently no-ops when
        // extraArgumentsText fails to parse, but canRun previously never
        // checked parseability, leaving Run enabled with zero feedback.
        XCTAssertNil(TaxTriageWizardSheet.advancedArgumentsParseError("--flag value"))
        XCTAssertNil(TaxTriageWizardSheet.advancedArgumentsParseError(""))
        XCTAssertNotNil(TaxTriageWizardSheet.advancedArgumentsParseError("--flag 'unterminated"))
    }
}
