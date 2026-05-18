import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class AssemblyWizardSheetTests: XCTestCase {
    func testUnknownReadTypeDefaultsAreTreatedAsCurrentManualSelection() {
        XCTAssertTrue(AssemblyWizardSheet.initialManualReadTypeConfirmationState())
        XCTAssertEqual(
            AssemblyWizardSheet.detectedReadTypeSummary(
                compatibilityBlockingMessage: nil,
                resolvedReadType: nil
            ),
            "No single read class detected. Review the selected read type below."
        )
    }

    func testRunRequiresManagedAssemblyToolReadiness() {
        let blocked = AssemblyWizardRunPresentation(
            hasInputFiles: true,
            hasOutputDirectory: true,
            projectName: "Demo",
            requiresManualReadTypeConfirmation: false,
            hasConfirmedManualReadType: true,
            advancedOptionsParseError: nil,
            compatibilityPresentation: AssemblyCompatibilityPresentation(
                tool: .spades,
                readType: .illuminaShortReads,
                packReady: true,
                toolReady: false,
                blockingMessage: nil
            ),
            configurationBlockingMessage: nil
        )

        XCTAssertFalse(blocked.canRun)
        XCTAssertEqual(blocked.validationMessage, "SPAdes is not ready in the Genome Assembly pack yet.")
    }

    func testAssemblySheetUsesExtraArgumentsWording() {
        XCTAssertEqual(AssemblyWizardSheet.advancedDisclosureTitle, "Curated extra arguments")
        XCTAssertEqual(AssemblyWizardSheet.extraArgumentsFieldTitle, "Extra arguments")
    }

    func testHifiasmProfilesDefaultToDiploidAndExposeHaploidViral() {
        let options = AssemblyWizardSheet.profileOptions(for: .hifiasm)

        XCTAssertEqual(AssemblyWizardSheet.defaultProfileID(for: .hifiasm), "diploid")
        XCTAssertEqual(options.map(\.id), ["diploid", "haploid-viral"])
        XCTAssertEqual(
            AssemblyWizardSheet.curatedAdvancedArguments(
                for: .hifiasm,
                spadesCareful: false,
                spadesSkipErrorCorrection: false,
                flyeMetagenomeMode: false,
                hifiasmPrimaryOnly: true
            ),
            ["--primary"]
        )
        XCTAssertEqual(
            AssemblyWizardSheet.curatedAdvancedArguments(
                for: .hifiasm,
                spadesCareful: false,
                spadesSkipErrorCorrection: false,
                flyeMetagenomeMode: false,
                hifiasmPrimaryOnly: false
            ),
            []
        )
    }
}
