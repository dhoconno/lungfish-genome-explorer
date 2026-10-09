import XCTest
@testable import LungfishIO
import LungfishTestSupport

/// Decision D5b of the Phase 2.3 follow-up. One occurrence per animal, locus
/// and allele, kept where calls enter a result.
final class ONTGenotypeCallUniqueOccurrencesTests: XCTestCase {
    func testKeepsTheHighestReadRowOfADuplicatePairInTheFirstRowsPosition() {
        let calls = [
            call("AnimalA", "01_Mafa_A1_001_01", reads: 9),
            call("AnimalA", "03_Mafa_B_075_01", reads: 17),
            call("AnimalB", "03_Mafa_B_075_01", reads: 40),
            call("AnimalA", "03_Mafa_B_075_01", reads: 91),
        ]

        let unique = ONTGenotypeCall.uniqueOccurrences(calls)

        XCTAssertEqual(
            unique.map { "\($0.sample) \($0.genotype) \($0.passedUniqueReads)" },
            ["AnimalA 01_Mafa_A1_001_01 9", "AnimalA 03_Mafa_B_075_01 91", "AnimalB 03_Mafa_B_075_01 40"]
        )
        XCTAssertEqual(unique.map(\.passedUniqueReads).reduce(0, +), 140, "the rows are never summed, 17 is gone")
    }

    func testMoreAlignmentsBreakAReadTieAndAnExactTieKeepsTheEarlierRow() {
        let fewerAlignments = call("S1", "Mafa-A1*001:01", reads: 50, alignments: 50)
        let moreAlignments = call("S1", "Mafa-A1*001:01", reads: 50, alignments: 80)
        XCTAssertEqual(
            ONTGenotypeCall.uniqueOccurrences([fewerAlignments, moreAlignments]).map(\.passedAlignments),
            [80]
        )
        XCTAssertEqual(
            ONTGenotypeCall.uniqueOccurrences([moreAlignments, fewerAlignments]).map(\.passedAlignments),
            [80]
        )

        let first = call("S1", "Mafa-A1*001:01", reads: 50, alignments: 50, retainedReads: 400)
        let second = call("S1", "Mafa-A1*001:01", reads: 50, alignments: 50, retainedReads: 900)
        XCTAssertEqual(
            ONTGenotypeCall.uniqueOccurrences([first, second]).map(\.sampleUniqueRetainedReads),
            [400],
            "an exact tie keeps the first row in file order"
        )
    }

    func testOtherAnimalsAndOtherAllelesAreNeverCollapsed() {
        let calls = [
            call("S1", "Mafa-A1*001:01", reads: 10),
            call("S2", "Mafa-A1*001:01", reads: 10),
            call("S1", "Mafa-A1*002:01", reads: 10),
            call("S1", "Mafa-B*001:01", reads: 10),
        ]
        XCTAssertEqual(ONTGenotypeCall.uniqueOccurrences(calls), calls)
        XCTAssertEqual(ONTGenotypeCall.uniqueOccurrences([]), [])
    }

    func testASampleResultCollapsesItsOwnCallsAndKeepsItsSummaryCounts() {
        let sample = ONTGenotypeSampleResult(
            sample: "S1",
            passedAlignments: 120,
            passedUniqueReads: 120,
            sampleTotalReads: 2_000,
            sampleUniqueRetainedPercent: 6,
            calls: [
                call("S1", "Mafa-A1*001:01", reads: 17),
                call("S1", "Mafa-A1*001:01", reads: 91),
                call("S1", "Mafa-B*001:01", reads: 12),
            ]
        )

        let collapsed = sample.collapsingDuplicateOccurrences()

        XCTAssertEqual(collapsed.calls.map(\.passedUniqueReads), [91, 12])
        XCTAssertEqual(collapsed.passedUniqueReads, 120, "the sample summary's own count stays as written")
        XCTAssertEqual(collapsed.sampleTotalReads, 2_000)
        XCTAssertEqual(collapsed.sampleUniqueRetainedPercent, 6)
        XCTAssertEqual(collapsed.collapsingDuplicateOccurrences(), collapsed, "collapsing again changes nothing")
    }

    func testTheWarningNamesTheCollapsedRowCountAndIsAbsentWhenNothingCollapsed() throws {
        XCTAssertEqual(ONTGenotypeIntegrityWarning.duplicateCallRowsCollapsed(rowCount: 3, uniqueCount: 3), [])

        let one = try XCTUnwrap(ONTGenotypeIntegrityWarning.duplicateCallRowsCollapsed(rowCount: 4, uniqueCount: 3).first)
        XCTAssertEqual(one.code, .duplicateCallRowsCollapsed)
        XCTAssertEqual(one.code.rawValue, "duplicate-call-rows-collapsed")
        XCTAssertNil(one.path)
        XCTAssertTrue(one.detail.hasPrefix("1 duplicate genotype row was collapsed."), one.detail)
        XCTAssertTrue(one.detail.contains("the row with the most passed unique reads was kept"), one.detail)

        let three = try XCTUnwrap(ONTGenotypeIntegrityWarning.duplicateCallRowsCollapsed(rowCount: 7, uniqueCount: 4).first)
        XCTAssertTrue(three.detail.hasPrefix("3 duplicate genotype rows were collapsed."), three.detail)
    }

    /// Test fixtures and decoded captures build results through the
    /// initializer, so they follow the loader's rule. The result's calls, each
    /// sample's calls and the warning all come from one pass, and decoding
    /// the result again neither collapses nor warns a second time.
    func testTheResultInitializerCollapsesCallsAndSampleCallsAndWarnsOnce() throws {
        let duplicated = [
            call("AnimalA", "03_Mafa_B_075_01", reads: 17),
            call("AnimalB", "03_Mafa_B_075_01", reads: 40),
            call("AnimalA", "03_Mafa_B_075_01", reads: 91),
        ]
        let sample = ONTGenotypeSampleResult(
            sample: "AnimalA",
            passedAlignments: 108,
            passedUniqueReads: 108,
            sampleTotalReads: nil,
            sampleUniqueRetainedPercent: nil,
            calls: duplicated.filter { $0.sample == "AnimalA" }
        )
        let result = GenotypeTestFixtures.makeResult(samples: [sample], calls: duplicated)

        XCTAssertEqual(result.calls.map(\.passedUniqueReads), [91, 40])
        XCTAssertEqual(result.samples.first?.calls.map(\.passedUniqueReads), [91])
        XCTAssertEqual(result.samples.first?.passedUniqueReads, 108, "the sample summary's own count stays as written")
        XCTAssertEqual(result.integrityWarnings.map(\.code), [.duplicateCallRowsCollapsed])

        let decoded = try JSONDecoder().decode(ONTGenotypeResultBundleData.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(decoded, result)
        XCTAssertEqual(decoded.integrityWarnings.count, 1)

        let clean = GenotypeTestFixtures.makeResult(calls: Array(duplicated.prefix(2)))
        XCTAssertEqual(clean.calls, Array(duplicated.prefix(2)))
        XCTAssertTrue(clean.integrityWarnings.isEmpty, "a result without duplicates carries no warning")
    }

    private func call(
        _ sample: String,
        _ genotype: String,
        reads: Int,
        alignments: Int? = nil,
        retainedReads: Int? = nil
    ) -> ONTGenotypeCall {
        ONTGenotypeCall(
            sample: sample,
            genotype: genotype,
            passedAlignments: alignments ?? reads,
            passedUniqueReads: reads,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: retainedReads,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
    }
}
