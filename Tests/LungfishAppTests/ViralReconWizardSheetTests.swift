import XCTest
@testable import LungfishApp

final class ViralReconWizardSheetTests: XCTestCase {
    func testFourVisibleControlsWhenPlatformDetected() {
        let controls = ViralReconWizardSheet.visibleControls(platformDetected: true)
        XCTAssertEqual(controls, [.inputs, .primerScheme, .minimumMappedReads, .readiness])
    }

    func testPlatformControlAppearsOnlyWhenDetectionFails() {
        let controls = ViralReconWizardSheet.visibleControls(platformDetected: false)
        XCTAssertTrue(controls.contains(.platform))
        XCTAssertEqual(controls.first, .inputs)
    }

    func testNoReferenceOrExecutorControlIsOffered() {
        for detected in [true, false] {
            let controls = ViralReconWizardSheet.visibleControls(platformDetected: detected)
            XCTAssertFalse(controls.contains(.reference))
            XCTAssertFalse(controls.contains(.executor))
        }
    }

    /// A silent default to the first scheme alphabetically trims with the
    /// wrong primers; the picker starts with no selection.
    func testPrimerSchemePickerStartsWithNoSelection() {
        let available = ["file:///schemes/artic-v3", "file:///schemes/artic-v5.3.2", "file:///schemes/midnight"]
        XCTAssertEqual(ViralReconWizardPrimerSelectionPolicy.initialSelection(previous: "", availableIDs: available), "")
        XCTAssertEqual(
            ViralReconWizardPrimerSelectionPolicy.initialSelection(previous: "file:///schemes/midnight", availableIDs: available),
            "file:///schemes/midnight",
            "a scheme the user already chose is kept while it is still on offer"
        )
        XCTAssertEqual(
            ViralReconWizardPrimerSelectionPolicy.initialSelection(previous: "file:///schemes/removed", availableIDs: available),
            "",
            "a choice that is no longer available is not replaced by a guess"
        )
        XCTAssertEqual(ViralReconWizardPrimerSelectionPolicy.initialSelection(previous: "", availableIDs: []), "")
    }

    func testRunStaysBlockedUntilAPrimerSchemeIsChosen() {
        let evaluation = ViralReconWizardReadiness.evaluate(
            ViralReconWizardReadiness.State(
                hasInputFiles: true,
                effectivePlatform: .illumina,
                inputError: nil,
                primerManifest: nil,
                outputRootAvailable: true,
                minimumMappedReads: 1000
            )
        )
        XCTAssertFalse(evaluation.canRun)
        XCTAssertEqual(evaluation.message, "Select a SARS-CoV-2 primer scheme.")
    }

    func testAdvancedFieldParsesKeyValuePairs() {
        let known: Set<String> = ["variant_caller", "min_mapped_reads"]
        let result = ViralReconWizardSheet.parseAdvancedParameters(
            "--variant_caller bcftools --min_mapped_reads 500", knownParameters: known)
        guard case .success(let params) = result else { return XCTFail("expected success") }
        XCTAssertEqual(params["variant_caller"], "bcftools")
        XCTAssertEqual(params["min_mapped_reads"], "500")
    }

    func testAdvancedFieldRejectsUnknownParameterByName() {
        let result = ViralReconWizardSheet.parseAdvancedParameters(
            "--varient_caller bcftools", knownParameters: ["variant_caller"])
        guard case .failure(let message) = result else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("varient_caller"), message)
    }

    func testAdvancedFieldRejectsStructuralParameterNamingTheOwningControl() {
        let result = ViralReconWizardSheet.parseAdvancedParameters(
            "--primer_bed /tmp/x.bed", knownParameters: ["primer_bed"])
        guard case .failure(let message) = result else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("primer_bed"), message)
    }

    func testEmptyAdvancedFieldSucceeds() {
        let result = ViralReconWizardSheet.parseAdvancedParameters("", knownParameters: [])
        guard case .success(let params) = result else { return XCTFail("expected success") }
        XCTAssertTrue(params.isEmpty)
    }

    // The two Freyja skips are forced by the pipeline's container pin, so the
    // advanced field must not be a way back to them.
    func testAdvancedFieldRejectsTheForcedFreyjaSkips() {
        for name in ["skip_freyja", "skip_freyja_boot"] {
            let result = ViralReconWizardSheet.parseAdvancedParameters(
                "--\(name) false", knownParameters: [name])
            guard case .failure(let message) = result else {
                return XCTFail("expected \(name) to be refused")
            }
            XCTAssertTrue(message.contains(name), message)
        }
    }

    func testAdvancedFieldOverridesTuningKeysTheWizardNoLongerShows() {
        let known: Set<String> = ["skip_fastqc", "max_cpus", "consensus_caller"]
        let result = ViralReconWizardSheet.parseAdvancedParameters(
            "--skip_fastqc true --max_cpus 2 --consensus_caller ivar", knownParameters: known)
        guard case .success(let params) = result else { return XCTFail("expected success") }
        XCTAssertEqual(params["skip_fastqc"], "true")
        XCTAssertEqual(params["max_cpus"], "2")
        XCTAssertEqual(params["consensus_caller"], "ivar")
    }
}
