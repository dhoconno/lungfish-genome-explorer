import XCTest
import LungfishWorkflow
@testable import LungfishApp

/// The hydrolysis-probe window was CLI-only, so a GUI user could not adjust the
/// probe at all. These check the dialog now sends the same probe rules the CLI does.
@MainActor
final class Primer3ProbeFieldsTests: XCTestCase {

    private func state() -> PrimerDesignDialogState {
        let state = PrimerDesignDialogState(projectURL: nil)
        state.engine = .primer3
        return state
    }

    /// An untouched dialog must send byte-for-byte what `--assay qpcr-probe` sends.
    func testUntouchedProbeFieldsMatchTheSharedPreset() throws {
        let state = state()
        state.chemistry = .hydrolysisProbe
        let probe = try XCTUnwrap(state.probeOptions())
        XCTAssertEqual(probe, Primer3ProbeDefaults.hydrolysisProbe)
        let options = try state.primer3Options()
        XCTAssertEqual(options.probe, Primer3ProbeDefaults.hydrolysisProbe)
    }

    /// Only the hydrolysis-probe assay asks Primer3 for an internal oligo.
    func testNonProbeAssaysSendNoProbeSettings() throws {
        for chemistry in [PrimerDesignChemistry.pcr, .intercalatingDye] {
            let state = state()
            state.chemistry = chemistry
            XCTAssertNil(try state.probeOptions(), "\(chemistry)")
            XCTAssertNil(try state.primer3Options().probe, "\(chemistry)")
        }
    }

    func testEditedProbeFieldsReachThePrimer3Options() throws {
        let state = state()
        state.chemistry = .hydrolysisProbe
        state.probeMinTm = "66"
        state.probeOptTm = "68"
        state.probeMaxTm = "72"
        state.probeMinSize = "22"
        state.probeOptSize = "26"
        state.probeMaxSize = "28"
        state.probeMinGC = "45"
        state.probeOptGC = "55"
        state.probeMaxGC = "70"
        let probe = try XCTUnwrap(state.primer3Options().probe)
        XCTAssertEqual(probe.probeMinTm, 66)
        XCTAssertEqual(probe.probeOptTm, 68)
        XCTAssertEqual(probe.probeMaxTm, 72)
        XCTAssertEqual(probe.probeMinSize, 22)
        XCTAssertEqual(probe.probeOptSize, 26)
        XCTAssertEqual(probe.probeMaxSize, 28)
        XCTAssertEqual(probe.probeMinGC, 45)
        XCTAssertEqual(probe.probeOptGC, 55)
        XCTAssertEqual(probe.probeMaxGC, 70)
        // Rules the dialog does not expose still travel from the preset.
        XCTAssertEqual(probe.probeMaxPolyX, Primer3ProbeDefaults.hydrolysisProbe.probeMaxPolyX)
        XCTAssertEqual(probe.probeMustMatchFivePrime,
                       Primer3ProbeDefaults.hydrolysisProbe.probeMustMatchFivePrime)
    }

    func testProbeFieldsReseedWhenTheAssayChanges() throws {
        let state = state()
        state.chemistry = .hydrolysisProbe
        state.probeOptTm = "69"
        // Leaving and returning reseeds the window from the preset, so probe rules
        // from an earlier edit cannot leak into a fresh assay choice.
        state.chemistry = .pcr
        state.chemistry = .hydrolysisProbe
        XCTAssertEqual(try XCTUnwrap(state.probeOptions()).probeOptTm,
                       Primer3ProbeDefaults.hydrolysisProbe.probeOptTm)
    }

    func testProbeFieldsRejectUnorderedOrOutOfRangeValues() {
        let state = state()
        state.chemistry = .hydrolysisProbe
        state.probeOptTm = "80"  // above the maximum
        XCTAssertThrowsError(try state.probeOptions())
        XCTAssertNotNil(state.validationMessage)

        let sizes = self.state()
        sizes.chemistry = .hydrolysisProbe
        sizes.probeMinSize = "30"
        sizes.probeMaxSize = "20"
        XCTAssertThrowsError(try sizes.probeOptions())

        let gc = self.state()
        gc.chemistry = .hydrolysisProbe
        gc.probeMaxGC = "120"
        XCTAssertThrowsError(try gc.probeOptions())

        let blank = self.state()
        blank.chemistry = .hydrolysisProbe
        blank.probeMinTm = ""
        XCTAssertThrowsError(try blank.probeOptions())
    }
}
