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

    func testClinicalTriageDescriptionUsesPathogenDetectionLanguage() {
        let description = UnifiedMetagenomicsWizard.AnalysisType.clinicalTriage.analysisDescription

        XCTAssertTrue(description.localizedCaseInsensitiveContains("pathogen detection"))
        XCTAssertTrue(description.localizedCaseInsensitiveContains("taxtriage"))
        XCTAssertFalse(description.localizedCaseInsensitiveContains("clinical triage"))
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
        let source = try loadSource(at: "Sources/LungfishApp/Views/Metagenomics/UnifiedMetagenomicsWizard.swift")
        let bodyStart = try XCTUnwrap(source.range(of: "    var body: some View {"))
        let bodyEnd = try XCTUnwrap(source.range(of: "    // MARK: - Runner Sidebar"))
        let bodySource = String(source[bodyStart.upperBound..<bodyEnd.lowerBound])

        XCTAssertTrue(bodySource.contains("runnerSidebar"))
        XCTAssertTrue(bodySource.contains("runnerDetail"))
        XCTAssertTrue(source.contains("footerBar"))
        XCTAssertTrue(source.contains("UnifiedClassifierRunnerSection"))
        XCTAssertFalse(source.contains("WizardStep"))
        XCTAssertFalse(source.contains("analysisTypeSelector"))
    }

    func testPresenterUsesUnifiedRunnerPreferredContentSize() throws {
        let source = try loadSource(at: "Sources/LungfishApp/App/AppDelegate.swift")
        XCTAssertTrue(source.contains("wizardPanel.setContentSize(UnifiedMetagenomicsWizard.preferredContentSize)"))
    }

    func testClassifierLaunchRoutingUsesUnifiedRunnerSelection() throws {
        let source = try loadSource(at: "Sources/LungfishApp/App/AppDelegate.swift")

        XCTAssertTrue(source.contains("UnifiedMetagenomicsWizard(inputFiles: bundleURLs, initialSelection: .classification)"))
        XCTAssertTrue(source.contains("UnifiedMetagenomicsWizard(inputFiles: bundleURLs, initialSelection: .viralDetection)"))
        XCTAssertTrue(source.contains("UnifiedMetagenomicsWizard(inputFiles: bundleURLs, initialSelection: .clinicalTriage)"))
        XCTAssertFalse(source.contains("ClassificationWizardSheet("))
        XCTAssertFalse(source.contains("EsVirituWizardSheet("))
        XCTAssertFalse(source.contains("TaxTriageWizardSheet("))
    }

    private func loadSource(at relativePath: String) throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)

        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
