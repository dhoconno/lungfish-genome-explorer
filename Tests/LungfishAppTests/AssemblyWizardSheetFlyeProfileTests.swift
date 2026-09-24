import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class AssemblyWizardSheetFlyeProfileTests: XCTestCase {
    private let rawSelection = FlyeProfileSelector.selection(readQuality: 7.9, basis: .bundleStatistics)
    private let hqSelection = FlyeProfileSelector.selection(readQuality: 12, basis: .sampledReads, sampledReadCount: 500)

    func testFlyeProfileSeedsFromTheReadQualitySelection() {
        XCTAssertEqual(AssemblyWizardSheet.seededProfileID(for: .flye, flyeSelection: rawSelection), "nano-raw")
        XCTAssertEqual(AssemblyWizardSheet.seededProfileID(for: .flye, flyeSelection: hqSelection), "nano-hq")
    }

    func testFlyeProfileFallsBackToNanoHQBeforeAnyMeasurement() {
        XCTAssertEqual(AssemblyWizardSheet.seededProfileID(for: .flye, flyeSelection: nil), "nano-hq")
        XCTAssertEqual(AssemblyWizardSheet.defaultProfileID(for: .flye), "nano-hq")
    }

    func testOtherToolsIgnoreTheFlyeSelection() {
        XCTAssertEqual(AssemblyWizardSheet.seededProfileID(for: .hifiasm, flyeSelection: rawSelection), "diploid")
        XCTAssertEqual(AssemblyWizardSheet.seededProfileID(for: .spades, flyeSelection: rawSelection), "isolate")
        XCTAssertNil(AssemblyWizardSheet.profileSelectionBasis(for: .hifiasm, selectedProfileID: "diploid", flyeSelection: rawSelection))
    }

    func testReadQualityIsMeasuredOnlyForSingleOntOrFlyeInputs() {
        XCTAssertTrue(AssemblyWizardSheet.shouldSeedFlyeProfile(inputCount: 1, initialTool: .flye, detectedReadType: nil))
        XCTAssertTrue(AssemblyWizardSheet.shouldSeedFlyeProfile(inputCount: 1, initialTool: .hifiasm, detectedReadType: .ontReads))
        XCTAssertFalse(AssemblyWizardSheet.shouldSeedFlyeProfile(inputCount: 1, initialTool: .spades, detectedReadType: .illuminaShortReads))
        XCTAssertFalse(AssemblyWizardSheet.shouldSeedFlyeProfile(inputCount: 2, initialTool: .flye, detectedReadType: .ontReads))
    }

    func testProfileBasisRecordsPreselectionAndUserOverride() {
        XCTAssertEqual(
            AssemblyWizardSheet.profileSelectionBasis(for: .flye, selectedProfileID: "nano-raw", flyeSelection: rawSelection),
            "nano-raw preselected from read quality Q8 from the bundle's statistics"
        )
        XCTAssertEqual(
            AssemblyWizardSheet.profileSelectionBasis(for: .flye, selectedProfileID: "nano-hq", flyeSelection: rawSelection),
            "nano-hq chosen by the user; nano-raw was preselected from read quality Q8 from the bundle's statistics"
        )
        XCTAssertNil(AssemblyWizardSheet.profileSelectionBasis(for: .flye, selectedProfileID: "nano-raw", flyeSelection: nil))
    }

    func testCaptionUnderTheProfilePickerSaysWhyItWasChosen() {
        XCTAssertEqual(rawSelection.caption, "Nano Raw preselected: read quality Q8 from the bundle's statistics.")
        XCTAssertEqual(hqSelection.caption, "Nano HQ preselected: median read quality Q12 from the first 500 reads.")
    }

    func testCopyCLICommandCarriesTheResolvedProfile() {
        let request = AssemblyRunRequest(
            tool: .flye,
            readType: .ontReads,
            inputURLs: [URL(fileURLWithPath: "/tmp/HG002.chrM.ont.lungfishfastq")],
            projectName: "HG002.chrM.ont_assembly",
            outputDirectory: URL(fileURLWithPath: "/tmp/Analyses"),
            threads: 8,
            selectedProfileID: rawSelection.profileID,
            profileSelectionBasis: rawSelection.provenanceBasis(appliedProfileID: nil)
        )

        let command = AssemblyRunner.cliCommandPreview(request: request)

        XCTAssertTrue(command.contains("--profile nano-raw"), command)
        XCTAssertTrue(command.contains("--assembler flye"), command)
    }
}
