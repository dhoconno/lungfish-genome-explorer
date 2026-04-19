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

    func testUnifiedClassifierWizardUsesSharedEmbeddedContractNames() throws {
        let source = try loadSource(at: "Sources/LungfishApp/Views/Metagenomics/UnifiedMetagenomicsWizard.swift")

        XCTAssertTrue(source.contains("embeddedInOperationsDialog: true"))
        XCTAssertTrue(source.contains("embeddedRunTrigger: runnerRunTrigger"))
        XCTAssertTrue(source.contains("onRunnerAvailabilityChange: { runnerCanRun = $0 }"))
        XCTAssertFalse(source.contains("embeddedInUnifiedRunner"))
    }

    func testPresenterUsesUnifiedRunnerPreferredContentSize() throws {
        let source = try loadSource(at: "Sources/LungfishApp/App/AppDelegate.swift")
        XCTAssertTrue(source.contains("wizardPanel.setContentSize(UnifiedMetagenomicsWizard.preferredContentSize)"))
    }

    func testClassifierLaunchRoutingUsesOperationsDialogForClassificationAndUnifiedRunnerForOthers() throws {
        let source = try loadSource(at: "Sources/LungfishApp/App/AppDelegate.swift")

        XCTAssertTrue(source.contains("showFASTQOperationsDialog(sender, initialCategory: .classification)"))
        XCTAssertTrue(source.contains("UnifiedMetagenomicsWizard(inputFiles: bundleURLs, initialSelection: .viralDetection)"))
        XCTAssertTrue(source.contains("UnifiedMetagenomicsWizard(inputFiles: bundleURLs, initialSelection: .clinicalTriage)"))
        XCTAssertFalse(source.contains("UnifiedMetagenomicsWizard(inputFiles: bundleURLs, initialSelection: .classification)"))
        XCTAssertFalse(source.contains("ClassificationWizardSheet("))
        XCTAssertFalse(source.contains("EsVirituWizardSheet("))
        XCTAssertFalse(source.contains("TaxTriageWizardSheet("))
    }

    func testFASTQOperationsDialogRunDispatchesOnlyMappingAndClassifierEmbedsDirectly() throws {
        let source = try loadSource(at: "Sources/LungfishApp/App/AppDelegate.swift")

        XCTAssertTrue(source.contains("if let config = state.pendingMinimap2Config"))
        XCTAssertTrue(source.contains("self.runMinimap2Mapping(config: config)"))
        XCTAssertFalse(source.contains("pendingSPAdesConfig"))
        XCTAssertFalse(source.contains("AssemblyRunner.run(config:"))
        XCTAssertTrue(source.contains("if !state.pendingClassificationConfigs.isEmpty"))
        XCTAssertTrue(source.contains("self.runClassification(configs: state.pendingClassificationConfigs, viewerController: viewerController)"))
        XCTAssertTrue(source.contains("if !state.pendingEsVirituConfigs.isEmpty"))
        XCTAssertTrue(source.contains("self.runEsViritu(configs: state.pendingEsVirituConfigs, viewerController: viewerController)"))
        XCTAssertTrue(source.contains("if let config = state.pendingTaxTriageConfig"))
        XCTAssertTrue(source.contains("self.runTaxTriage(config: config, viewerController: viewerController)"))
    }

    func testFASTQOperationsDialogRoutesDerivativeLaunchesThroughMainSplitExecutionPath() throws {
        let source = try loadSource(at: "Sources/LungfishApp/App/AppDelegate.swift")

        XCTAssertTrue(source.contains("if let request = state.pendingLaunchRequest"))
        XCTAssertTrue(source.contains("runFASTQOperationLaunchRequest("))
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
