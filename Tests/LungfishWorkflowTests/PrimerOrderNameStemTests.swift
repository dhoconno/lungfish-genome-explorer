import XCTest
@testable import LungfishWorkflow

/// Oligo names reach a vendor order sheet, so a name that stops mid-field reads as
/// a different allele. These cover the naming contract directly.
final class PrimerOrderNameStemTests: XCTestCase {
    private let limit = PrimerOrderExportService.orderNameStemLimit

    /// The reported defect: an MSA row's descriptive header was cut at 24
    /// characters, turning an A1*001 allele into "..._001_0".
    func testLongAlleleHeaderIsNotCutInsideAField() {
        let header = "LR699574.1_Mamu-A1_001_01_01_01_Macaca_mulatta_genomic_DNA"
        let stem = PrimerOrderExportService.orderNameStem(header)
        XCTAssertFalse(stem.hasSuffix("_0"), stem)
        XCTAssertFalse(stem.hasSuffix("_"), stem)
        XCTAssertLessThanOrEqual(stem.count, limit)
        // Every retained field is whole, so the stem is a prefix at a field boundary.
        XCTAssertTrue(header.hasPrefix(stem), stem)
        let nextCharacter = header.dropFirst(stem.count).first
        XCTAssertEqual(nextCharacter, "_", "the stem must end where a field ends")
    }

    /// The accession identifies the record, so it is preferred over a long header.
    func testRecordIDIsPreferredOverTheDescriptiveTitle() {
        let stem = PrimerOrderExportService.orderNameStem(
            "LR699574.1_Mamu-A1_001_01_01_01_Macaca_mulatta_genomic_DNA",
            recordID: "LR699574.1")
        XCTAssertEqual(stem, "LR699574.1")
    }

    /// An MSA row ID like "row-000001-032f0085da" names nothing a reader knows, so
    /// the descriptive title is used instead.
    func testOpaqueRowIdentifiersFallBackToTheTitle() {
        let stem = PrimerOrderExportService.orderNameStem(
            "LR699574.1_Mamu-A1_001_01_01_01", recordID: "row-000001-032f0085da")
        XCTAssertTrue(stem.hasPrefix("LR699574.1"), stem)
        XCTAssertFalse(stem.contains("row-"), stem)
    }

    func testShortNamesAreUnchangedAndIllegalCharactersBecomeUnderscores() {
        XCTAssertEqual(PrimerOrderExportService.orderNameStem("NC_045512.2"), "NC_045512.2")
        XCTAssertEqual(PrimerOrderExportService.orderNameStem("spike gene"), "spike_gene")
        XCTAssertEqual(PrimerOrderExportService.orderNameStem("a/b:c"), "a_b_c")
    }

    func testEmptyAndPunctuationOnlyTitlesFallBackToTemplate() {
        XCTAssertEqual(PrimerOrderExportService.orderNameStem(""), "Template")
        XCTAssertEqual(PrimerOrderExportService.orderNameStem("___"), "Template")
        XCTAssertEqual(PrimerOrderExportService.orderNameStem("   "), "Template")
    }

    /// A single field longer than the limit still has to yield a bounded name,
    /// because the vendor sheet has a column width.
    func testOneOverlongFieldIsCutBecauseNoFieldBoundaryExists() {
        let stem = PrimerOrderExportService.orderNameStem(String(repeating: "A", count: 60))
        XCTAssertEqual(stem.count, limit)
    }

    func testStemsStayWithinTheLimitForManyRealisticHeaders() {
        let headers = [
            "LR699574.1_Mamu-A1_001_01_01_01_Macaca_mulatta_genomic_DNA",
            "MT192765.1 Severe acute respiratory syndrome coronavirus 2",
            "gi|1798174254|ref|NC_045512.2| Wuhan seafood market pneumonia virus",
            "Mamu-A1*004:01:01:01",
        ]
        for header in headers {
            let stem = PrimerOrderExportService.orderNameStem(header)
            XCTAssertLessThanOrEqual(stem.count, limit, header)
            XCTAssertFalse(stem.isEmpty, header)
            XCTAssertFalse(stem.hasSuffix("_"), stem)
        }
    }
}
