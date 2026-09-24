import XCTest
@testable import LungfishCore

final class GenBankAccessionParserTests: XCTestCase {
    func testAcceptsNucleotideFamiliesAndPreservesVersions() throws {
        let values = ["U12345", "NC_000017.11", "NM_000059.4", "PQ12345678.1", "NM_000546.6", "NM_001744.6",
                      "NR_135858.1", "XM_012345678.2", "XR_123456.1", "NG_009904.1",
                      "NT_123456.1", "NW_012345678.1", "AC_123456.1",
                      "AAAA01000001.1", "AAAAAA020000001.1", "NZ_CP012345.1", "NZ_CASIGT010000001.1"]
        for value in values { XCTAssertTrue(GenBankAccessionParser.isNucleotideAccession(value), value) }
        XCTAssertEqual(try GenBankAccessionParser.parseAccessionList(values.joined(separator: "\n")), values)
    }

    func testRejectsProteinAssemblySRAAndMalformedAccessions() {
        for value in ["AP_123456.1", "NP_123456.1", "WP_123456789.1", "AAA12345.1", "GCF_000001405.40", "SRR123456",
                      "12345", "NM_000546.0", "NM_000546.", "NM_000546.6 OR all[filter]", "AB123", ""] {
            XCTAssertFalse(GenBankAccessionParser.isNucleotideAccession(value), value)
        }
    }

    func testRejectsBioSampleIDsButAllowsExpandedWGSDigitCounts() {
        for value in ["SAMN12345678", "SAMD123456789", "SAMEA123456789"] {
            XCTAssertFalse(GenBankAccessionParser.isNucleotideAccession(value), value)
        }
        XCTAssertTrue(GenBankAccessionParser.isNucleotideAccession("AAAA01000000001.1"))
        XCTAssertTrue(GenBankAccessionParser.isNucleotideAccession("AAAAAA010000000001.1"))
    }

    func testNormalizesCaseAndDeduplicatesWithoutCollapsingVersions() throws {
        XCTAssertEqual(try GenBankAccessionParser.parseAccessionList("nm_000059.4, NM_000059.4\tnm_000546.6\nNM_000059.3 NM_000059"),
                       ["NM_000059.4", "NM_000546.6", "NM_000059.3", "NM_000059"])
    }

    func testCSVUsesAccessionColumnAndHandlesQuotedMetadata() throws {
        let text = "\u{FEFF}title,accession.version,note\r\n\"NM_000059.2, decoy\",nm_000546.6,\"line one\nline \"\"two\"\"\"\r\nother,NM_000059.4,ignored\r\n"
        XCTAssertEqual(try GenBankAccessionParser.parseCSV(text), ["NM_000546.6", "NM_000059.4"])
    }

    func testTSVUsesAccessionColumn() throws {
        XCTAssertEqual(try GenBankAccessionParser.parseCSV("Organism\tAccession\tLength\nHomo sapiens\tNM_000059.4\t11954\n"), ["NM_000059.4"])
    }

    func testVersionColumnPreferredOverUnversionedAccessionColumn() throws {
        XCTAssertEqual(try GenBankAccessionParser.parseCSV("accession,accession.version\nNM_000059,NM_000059.4\n"), ["NM_000059.4"])
    }

    func testHeaderlessCSVAndSingleColumnHeader() throws {
        XCTAssertEqual(try GenBankAccessionParser.parseCSV("\"NM_000059.4\",\"NM_000546.6\"\n"), ["NM_000059.4", "NM_000546.6"])
        XCTAssertEqual(try GenBankAccessionParser.parseCSV("acc\nNM_000059.4\n\nNM_000546.6\n"), ["NM_000059.4", "NM_000546.6"])
    }

    func testInvalidRowReportsLineAndValueInsteadOfPartiallyImporting() {
        XCTAssertThrowsError(try GenBankAccessionParser.parseCSV("accession,title\nNM_000059.4,valid\nSRR123456,wrong database\n")) { error in
            XCTAssertTrue(error.localizedDescription.contains("3"))
            XCTAssertTrue(error.localizedDescription.contains("SRR123456"))
        }
        XCTAssertThrowsError(try GenBankAccessionParser.parseCSV("accession,title\n,missing\n"))
        XCTAssertThrowsError(try GenBankAccessionParser.parseCSV("title,length\nNM_000059.4,11954\n"))
    }

    func testRejectsEmptyAndMalformedCSV() {
        for value in ["", "\n \t\n", "acc\n", "\"NM_000059.4", "\"NM_000059.4\"junk", "MN\"908947.3"] {
            XCTAssertThrowsError(try GenBankAccessionParser.parseCSV(value), value)
        }
    }

    func testReadsUTF8File() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tsv")
        defer { try? FileManager.default.removeItem(at: url) }
        try "accession\ttitle\nNM_000059.4\tHomo sapiens\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try GenBankAccessionParser.parseCSVFile(at: url), ["NM_000059.4"])
    }
}
