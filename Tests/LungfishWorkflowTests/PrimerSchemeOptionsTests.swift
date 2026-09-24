import XCTest
@testable import LungfishWorkflow

final class PrimerSchemeOptionsTests: XCTestCase {
    func testProvenanceRecordsRequestedBoundsSeparatelyFromResolvedBounds() throws {
        let options = PrimerSchemeDesignOptions(
            engine: .olivar, mode: .tiled, grouping: .independent,
            nominalAmpliconLength: 400, minimumAmpliconLength: 360,
            maximumAmpliconLength: 440,
            requestedMinimumAmpliconLength: nil,
            requestedMaximumAmpliconLength: 440,
            workers: 1, olivar: .init())
        XCTAssertEqual(options.provenanceOptions["requestedMinimumAmpliconLength"], .null)
        XCTAssertEqual(options.provenanceOptions["requestedMaximumAmpliconLength"], .integer(440))
    }

    func testEqualMinimumTargetMaximumBoundaryIsValid() throws {
        let options = PrimerSchemeDesignOptions(
            engine: .olivar, mode: .tiled, grouping: .independent,
            nominalAmpliconLength: 120, minimumAmpliconLength: 120,
            maximumAmpliconLength: 120, workers: 1, olivar: .init())
        XCTAssertNoThrow(try options.validate())
    }

    func testOlivarRejectsMinimumBelowNativeLimitWithoutClamping() {
        let options = PrimerSchemeDesignOptions(
            engine: .olivar, mode: .tiled, grouping: .independent,
            nominalAmpliconLength: 200, minimumAmpliconLength: 119,
            maximumAmpliconLength: 250, workers: 1, olivar: .init())
        XCTAssertThrowsError(try options.validate()) { error in
            XCTAssertTrue(error.localizedDescription.contains("120"), error.localizedDescription)
        }
    }

    func testVarVAMPAcceptsEveryNativeMode() throws {
        for mode in [PrimerSchemeMode.single, .tiled] {
            let options = PrimerSchemeDesignOptions(
                engine: .varvamp, mode: mode, grouping: .independent,
                nominalAmpliconLength: 200, minimumAmpliconLength: 180,
                maximumAmpliconLength: 220, workers: 2, varvamp: .init())
            XCTAssertNoThrow(try options.validate(), "mode \(mode)")
        }
        let qpcr = PrimerSchemeDesignOptions(
            engine: .varvamp, mode: .qpcr, grouping: .independent,
            nominalAmpliconLength: 120, minimumAmpliconLength: 70,
            maximumAmpliconLength: 200, workers: 2,
            varvamp: .init(cumulativeConsensusThreshold: 0.9))
        XCTAssertNoThrow(try qpcr.validate())
    }

    func testVarVAMPRejectsCombinedGrouping() {
        let options = PrimerSchemeDesignOptions(
            engine: .varvamp, mode: .tiled, grouping: .combined,
            nominalAmpliconLength: 200, minimumAmpliconLength: 180,
            maximumAmpliconLength: 220, workers: 1, varvamp: .init())
        XCTAssertThrowsError(try options.validate())
    }

    func testQPCRRequiresExplicitConsensusThreshold() {
        let options = PrimerSchemeDesignOptions(
            engine: .varvamp, mode: .qpcr, grouping: .independent,
            nominalAmpliconLength: 120, minimumAmpliconLength: 70,
            maximumAmpliconLength: 200, workers: 1, varvamp: .init())
        XCTAssertThrowsError(try options.validate()) { error in
            XCTAssertTrue(error.localizedDescription.lowercased().contains("threshold"))
        }
    }

    func testEngineSpecificOptionsAreExclusive() {
        let missing = PrimerSchemeDesignOptions(
            engine: .olivar, mode: .tiled, grouping: .independent,
            nominalAmpliconLength: 200, minimumAmpliconLength: 180,
            maximumAmpliconLength: 220, workers: 1)
        XCTAssertThrowsError(try missing.validate())

        let both = PrimerSchemeDesignOptions(
            engine: .olivar, mode: .tiled, grouping: .independent,
            nominalAmpliconLength: 200, minimumAmpliconLength: 180,
            maximumAmpliconLength: 220, workers: 1,
            olivar: .init(), varvamp: .init())
        XCTAssertThrowsError(try both.validate())
    }

    func testRejectsNonFiniteAdvancedNumbers() {
        for value in [Double.nan, .infinity, -.infinity] {
            let olivar = PrimerSchemeDesignOptions(
                engine: .olivar, mode: .tiled, grouping: .independent,
                nominalAmpliconLength: 200, minimumAmpliconLength: 180,
                maximumAmpliconLength: 220, workers: 1,
                olivar: .init(minimumVariantFrequency: value))
            XCTAssertThrowsError(try olivar.validate())

            let varvamp = PrimerSchemeDesignOptions(
                engine: .varvamp, mode: .single, grouping: .independent,
                nominalAmpliconLength: 200, minimumAmpliconLength: 180,
                maximumAmpliconLength: 220, workers: 1,
                varvamp: .init(configOverrides: .init(primerHairpin: value)))
            XCTAssertThrowsError(try varvamp.validate())
        }
    }

    func testRejectsReversedRangesAndBadWorkerCounts() {
        let reversed = PrimerSchemeDesignOptions(
            engine: .varvamp, mode: .single, grouping: .independent,
            nominalAmpliconLength: 200, minimumAmpliconLength: 201,
            maximumAmpliconLength: 220, workers: 1, varvamp: .init())
        XCTAssertThrowsError(try reversed.validate())

        for workers in [0, -1] {
            let options = PrimerSchemeDesignOptions(
                engine: .varvamp, mode: .single, grouping: .independent,
                nominalAmpliconLength: 200, minimumAmpliconLength: 180,
                maximumAmpliconLength: 220, workers: workers, varvamp: .init())
            XCTAssertThrowsError(try options.validate())
        }
    }

    func testModeSpecificVarVAMPSettingsRejectUnsupportedUse() {
        let reportInTiled = PrimerSchemeDesignOptions(
            engine: .varvamp, mode: .tiled, grouping: .independent,
            nominalAmpliconLength: 200, minimumAmpliconLength: 180,
            maximumAmpliconLength: 220, workers: 1,
            varvamp: .init(reportCount: 3))
        XCTAssertThrowsError(try reportInTiled.validate())

        let probeInSingle = PrimerSchemeDesignOptions(
            engine: .varvamp, mode: .single, grouping: .independent,
            nominalAmpliconLength: 200, minimumAmpliconLength: 180,
            maximumAmpliconLength: 220, workers: 1,
            varvamp: .init(maximumProbeAmbiguities: 1))
        XCTAssertThrowsError(try probeInSingle.validate())
    }

    func testProvenanceDistinguishesResolvedDefaultsFromSuppliedValues() throws {
        let options = PrimerSchemeDesignOptions(
            engine: .olivar, mode: .tiled, grouping: .independent,
            nominalAmpliconLength: 400, minimumAmpliconLength: 360,
            maximumAmpliconLength: 440, workers: 2,
            olivar: .init(minimumVariantFrequency: 0.02,
                          suppliedOptionNames: ["minimumVariantFrequency"]))
        try options.validate()
        let engine = try XCTUnwrap(options.provenanceOptions["olivar"]?.dictionaryValue)
        let supplied = try XCTUnwrap(engine["supplied"]?.dictionaryValue)
        let resolved = try XCTUnwrap(engine["resolved"]?.dictionaryValue)
        XCTAssertEqual(supplied["minimumVariantFrequency"], .number(0.02))
        XCTAssertEqual(resolved["minimumVariantFrequency"], .number(0.02))
        XCTAssertEqual(resolved["minimumComplexity"], .number(0.4))
        XCTAssertNil(supplied["minimumComplexity"])
    }
}
