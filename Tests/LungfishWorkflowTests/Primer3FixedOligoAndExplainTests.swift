import XCTest
@testable import LungfishWorkflow

/// Covers fixed oligos and forced 3' ends (B), the per-oligo EXPLAIN lines (C),
/// and the probe Tm offset (D).
final class Primer3FixedOligoAndExplainTests: XCTestCase {
    /// A template with no internal repeats, so each fixed oligo occurs once.
    private let template = "ACGTTGCACCTAGGATCCGTATCAGGTCAAGCTTGGCCAATTCGATCGATTTACCGGTCAA"

    private func prepared(_ sequence: String) -> Primer3PreparedTemplate {
        Primer3PreparedTemplate(
            inputID: UUID(), resultID: UUID(), title: "t", sequence: sequence,
            sourceURL: URL(fileURLWithPath: "/tmp/t.fa"), sourceIndex: 0, sourceRecordID: "t",
            sourceKind: .fasta, bindingSitePolicy: .templateOnly,
            alignmentToTemplate: nil, excludedRegions: [])
    }

    // MARK: - B: fixed oligo placement

    func testLocatesAForwardPrimerOnThePlusStrand() throws {
        let forward = String(template.prefix(12))
        let placements = try Primer3FixedOligoValidation.validate(
            .init(leftPrimer: forward), template: template)
        let placement = try XCTUnwrap(placements.first)
        XCTAssertEqual(placement.role, .leftPrimer)
        XCTAssertEqual(placement.start, 1)
        XCTAssertEqual(placement.end, 12)
        XCTAssertFalse(placement.matchedReverseComplement)
        XCTAssertEqual(placement.threePrimeEnd, 12)
    }

    func testLocatesAReversePrimerGivenAsOrderedViaItsReverseComplement() throws {
        // A reverse primer is ordered 5'->3', so its reverse complement is what
        // appears in the template.
        let footprint = String(template.suffix(12))
        let asOrdered = Primer3FixedOligoValidation.reverseComplement(footprint)
        let placement = try XCTUnwrap(
            try Primer3FixedOligoValidation.validate(
                .init(rightPrimer: asOrdered), template: template).first)
        XCTAssertTrue(placement.matchedReverseComplement)
        XCTAssertEqual(placement.end, template.count)
        // Its 3' end is the leftmost template base of the footprint.
        XCTAssertEqual(placement.threePrimeEnd, template.count - 11)
    }

    func testReportsEveryFixedOligoIncludingTheProbe() throws {
        let placements = try Primer3FixedOligoValidation.validate(
            .init(
                leftPrimer: String(template.prefix(12)),
                rightPrimer: Primer3FixedOligoValidation.reverseComplement(String(template.suffix(12))),
                probe: String(template.dropFirst(20).prefix(14))),
            template: template)
        XCTAssertEqual(placements.map(\.role), [.leftPrimer, .rightPrimer, .probe])
    }

    func testAnAbsentOligoFailsWithAnActionableMessage() {
        XCTAssertThrowsError(
            try Primer3FixedOligoValidation.validate(.init(leftPrimer: "TTTTTTTTTTTT"), template: template)
        ) { error in
            XCTAssertEqual(
                error as? Primer3FixedOligoValidation.Failure,
                .notFound(.leftPrimer, "TTTTTTTTTTTT"))
            // The message must mention orientation, the usual cause.
            XCTAssertTrue(error.localizedDescription.contains("orientation"))
        }
    }

    func testARepeatedOligoIsRejectedAsAmbiguous() {
        // "AC" occurs many times, so its position cannot be reported.
        XCTAssertThrowsError(
            try Primer3FixedOligoValidation.validate(.init(probe: "AC"), template: template)
        ) { error in
            guard case .ambiguous(.probe, "AC", _)? = error as? Primer3FixedOligoValidation.Failure else {
                return XCTFail("expected an ambiguity failure, got \(error)")
            }
        }
    }

    func testNonACGTSymbolsAreRejected() {
        XCTAssertThrowsError(
            try Primer3FixedOligoValidation.validate(.init(probe: "ACGTN"), template: template)
        ) {
            XCTAssertEqual(
                $0 as? Primer3FixedOligoValidation.Failure, .invalidSymbols(.probe, "ACGTN"))
        }
    }

    func testForcedEndsMustLieInsideTheTemplate() {
        XCTAssertThrowsError(
            try Primer3FixedOligoValidation.validate(
                .init(forceLeftEnd: template.count + 1), template: template)
        ) {
            XCTAssertEqual(
                $0 as? Primer3FixedOligoValidation.Failure,
                .forcedEndOutOfRange("SEQUENCE_FORCE_LEFT_END", template.count + 1, templateLength: template.count))
        }
        XCTAssertNoThrow(
            try Primer3FixedOligoValidation.validate(
                .init(forceLeftEnd: 1, forceRightEnd: template.count), template: template))
    }

    func testBlankFieldsAreTreatedAsAbsent() {
        // A blank GUI field must not emit a tag Primer3 would reject.
        let oligos = Primer3FixedOligos(leftPrimer: "   ", rightPrimer: "", probe: nil)
        XCTAssertTrue(oligos.isEmpty)
        XCTAssertNil(oligos.leftPrimer)
    }

    func testSequencesAreUppercasedSoLowercaseInputWorks() throws {
        let placement = try XCTUnwrap(
            try Primer3FixedOligoValidation.validate(
                .init(leftPrimer: String(template.prefix(12)).lowercased()),
                template: template).first)
        XCTAssertEqual(placement.sequence, String(template.prefix(12)))
    }

    // MARK: - B: Boulder tags

    func testBoulderWritesTheFixedOligoAndForcedEndTags() throws {
        let forward = String(template.prefix(12))
        let reverse = Primer3FixedOligoValidation.reverseComplement(String(template.suffix(12)))
        let text = try Primer3BoulderWriter.makeInput(
            templates: [prepared(template)],
            options: .preset(.qpcrProbe, fixedOligos: .init(
                leftPrimer: forward, rightPrimer: reverse,
                probe: String(template.dropFirst(20).prefix(14)),
                forceLeftEnd: 12, forceRightEnd: 50)))

        XCTAssertTrue(text.contains("SEQUENCE_PRIMER=\(forward)\n"))
        XCTAssertTrue(text.contains("SEQUENCE_PRIMER_REVCOMP=\(reverse)\n"))
        XCTAssertTrue(text.contains("SEQUENCE_INTERNAL_OLIGO=\(String(template.dropFirst(20).prefix(14)))\n"))
        // PRIMER_FIRST_BASE_INDEX is 0, so the 1-based inputs shift down by one.
        XCTAssertTrue(text.contains("SEQUENCE_FORCE_LEFT_END=11\n"))
        XCTAssertTrue(text.contains("SEQUENCE_FORCE_RIGHT_END=49\n"))
    }

    func testBoulderOmitsEveryFixedOligoTagWhenNoneAreGiven() throws {
        let text = try Primer3BoulderWriter.makeInput(
            templates: [prepared(template)], options: .preset(.pcr))
        for key in ["SEQUENCE_PRIMER=", "SEQUENCE_PRIMER_REVCOMP=", "SEQUENCE_INTERNAL_OLIGO=",
                    "SEQUENCE_FORCE_LEFT_END=", "SEQUENCE_FORCE_RIGHT_END="] {
            XCTAssertFalse(text.contains(key), key)
        }
    }

    func testBoulderRefusesAFixedOligoThatIsNotInTheTemplate() {
        XCTAssertThrowsError(try Primer3BoulderWriter.makeInput(
            templates: [prepared(template)],
            options: .preset(.pcr, fixedOligos: .init(leftPrimer: "TTTTTTTTTTTT"))))
    }

    func testFixedOligosSurviveACodableRoundTrip() throws {
        let options = Primer3DesignOptions.preset(.qpcrProbe, fixedOligos: .init(
            leftPrimer: String(template.prefix(12)), forceRightEnd: 40))
        let decoded = try JSONDecoder().decode(
            Primer3DesignOptions.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(decoded, options)
        XCTAssertEqual(decoded.fixedOligos.forceRightEnd, 40)
    }

    // MARK: - D: probe Tm offset

    func testProbeMinimumIsRaisedToFiveDegreesAboveTheHighestPrimerTm() {
        let options = Primer3DesignOptions.preset(.qpcrProbe)
        // The preset configures 64 C, but primers reach 62 C, so 62 + 5 = 67.
        XCTAssertEqual(options.probe?.probeMinTm, 64)
        XCTAssertEqual(options.effectiveProbe?.probeMinTm, 67)
        XCTAssertGreaterThanOrEqual(
            (options.effectiveProbe?.probeMinTm ?? 0) - options.primerMaxTm, 5)
    }

    func testRaisingTheMinimumCarriesTheWindowUpSoItStaysOrdered() throws {
        let options = Primer3DesignOptions.preset(.qpcrProbe, probeMinTmOffsetOverPrimers: 12)
        let probe = try XCTUnwrap(options.effectiveProbe)
        // 62 + 12 = 74, above the configured 70 maximum, so opt and max follow.
        XCTAssertEqual(probe.probeMinTm, 74)
        XCTAssertLessThanOrEqual(probe.probeMinTm, probe.probeOptTm)
        XCTAssertLessThanOrEqual(probe.probeOptTm, probe.probeMaxTm)
    }

    func testAnAlreadyHotEnoughProbeWindowIsLeftAlone() {
        // Primers capped at 50 C leave the configured 64 C minimum well clear,
        // so nothing is raised.
        let options = Primer3DesignOptions(
            assayMode: .qpcrProbe, productSizeMin: 70, productSizeMax: 150,
            targetStart: nil, targetEnd: nil, pairCount: 5,
            primerMinSize: 18, primerOptSize: 20, primerMaxSize: 24,
            primerMinTm: 48, primerOptTm: 49, primerMaxTm: 50,
            primerMinGC: 40, primerMaxGC: 60, pickInternalOligo: true,
            probe: .hydrolysisProbe)
        XCTAssertEqual(options.effectiveProbe, .hydrolysisProbe)
    }

    func testANilOffsetLeavesTheProbeWindowExactlyAsConfigured() {
        let options = Primer3DesignOptions.preset(.qpcrProbe, probeMinTmOffsetOverPrimers: nil)
        XCTAssertEqual(options.effectiveProbe, options.probe)
        XCTAssertEqual(options.effectiveProbe?.probeMinTm, 64)
    }

    func testTheOffsetNeverAppliesWithoutAProbe() {
        for mode in [Primer3AssayMode.pcr, .qpcrDye] {
            XCTAssertNil(Primer3DesignOptions.preset(mode).effectiveProbe, mode.rawValue)
        }
    }

    func testPCRAndDyeBoulderOutputIsUnchangedByTheProbeSettings() throws {
        // The probe work must not leak a PRIMER_INTERNAL_* line into the
        // non-probe presets.
        for mode in [Primer3AssayMode.pcr, .qpcrDye] {
            let text = try Primer3BoulderWriter.makeInput(
                templates: [prepared(template)], options: .preset(mode))
            XCTAssertFalse(text.contains("PRIMER_INTERNAL_MIN_TM"), mode.rawValue)
            XCTAssertFalse(text.contains("PRIMER_INTERNAL_MAX_POLY_X"), mode.rawValue)
        }
    }

    func testProbePresetCapsRunsAtThreeToAvoidGQuadruplexes() throws {
        let text = try Primer3BoulderWriter.makeInput(
            templates: [prepared(template)], options: .preset(.qpcrProbe))
        XCTAssertTrue(text.contains("PRIMER_INTERNAL_MAX_POLY_X=3\n"))
    }

    // MARK: - C: per-oligo explain lines

    func testParserSurfacesAllFourExplainLines() throws {
        let id = UUID()
        let record = """
        SEQUENCE_ID=\(id.uuidString)
        PRIMER_LEFT_EXPLAIN=considered 10, high tm 7, ok 3
        PRIMER_RIGHT_EXPLAIN=considered 10, high tm 9, ok 1
        PRIMER_INTERNAL_EXPLAIN=considered 1, low tm 1, ok 0
        PRIMER_PAIR_EXPLAIN=considered 0, ok 0
        PRIMER_PAIR_NUM_RETURNED=0
        =

        """
        let parsed = try Primer3BoulderParser.parse(record, expectedResultIDs: [id])
        let explanations = try XCTUnwrap(parsed.first?.explanations)
        XCTAssertEqual(explanations.left, "considered 10, high tm 7, ok 3")
        XCTAssertEqual(explanations.right, "considered 10, high tm 9, ok 1")
        XCTAssertEqual(explanations.internalOligo, "considered 1, low tm 1, ok 0")
        XCTAssertEqual(explanations.pair, "considered 0, ok 0")
        // The legacy single field still carries the pair line.
        XCTAssertEqual(parsed.first?.explanation, "considered 0, ok 0")
    }

    func testZeroPairRunAttributesTheFailureToTheProbeNotThePair() throws {
        // This is the case the feature exists for: the pair line says
        // "considered 0" and explains nothing, while the probe line names the
        // rule that rejected everything.
        let id = UUID()
        let record = """
        SEQUENCE_ID=\(id.uuidString)
        PRIMER_LEFT_EXPLAIN=considered 1, ok 1
        PRIMER_RIGHT_EXPLAIN=considered 1, ok 1
        PRIMER_INTERNAL_EXPLAIN=considered 1, low tm 1, ok 0
        PRIMER_PAIR_EXPLAIN=considered 0, ok 0
        PRIMER_PAIR_NUM_RETURNED=0
        =

        """
        let result = try XCTUnwrap(
            try Primer3BoulderParser.parse(record, expectedResultIDs: [id]).first)
        XCTAssertTrue(result.pairs.isEmpty)
        let labelled = try XCTUnwrap(result.explanations).labelledLines
        XCTAssertEqual(labelled.map(\.label), ["Left primer", "Right primer", "Probe", "Pair"])
        XCTAssertTrue(try XCTUnwrap(result.explanations?.internalOligo).contains("low tm"))
    }

    func testExplainLinesAreOmittedWhenPrimer3EmitsNone() throws {
        let id = UUID()
        let record = """
        SEQUENCE_ID=\(id.uuidString)
        PRIMER_PAIR_NUM_RETURNED=0
        =

        """
        let result = try XCTUnwrap(
            try Primer3BoulderParser.parse(record, expectedResultIDs: [id]).first)
        XCTAssertEqual(result.explanations?.isEmpty, true)
        XCTAssertTrue(try XCTUnwrap(result.explanations).labelledLines.isEmpty)
    }

    func testLabelledLinesSkipAbsentEntries() {
        let explanations = Primer3Explanations(
            left: "considered 5, ok 5", right: nil, internalOligo: "", pair: "considered 3, ok 3")
        XCTAssertEqual(explanations.labelledLines.map(\.label), ["Left primer", "Pair"])
        XCTAssertFalse(explanations.isEmpty)
    }

    func testNormalizedResultsRoundTripTheExplainLines() throws {
        let explanations = Primer3Explanations(
            left: "considered 2, ok 2", right: "considered 2, ok 1",
            internalOligo: "considered 1, ok 0", pair: "considered 0, ok 0")
        let results = Primer3NormalizedResults(
            analysisID: UUID(), runID: UUID(),
            results: [Primer3TemplateResult(
                resultID: UUID(), inputID: UUID(), title: "t", sourceKind: "fasta",
                sourceIndex: 0, sourceRecordID: "t", templateSequence: template,
                alignmentToTemplate: nil, excludedRegions: [], pairs: [],
                error: nil, explanation: explanations.pair, explanations: explanations)])
        let decoded = try JSONDecoder().decode(
            Primer3NormalizedResults.self, from: JSONEncoder().encode(results))
        XCTAssertEqual(decoded.results.first?.explanations, explanations)
    }

    func testResultsWrittenBeforePerOligoLinesExistedStillDecode() throws {
        // `explanations` is absent in older records, so it must be optional.
        let json = Data("""
        {"schemaVersion":1,"analysisID":"\(UUID().uuidString)","runID":"\(UUID().uuidString)",
         "results":[{"resultID":"\(UUID().uuidString)","inputID":"\(UUID().uuidString)",
         "title":"t","sourceKind":"fasta","sourceIndex":0,"sourceRecordID":"t",
         "templateSequence":"ACGT","excludedRegions":[],"pairs":[],
         "explanation":"considered 0, ok 0"}]}
        """.utf8)
        let decoded = try JSONDecoder().decode(Primer3NormalizedResults.self, from: json)
        XCTAssertNil(decoded.results.first?.explanations)
        XCTAssertEqual(decoded.results.first?.explanation, "considered 0, ok 0")
    }
}
