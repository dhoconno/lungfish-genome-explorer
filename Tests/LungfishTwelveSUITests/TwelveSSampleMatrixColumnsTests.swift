import XCTest
import LungfishIO
@testable import LungfishTwelveSUI

final class TwelveSSampleMatrixColumnsTests: XCTestCase {
    func testReadsColumnIDRoundTrip() {
        let id = TwelveSSampleMatrixColumns.readsColumnID(sampleID: "SampleA")
        XCTAssertEqual(id, "sample::SampleA::reads")
        XCTAssertEqual(TwelveSSampleMatrixColumns.parse(id), .reads(sampleID: "SampleA"))
    }

    func testMetaColumnIDRoundTrip() {
        let id = TwelveSSampleMatrixColumns.metaColumnID(sampleID: "SampleA", field: "site")
        XCTAssertEqual(id, "sample::SampleA::meta::site")
        XCTAssertEqual(TwelveSSampleMatrixColumns.parse(id), .meta(sampleID: "SampleA", field: "site"))
    }

    func testMetaColumnFieldWithDelimiterSurvives() {
        // A field containing "::" must round-trip (field is the remainder).
        let id = TwelveSSampleMatrixColumns.metaColumnID(sampleID: "S1", field: "lat::lon")
        XCTAssertEqual(TwelveSSampleMatrixColumns.parse(id), .meta(sampleID: "S1", field: "lat::lon"))
    }

    func testNonMatrixIDParsesNil() {
        XCTAssertNil(TwelveSSampleMatrixColumns.parse("scientificName"))
        XCTAssertNil(TwelveSSampleMatrixColumns.parse("sample::only"))
    }

    func testPctColumnIDRoundTripAndValue() {
        let id = TwelveSSampleMatrixColumns.pctColumnID(sampleID: "SampleA")
        XCTAssertEqual(id, "sample::SampleA::pct")
        XCTAssertEqual(TwelveSSampleMatrixColumns.parse(id), .pct(sampleID: "SampleA"))
        let row = TwelveSScientificNameCountRow(scientificName: "X", targetIDs: ["t"],
            sampleCounts: ["SampleA": 25], sampleExactReadTotals: ["SampleA": 100], taxids: [])
        XCTAssertEqual(TwelveSSampleMatrixColumns.pctValue(row, sampleID: "SampleA"), "25.0%")
        XCTAssertEqual(TwelveSSampleMatrixColumns.pctFraction(row, sampleID: "SampleA"), 25, accuracy: 0.001)
        // zero denominator → 0.0%
        let z = TwelveSScientificNameCountRow(scientificName: "Y", targetIDs: ["t"],
            sampleCounts: ["SampleA": 0], sampleExactReadTotals: ["SampleA": 0], taxids: [])
        XCTAssertEqual(TwelveSSampleMatrixColumns.pctValue(z, sampleID: "SampleA"), "0.0%")
    }

    func testReadsValue() {
        let row = TwelveSScientificNameCountRow(scientificName: "X", targetIDs: ["t"],
            sampleCounts: ["SampleA": 12, "SampleB": 3], sampleExactReadTotals: ["SampleA": 100, "SampleB": 50], taxids: [])
        XCTAssertEqual(TwelveSSampleMatrixColumns.readsValue(row, sampleID: "SampleA"), "12")
        XCTAssertEqual(TwelveSSampleMatrixColumns.readsValue(row, sampleID: "SampleZ"), "0")
    }
}
