import XCTest
@testable import LungfishCore
@testable import LungfishWorkflow

final class MappedReadsSAMRecordTests: XCTestCase {
    func testParseMappedRecordPreservesCoreFieldsAndAllAuxiliaryTags() throws {
        let line = "read-1\t99\tchr1\t101\t42\t8M1I4M2D6M\t=\t151\t200\tACGTACGTACGTACGTAAA\tIIIIIIIIIIIIIIIIIII\tNM:i:2\tAS:i:87\tRG:Z:grp-a\tXX:Z:a=b;c"

        let record = try XCTUnwrap(MappedReadsSAMRecord.parse(line))

        XCTAssertEqual(record.readName, "read-1")
        XCTAssertEqual(record.flag, 99)
        XCTAssertEqual(record.referenceName, "chr1")
        XCTAssertEqual(record.start0, 100)
        XCTAssertEqual(record.end0, 120)
        XCTAssertEqual(record.mapq, 42)
        XCTAssertEqual(record.cigarString, "8M1I4M2D6M")
        XCTAssertEqual(record.referenceLength, 20)
        XCTAssertEqual(record.queryLength, 19)
        XCTAssertEqual(record.mateReferenceName, "chr1")
        XCTAssertEqual(record.matePosition0, 150)
        XCTAssertEqual(record.templateLength, 200)
        XCTAssertEqual(record.sequence, "ACGTACGTACGTACGTAAA")
        XCTAssertEqual(record.qualities, "IIIIIIIIIIIIIIIIIII")
        XCTAssertEqual(record.auxiliaryTags["NM"], "2")
        XCTAssertEqual(record.auxiliaryTags["AS"], "87")
        XCTAssertEqual(record.auxiliaryTags["RG"], "grp-a")
        XCTAssertEqual(record.auxiliaryTags["XX"], "a=b;c")
    }

    func testDefaultAttributesExcludeSequenceAndQualities() throws {
        let line = "r2\t16\tchr2\t10\t60\t5S10M\t*\t0\t0\tNNNNNACGTACGTAC\tFFFFFJJJJJJJJJJ\tNM:i:0\tMD:Z:10"
        let record = try XCTUnwrap(MappedReadsSAMRecord.parse(line))
        let request = MappedReadsAnnotationRequest(
            bundleURL: URL(fileURLWithPath: "/tmp/ref.lungfishref"),
            sourceTrackID: "aln_a",
            outputTrackName: "Mapped Reads",
            includeSequence: false,
            includeQualities: false
        )

        let row = record.annotationRow(
            sourceTrackID: "aln_a",
            sourceTrackName: "Reads",
            request: request
        )

        XCTAssertEqual(row.name, "r2")
        XCTAssertEqual(row.type, "mapped_read")
        XCTAssertEqual(row.chromosome, "chr2")
        XCTAssertEqual(row.start, 9)
        XCTAssertEqual(row.end, 19)
        XCTAssertEqual(row.strand, "-")
        XCTAssertEqual(row.attributes["read_name"], "r2")
        XCTAssertEqual(row.attributes["flag"], "16")
        XCTAssertEqual(row.attributes["mapq"], "60")
        XCTAssertEqual(row.attributes["cigar"], "5S10M")
        XCTAssertEqual(row.attributes["tag_NM"], "0")
        XCTAssertEqual(row.attributes["tag_MD"], "10")
        XCTAssertEqual(row.attributes["source_alignment_track_id"], "aln_a")
        XCTAssertEqual(row.attributes["source_alignment_track_name"], "Reads")
        XCTAssertNil(row.attributes["sequence"])
        XCTAssertNil(row.attributes["qualities"])
    }

    func testOptionalSequenceAndQualitiesAreIncludedOnlyWhenRequested() throws {
        let line = "r3\t0\tchr1\t1\t20\t4M\t*\t0\t0\tACGT\tABCD\tNM:i:0"
        let record = try XCTUnwrap(MappedReadsSAMRecord.parse(line))
        let request = MappedReadsAnnotationRequest(
            bundleURL: URL(fileURLWithPath: "/tmp/ref.lungfishref"),
            sourceTrackID: "aln_a",
            outputTrackName: "Mapped Reads",
            includeSequence: true,
            includeQualities: true
        )

        let row = record.annotationRow(
            sourceTrackID: "aln_a",
            sourceTrackName: "Reads",
            request: request
        )

        XCTAssertEqual(row.attributes["sequence"], "ACGT")
        XCTAssertEqual(row.attributes["qualities"], "ABCD")
    }

    func testSecondaryAndSupplementaryFlagsAreExposed() throws {
        let secondary = try XCTUnwrap(MappedReadsSAMRecord.parse("r4\t256\tchr1\t1\t20\t4M\t*\t0\t0\tACGT\tABCD"))
        let supplementary = try XCTUnwrap(MappedReadsSAMRecord.parse("r5\t2048\tchr1\t1\t20\t4M\t*\t0\t0\tACGT\tABCD"))

        XCTAssertTrue(secondary.isSecondary)
        XCTAssertFalse(secondary.isSupplementary)
        XCTAssertFalse(supplementary.isSecondary)
        XCTAssertTrue(supplementary.isSupplementary)
    }
}
