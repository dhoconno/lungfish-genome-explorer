import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

/// State-level cover for the fixed-oligo and probe Tm offset dialog fields.
///
/// The dialog itself cannot be click-tested here, so these assert the state
/// object turns the visible fields into exactly the options the CLI builds for
/// the same choice.
@MainActor
final class PrimerDesignFixedOligoStateTests: XCTestCase {
    private func probeState() -> PrimerDesignDialogState {
        let state = PrimerDesignDialogState()
        state.engine = .primer3
        state.chemistry = .hydrolysisProbe
        return state
    }

    // MARK: - Fixed oligos

    func testAFreshDialogSendsNoFixedOligos() throws {
        let options = try probeState().primer3Options()
        XCTAssertTrue(options.fixedOligos.isEmpty)
    }

    func testEditedFieldsBecomeFixedOligoOptions() throws {
        let state = probeState()
        state.fixedLeftPrimer = "acgtacgtacgt"
        state.fixedRightPrimer = "TTGGCCAATTGG"
        state.fixedProbe = "ACGTTTGGCCAA"
        state.forceLeftEnd = "120"
        state.forceRightEnd = "260"

        let fixed = try state.primer3Options().fixedOligos
        // Sequences are uppercased so a pasted lowercase primer still works.
        XCTAssertEqual(fixed.leftPrimer, "ACGTACGTACGT")
        XCTAssertEqual(fixed.rightPrimer, "TTGGCCAATTGG")
        XCTAssertEqual(fixed.probe, "ACGTTTGGCCAA")
        XCTAssertEqual(fixed.forceLeftEnd, 120)
        XCTAssertEqual(fixed.forceRightEnd, 260)
    }

    func testWhitespaceOnlyFieldsAreTreatedAsBlank() throws {
        let state = probeState()
        state.fixedLeftPrimer = "   "
        state.fixedProbe = ""
        XCTAssertTrue(try state.primer3Options().fixedOligos.isEmpty)
    }

    func testANonNucleotideSequenceIsRejectedBeforeAnyRun() {
        let state = probeState()
        state.fixedLeftPrimer = "ACGTX"
        XCTAssertThrowsError(try state.primer3Options()) { error in
            XCTAssertTrue(error.localizedDescription.contains("A, C, G and T"))
        }
    }

    func testANonPositiveForcedEndIsRejected() {
        let state = probeState()
        state.forceLeftEnd = "0"
        XCTAssertThrowsError(try state.primer3Options())
    }

    func testPlacementSummaryNamesStrandAndThreePrimeEndForEachOligo() throws {
        let template = "ACGTTGCACCTAGGATCCGTATCAGGTCAAGCTTGGCCAATTCGATCGATTTACCGGTCAA"
        let state = probeState()
        state.fixedLeftPrimer = String(template.prefix(12))
        state.fixedRightPrimer = Primer3FixedOligoValidation.reverseComplement(String(template.suffix(12)))

        let summary = try XCTUnwrap(state.fixedOligoPlacementSummary(template: template))
        XCTAssertTrue(summary.contains("Forward primer: 1-12 (forward strand, 3′ end 12)"))
        XCTAssertTrue(summary.contains("reverse strand"))
    }

    func testPlacementSummaryExplainsAnOligoThatIsNotInTheTemplate() throws {
        let state = probeState()
        state.fixedLeftPrimer = "TTTTTTTTTTTT"
        let summary = try XCTUnwrap(
            state.fixedOligoPlacementSummary(template: "ACGTACGTACGTACGTACGT"))
        XCTAssertTrue(summary.contains("does not occur in the template"))
    }

    func testPlacementSummaryIsAbsentWhenNoOligoIsFixed() {
        XCTAssertNil(probeState().fixedOligoPlacementSummary(template: "ACGTACGTACGT"))
    }

    // MARK: - Probe Tm offset

    func testAFreshDialogAppliesTheFiveDegreeDefault() throws {
        let options = try probeState().primer3Options()
        XCTAssertEqual(
            options.probeMinTmOffsetOverPrimers,
            Primer3DesignOptions.defaultProbeMinTmOffsetOverPrimers)
        // 62 C primers plus 5 raises the configured 64 C probe minimum to 67.
        XCTAssertEqual(options.effectiveProbe?.probeMinTm, 67)
    }

    func testABlankOffsetFieldStillAppliesTheDefault() throws {
        let state = probeState()
        state.probeMinTmOffsetOverPrimers = ""
        XCTAssertEqual(
            try state.primer3Options().probeMinTmOffsetOverPrimers,
            Primer3DesignOptions.defaultProbeMinTmOffsetOverPrimers)
    }

    func testZeroDisablesTheAdjustmentAndKeepsTheEditedWindow() throws {
        let state = probeState()
        state.probeMinTmOffsetOverPrimers = "0"
        let options = try state.primer3Options()
        XCTAssertNil(options.probeMinTmOffsetOverPrimers)
        XCTAssertEqual(options.effectiveProbe?.probeMinTm, options.probe?.probeMinTm)
    }

    func testAnEditedOffsetIsHonoured() throws {
        let state = probeState()
        state.probeMinTmOffsetOverPrimers = "8"
        let options = try state.primer3Options()
        XCTAssertEqual(options.probeMinTmOffsetOverPrimers, 8)
        XCTAssertEqual(options.effectiveProbe?.probeMinTm, 70)
    }

    func testANegativeOffsetIsRejected() {
        let state = probeState()
        state.probeMinTmOffsetOverPrimers = "-3"
        XCTAssertThrowsError(try state.primer3Options())
    }

    func testTheOffsetNeverAddsAProbeToANonProbeAssay() throws {
        let state = PrimerDesignDialogState()
        state.engine = .primer3
        state.chemistry = .intercalatingDye
        let options = try state.primer3Options()
        XCTAssertNil(options.probe)
        XCTAssertNil(options.effectiveProbe)
    }

    // MARK: - GUI and CLI parity

    /// Both surfaces resolve onto the same shared preset, so the dialog's
    /// output must equal that preset built from the same visible choices. The
    /// CLI half of this equality is asserted in the CLI test target, which can
    /// import the subcommand.
    func testDialogOptionsEqualTheSharedPresetForTheSameChoices() throws {
        let state = probeState()
        state.fixedLeftPrimer = "ACGTACGTACGT"
        state.forceRightEnd = "300"
        state.probeMinTmOffsetOverPrimers = "6"

        let expected = Primer3DesignOptions.preset(
            .qpcrProbe,
            fixedOligos: .init(leftPrimer: "ACGTACGTACGT", forceRightEnd: 300),
            probeMinTmOffsetOverPrimers: 6)
        XCTAssertEqual(try state.primer3Options(), expected)
    }
}
