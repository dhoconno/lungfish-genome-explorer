import XCTest
import LungfishIO
@testable import LungfishTwelveSUI

final class TwelveSRowAggregatorTests: XCTestCase {

    private func target(_ counts: [String: Int], totals: [String: Int]) -> TwelveSScientificNameCountRow {
        TwelveSScientificNameCountRow(scientificName: "X", targetIDs: ["t"],
            sampleCounts: counts, sampleExactReadTotals: totals, taxids: [])
    }

    func testTargetTotalsRestrictToSelectedSamples() {
        let row = target(["s1": 40, "s2": 10], totals: ["s1": 100, "s2": 50])
        XCTAssertEqual(TwelveSRowAggregator.totalExactReads(row, selected: ["s1"]), 40)
        XCTAssertEqual(TwelveSRowAggregator.totalExactReads(row, selected: ["s1", "s2"]), 50)
    }

    func testMaxSamplePercentRestrictsToSelected() {
        // s1: 40/100 = 40%, s2: 10/20 = 50%
        let row = target(["s1": 40, "s2": 10], totals: ["s1": 100, "s2": 20])
        XCTAssertEqual(TwelveSRowAggregator.maxSamplePercent(row, selected: ["s1"]), 40, accuracy: 0.001)
        XCTAssertEqual(TwelveSRowAggregator.maxSamplePercent(row, selected: ["s1", "s2"]), 50, accuracy: 0.001)
    }

    func testRowDroppedWhenNoSelectedSampleHasReads() {
        let row = target(["s1": 40], totals: ["s1": 100])
        XCTAssertFalse(TwelveSRowAggregator.includesTarget(row, selected: ["s2"]))
        XCTAssertTrue(TwelveSRowAggregator.includesTarget(row, selected: ["s1"]))
    }

    func testAllSamplesEqualsLegacyTotals() {
        let row = target(["s1": 40, "s2": 10], totals: ["s1": 100, "s2": 50])
        let all: Set<String> = ["s1", "s2"]
        XCTAssertEqual(TwelveSRowAggregator.totalExactReads(row, selected: all), row.totalExactReads)
    }

    func testUnresolvedSelectedReadCountAndInclusion() {
        let row = TwelveSUnresolvedSequence(sequenceID: "c1", sequence: "ACGT", readCount: 21,
            sampleCounts: ["s1": 15, "s2": 6], chimeraStatus: .candidate)
        XCTAssertEqual(TwelveSRowAggregator.selectedReadCount(row, selected: ["s1"]), 15)
        XCTAssertEqual(TwelveSRowAggregator.selectedReadCount(row, selected: ["s1", "s2"]), 21)
        XCTAssertFalse(TwelveSRowAggregator.includesUnresolved(row, selected: ["s3"]))
        XCTAssertTrue(TwelveSRowAggregator.includesUnresolved(row, selected: ["s2"]))
    }

    func testSampleEntryMetric() {
        let small = TwelveSSampleEntry(id: "s1", displayName: "Sample One", exactReads: 842)
        XCTAssertEqual(small.metricLabel, "reads")
        XCTAssertEqual(small.metricValue, "842")
        // formatReadCount compacts thousands
        let big = TwelveSSampleEntry(id: "s2", displayName: "Sample Two", exactReads: 1234)
        XCTAssertEqual(big.metricValue, "1.2K")
    }
}
