import Foundation
import XCTest
@testable import LungfishApp

@MainActor
final class UnifiedClassifierRunnerTests: XCTestCase {
    func testAnalysisTypeTitlesMatchSharedRunnerContract() {
        XCTAssertEqual(UnifiedMetagenomicsWizard.AnalysisType.classification.sidebarTitle, "Kraken2")
        XCTAssertEqual(UnifiedMetagenomicsWizard.AnalysisType.viralDetection.sidebarTitle, "EsViritu")
        XCTAssertEqual(UnifiedMetagenomicsWizard.AnalysisType.clinicalTriage.sidebarTitle, "TaxTriage")

        XCTAssertEqual(UnifiedMetagenomicsWizard.AnalysisType.classification.runnerTitle, "Kraken2")
        XCTAssertEqual(UnifiedMetagenomicsWizard.AnalysisType.viralDetection.runnerTitle, "EsViritu")
        XCTAssertEqual(UnifiedMetagenomicsWizard.AnalysisType.clinicalTriage.runnerTitle, "TaxTriage")
    }

    func testSharedSectionOrderMatchesRunnerShellContract() {
        XCTAssertEqual(
            UnifiedMetagenomicsWizard.sharedSectionOrder,
            ["Overview", "Prerequisites", "Samples", "Database", "Tool Settings", "Advanced Settings"]
        )
    }

    func testInitialSelectionIsSeededForTesting() {
        let wizard = UnifiedMetagenomicsWizard(inputFiles: [], initialSelection: .clinicalTriage)
        XCTAssertEqual(wizard.testingInitialSelection, .clinicalTriage)
        XCTAssertEqual(wizard.testingSidebarSelection, .clinicalTriage)
    }

    func testWizardSourceUsesRunnerShellTermsOnly() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/Views/Metagenomics/UnifiedMetagenomicsWizard.swift")

        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("WizardStep"))
        XCTAssertFalse(source.contains("analysisTypeSelector"))
    }
}
