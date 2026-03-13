import XCTest
@testable import LungfishIO
import LungfishCore

final class SequenceRecordTests: XCTestCase {

    // MARK: - SequenceFormat

    func testSequenceFormatFromFASTQExtension() {
        XCTAssertEqual(SequenceFormat.from(pathExtension: "fastq"), .fastq)
        XCTAssertEqual(SequenceFormat.from(pathExtension: "fq"), .fastq)
        XCTAssertEqual(SequenceFormat.from(pathExtension: "FASTQ"), .fastq)
    }

    func testSequenceFormatFromFASTAExtension() {
        XCTAssertEqual(SequenceFormat.from(pathExtension: "fasta"), .fasta)
        XCTAssertEqual(SequenceFormat.from(pathExtension: "fa"), .fasta)
        XCTAssertEqual(SequenceFormat.from(pathExtension: "fna"), .fasta)
        XCTAssertEqual(SequenceFormat.from(pathExtension: "fsa"), .fasta)
    }

    func testSequenceFormatFromGzExtensionReturnsNil() {
        XCTAssertNil(SequenceFormat.from(pathExtension: "gz"))
    }

    func testSequenceFormatFromUnknownExtensionReturnsNil() {
        XCTAssertNil(SequenceFormat.from(pathExtension: "bam"))
        XCTAssertNil(SequenceFormat.from(pathExtension: "vcf"))
    }

    func testSequenceFormatFromURL() {
        let fastqURL = URL(fileURLWithPath: "/tmp/reads.fastq")
        XCTAssertEqual(SequenceFormat.from(url: fastqURL), .fastq)

        let fastaURL = URL(fileURLWithPath: "/tmp/reference.fasta")
        XCTAssertEqual(SequenceFormat.from(url: fastaURL), .fasta)
    }

    func testSequenceFormatFromGzippedURL() {
        let gzURL = URL(fileURLWithPath: "/tmp/reads.fastq.gz")
        XCTAssertEqual(SequenceFormat.from(url: gzURL), .fastq)

        let fastaGzURL = URL(fileURLWithPath: "/tmp/ref.fasta.gz")
        XCTAssertEqual(SequenceFormat.from(url: fastaGzURL), .fasta)
    }

    func testSequenceFormatFileExtension() {
        XCTAssertEqual(SequenceFormat.fastq.fileExtension, "fastq")
        XCTAssertEqual(SequenceFormat.fasta.fileExtension, "fasta")
    }

    func testSequenceFormatCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let original = SequenceFormat.fasta
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(SequenceFormat.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - SimpleFASTARecord

    func testSimpleFASTARecordConformsToSequenceRecord() {
        let record = SimpleFASTARecord(identifier: "seq1", description: "test sequence", sequence: "ATCGATCG")
        XCTAssertEqual(record.identifier, "seq1")
        XCTAssertEqual(record.sequence, "ATCGATCG")
        XCTAssertEqual(record.recordDescription, "test sequence")
        XCTAssertEqual(record.length, 8)
    }

    func testSimpleFASTARecordNilDescription() {
        let record = SimpleFASTARecord(identifier: "seq1", sequence: "ATCG")
        XCTAssertNil(record.recordDescription)
    }

    func testSimpleFASTARecordFormatted() {
        let record = SimpleFASTARecord(identifier: "seq1", description: "desc", sequence: "ATCG")
        let formatted = record.formatted()
        XCTAssertEqual(formatted, ">seq1 desc\nATCG\n")
    }

    func testSimpleFASTARecordFormattedLongSequence() {
        let seq = String(repeating: "A", count: 150)
        let record = SimpleFASTARecord(identifier: "seq1", sequence: seq)
        let formatted = record.formatted(lineWidth: 60)
        let lines = formatted.split(separator: "\n")
        XCTAssertEqual(lines.count, 4) // header + 60 + 60 + 30
        XCTAssertEqual(lines[0], ">seq1")
        XCTAssertEqual(lines[1].count, 60)
        XCTAssertEqual(lines[2].count, 60)
        XCTAssertEqual(lines[3].count, 30)
    }

    func testSimpleFASTARecordEquatable() {
        let a = SimpleFASTARecord(identifier: "seq1", sequence: "ATCG")
        let b = SimpleFASTARecord(identifier: "seq1", sequence: "ATCG")
        let c = SimpleFASTARecord(identifier: "seq2", sequence: "ATCG")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - LungfishCore.Sequence Conformance

    func testCoreSequenceConformsToSequenceRecord() throws {
        let coreSeq = try LungfishCore.Sequence(
            name: "chr1",
            description: "Chromosome 1",
            alphabet: .dna,
            bases: "ATCGATCGATCG"
        )
        // Access through SequenceRecord protocol
        let record: any SequenceRecord = coreSeq
        XCTAssertEqual(record.identifier, "chr1")
        XCTAssertEqual(record.sequence, "ATCGATCGATCG")
        XCTAssertEqual(record.recordDescription, "Chromosome 1")
        XCTAssertEqual(record.length, 12)
    }

    // MARK: - FASTQDerivativePayload fullFASTA

    func testFullFASTAPayloadCategory() {
        let payload = FASTQDerivativePayload.fullFASTA(fastaFilename: "output.fasta")
        XCTAssertEqual(payload.category, "full-fasta")
    }

    // MARK: - Operation Format Compatibility

    func testSubsetOperationsSupportFASTA() {
        XCTAssertTrue(FASTQDerivativeOperationKind.subsampleProportion.supportsFASTA)
        XCTAssertTrue(FASTQDerivativeOperationKind.subsampleCount.supportsFASTA)
        XCTAssertTrue(FASTQDerivativeOperationKind.lengthFilter.supportsFASTA)
        XCTAssertTrue(FASTQDerivativeOperationKind.searchText.supportsFASTA)
        XCTAssertTrue(FASTQDerivativeOperationKind.searchMotif.supportsFASTA)
        XCTAssertTrue(FASTQDerivativeOperationKind.deduplicate.supportsFASTA)
        XCTAssertTrue(FASTQDerivativeOperationKind.fixedTrim.supportsFASTA)
        XCTAssertTrue(FASTQDerivativeOperationKind.orient.supportsFASTA)
    }

    func testQualityDependentOperationsDoNotSupportFASTA() {
        XCTAssertFalse(FASTQDerivativeOperationKind.qualityTrim.supportsFASTA)
        XCTAssertFalse(FASTQDerivativeOperationKind.adapterTrim.supportsFASTA)
        XCTAssertFalse(FASTQDerivativeOperationKind.pairedEndMerge.supportsFASTA)
        XCTAssertFalse(FASTQDerivativeOperationKind.pairedEndRepair.supportsFASTA)
        XCTAssertFalse(FASTQDerivativeOperationKind.demultiplex.supportsFASTA)
    }

    // MARK: - Manifest sequenceFormat

    func testManifestSequenceFormatRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let manifest = FASTQDerivedBundleManifest(
            name: "test",
            parentBundleRelativePath: "../parent.lungfishfastq",
            rootBundleRelativePath: "../../root.lungfishfastq",
            rootFASTQFilename: "reads.fasta",
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .lengthFilter),
            cachedStatistics: .placeholder(readCount: 10, baseCount: 100),
            pairingMode: nil,
            sequenceFormat: .fasta
        )

        let data = try encoder.encode(manifest)
        let decoded = try decoder.decode(FASTQDerivedBundleManifest.self, from: data)
        XCTAssertEqual(decoded.sequenceFormat, .fasta)
    }

    func testManifestSequenceFormatBackwardCompat() throws {
        // Encode a manifest WITH sequenceFormat, then strip the field to simulate legacy
        let encoder = JSONEncoder()
        let manifest = FASTQDerivedBundleManifest(
            name: "legacy",
            parentBundleRelativePath: "../parent.lungfishfastq",
            rootBundleRelativePath: "../../root.lungfishfastq",
            rootFASTQFilename: "reads.fastq",
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .lengthFilter),
            cachedStatistics: .placeholder(readCount: 10, baseCount: 100),
            pairingMode: nil,
            sequenceFormat: .fastq
        )
        var data = try encoder.encode(manifest)
        // Decode as dictionary, remove sequenceFormat, re-encode
        var dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        dict.removeValue(forKey: "sequenceFormat")
        data = try JSONSerialization.data(withJSONObject: dict)

        let decoded = try JSONDecoder().decode(FASTQDerivedBundleManifest.self, from: data)
        XCTAssertNil(decoded.sequenceFormat) // nil for legacy, caller assumes .fastq
    }
}
