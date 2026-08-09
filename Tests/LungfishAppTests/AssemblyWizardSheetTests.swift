import XCTest
@testable import LungfishApp
import LungfishKit
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

    // MARK: - MB-2 review round 1: picker gate is tool-based, not read-type-based

    func testMultiBundleRunPolicyLocksToPerBundleOnlyThisRound() {
        // .combined pooling is not implemented this round (see the fix-round-1
        // report); the picker must present exactly one selectable option.
        let rowStates = MultiBundleRunModePicker.rowStates(
            bundleCount: 3,
            policy: MultiBundleRunPolicy(allowedModes: [.perBundle], defaultMode: .perBundle)
        )

        XCTAssertEqual(rowStates.filter(\.isEnabled).map(\.mode), [.perBundle])
        XCTAssertTrue(rowStates.first { $0.mode == .combined }.map { !$0.isEnabled } ?? false)
    }
}
