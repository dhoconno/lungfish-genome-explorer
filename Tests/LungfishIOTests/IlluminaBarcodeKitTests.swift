import XCTest
@testable import LungfishIO

final class IlluminaBarcodeKitTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarcodeKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Built-In Kit Registry

    func testBuiltinKitCount() {
        let kits = IlluminaBarcodeKitRegistry.builtinKits()
        XCTAssertEqual(kits.count, 5)
    }

    func testTruSeqSingleA() {
        let kit = IlluminaBarcodeKitRegistry.truseqSingleA
        XCTAssertEqual(kit.id, "truseq-single-a")
        XCTAssertEqual(kit.barcodes.count, 12)
        XCTAssertFalse(kit.isDualIndexed)
        XCTAssertEqual(kit.vendor, "illumina")
        XCTAssertEqual(kit.barcodes[0].id, "D701")
        XCTAssertEqual(kit.barcodes[0].i7Sequence, "ATTACTCG")
        XCTAssertNil(kit.barcodes[0].i5Sequence)
    }

    func testTruSeqSingleB() {
        let kit = IlluminaBarcodeKitRegistry.truseqSingleB
        XCTAssertEqual(kit.id, "truseq-single-b")
        XCTAssertEqual(kit.barcodes.count, 8)
        XCTAssertFalse(kit.isDualIndexed)
    }

    func testTruSeqHTDual() {
        let kit = IlluminaBarcodeKitRegistry.truseqHTDual
        XCTAssertEqual(kit.id, "truseq-ht-dual")
        XCTAssertEqual(kit.barcodes.count, 96) // 12 i7 × 8 i5
        XCTAssertTrue(kit.isDualIndexed)
        // Check first barcode is a combination
        XCTAssertEqual(kit.barcodes[0].id, "D701-D501")
        XCTAssertNotNil(kit.barcodes[0].i5Sequence)
    }

    func testNexteraXTv2() {
        let kit = IlluminaBarcodeKitRegistry.nexteraXTv2
        XCTAssertEqual(kit.id, "nextera-xt-v2")
        XCTAssertEqual(kit.barcodes.count, 84) // 12 × 7
        XCTAssertTrue(kit.isDualIndexed)
    }

    func testIDTUDIndexes() {
        let kit = IlluminaBarcodeKitRegistry.idtUDIndexes
        XCTAssertEqual(kit.id, "idt-ud-indexes")
        XCTAssertEqual(kit.barcodes.count, 24)
        XCTAssertTrue(kit.isDualIndexed)
    }

    func testKitLookupByID() {
        let kit = IlluminaBarcodeKitRegistry.kit(byID: "nextera-xt-v2")
        XCTAssertNotNil(kit)
        XCTAssertEqual(kit?.displayName, "Nextera XT Index Kit v2")

        let notFound = IlluminaBarcodeKitRegistry.kit(byID: "nonexistent")
        XCTAssertNil(notFound)
    }

    // MARK: - Custom Kit Loading

    func testLoadCustomCSV() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let csv = """
        id,i7_sequence,i5_sequence,sample_name
        BC01,ACGTACGT,TGCATGCA,Sample-1
        BC02,GGTTAACC,,Sample-2
        BC03,AACCGGTT
        """

        let csvURL = dir.appendingPathComponent("custom-barcodes.csv")
        try csv.write(to: csvURL, atomically: true, encoding: .utf8)

        let kit = try IlluminaBarcodeKitRegistry.loadCustomKit(from: csvURL, name: "My Custom Kit")

        XCTAssertEqual(kit.id, "custom-my-custom-kit")
        XCTAssertEqual(kit.displayName, "My Custom Kit")
        XCTAssertEqual(kit.vendor, "custom")
        XCTAssertTrue(kit.isDualIndexed) // BC01 has i5
        XCTAssertEqual(kit.barcodes.count, 3)
        XCTAssertEqual(kit.barcodes[0].id, "BC01")
        XCTAssertEqual(kit.barcodes[0].i7Sequence, "ACGTACGT")
        XCTAssertEqual(kit.barcodes[0].i5Sequence, "TGCATGCA")
        XCTAssertEqual(kit.barcodes[0].sampleName, "Sample-1")
        XCTAssertNil(kit.barcodes[1].i5Sequence)
        XCTAssertNil(kit.barcodes[2].sampleName)
    }

    func testLoadCustomCSVSkipsComments() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let csv = """
        # This is a comment
        barcode_id,i7_sequence
        A01,ACGTACGT
        # Another comment
        A02,TGCATGCA
        """

        let csvURL = dir.appendingPathComponent("barcodes.csv")
        try csv.write(to: csvURL, atomically: true, encoding: .utf8)

        let kit = try IlluminaBarcodeKitRegistry.loadCustomKit(from: csvURL, name: "Test")
        XCTAssertEqual(kit.barcodes.count, 2)
    }

    // MARK: - FASTA Generation

    func testGenerateSingleIndexFASTA() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let kit = IlluminaBarcodeDefinition(
            id: "test",
            displayName: "Test Kit",
            barcodes: [
                IlluminaBarcode(id: "A01", i7Sequence: "ACGTACGT"),
                IlluminaBarcode(id: "A02", i7Sequence: "TGCATGCA"),
            ]
        )

        let fastaURL = dir.appendingPathComponent("adapters.fasta")
        let i5URL = try IlluminaBarcodeKitRegistry.generateCutadaptFASTA(
            for: kit,
            to: fastaURL,
            location: .fivePrime,
            includeAdapterContext: false
        )

        XCTAssertNil(i5URL, "Single-indexed kit should not produce i5 FASTA")

        let content = try String(contentsOf: fastaURL, encoding: .utf8)
        XCTAssertTrue(content.contains(">A01"))
        XCTAssertTrue(content.contains("^ACGTACGT"))
        XCTAssertTrue(content.contains(">A02"))
        XCTAssertTrue(content.contains("^TGCATGCA"))
    }

    func testGenerateThreePrimeFASTA() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let kit = IlluminaBarcodeDefinition(
            id: "test",
            displayName: "Test",
            barcodes: [
                IlluminaBarcode(id: "A01", i7Sequence: "ACGT"),
            ]
        )

        let fastaURL = dir.appendingPathComponent("adapters.fasta")
        try IlluminaBarcodeKitRegistry.generateCutadaptFASTA(
            for: kit,
            to: fastaURL,
            location: .threePrime,
            includeAdapterContext: false
        )

        let content = try String(contentsOf: fastaURL, encoding: .utf8)
        XCTAssertTrue(content.contains("ACGT$"))
    }

    func testGenerateDualIndexFASTA() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let kit = IlluminaBarcodeDefinition(
            id: "test",
            displayName: "Dual Test",
            isDualIndexed: true,
            barcodes: [
                IlluminaBarcode(id: "A01", i7Sequence: "ACGT", i5Sequence: "TGCA"),
            ]
        )

        let fastaURL = dir.appendingPathComponent("adapters.fasta")
        let i5URL = try IlluminaBarcodeKitRegistry.generateCutadaptFASTA(
            for: kit,
            to: fastaURL,
            location: .fivePrime,
            includeAdapterContext: false
        )

        XCTAssertNotNil(i5URL, "Dual-indexed kit should produce i5 FASTA")

        let i7Content = try String(contentsOf: fastaURL, encoding: .utf8)
        XCTAssertTrue(i7Content.contains(">A01"))
        XCTAssertTrue(i7Content.contains("^ACGT"))

        let i5Content = try String(contentsOf: i5URL!, encoding: .utf8)
        XCTAssertTrue(i5Content.contains(">A01"))
        XCTAssertTrue(i5Content.contains("^TGCA"))
    }

    // MARK: - Adapter Context

    func testGenerateFASTAWithAdapterContext() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let kit = IlluminaBarcodeDefinition(
            id: "test",
            displayName: "Context Test",
            barcodes: [
                IlluminaBarcode(id: "A01", i7Sequence: "ACGTACGT"),
            ]
        )

        let fastaURL = dir.appendingPathComponent("adapters.fasta")
        try IlluminaBarcodeKitRegistry.generateCutadaptFASTA(
            for: kit,
            to: fastaURL,
            location: .anywhere,
            includeAdapterContext: true
        )

        let content = try String(contentsOf: fastaURL, encoding: .utf8)
        XCTAssertTrue(content.contains(">A01"))
        // Should contain upstream + barcode + downstream
        let expected = "\(IlluminaAdapterContext.i7Upstream)ACGTACGT\(IlluminaAdapterContext.i7Downstream)"
        XCTAssertTrue(content.contains(expected), "Should include flanking adapter context")
    }

    func testGenerateDualIndexFASTAWithAdapterContext() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let kit = IlluminaBarcodeDefinition(
            id: "test",
            displayName: "Dual Context Test",
            isDualIndexed: true,
            barcodes: [
                IlluminaBarcode(id: "A01", i7Sequence: "ACGT", i5Sequence: "TGCA"),
            ]
        )

        let fastaURL = dir.appendingPathComponent("adapters.fasta")
        let i5URL = try IlluminaBarcodeKitRegistry.generateCutadaptFASTA(
            for: kit,
            to: fastaURL,
            location: .anywhere,
            includeAdapterContext: true
        )

        XCTAssertNotNil(i5URL)

        let i7Content = try String(contentsOf: fastaURL, encoding: .utf8)
        let expectedI7 = "\(IlluminaAdapterContext.i7Upstream)ACGT\(IlluminaAdapterContext.i7Downstream)"
        XCTAssertTrue(i7Content.contains(expectedI7), "i7 should include flanking context")

        let i5Content = try String(contentsOf: i5URL!, encoding: .utf8)
        let expectedI5 = "\(IlluminaAdapterContext.i5Upstream)TGCA\(IlluminaAdapterContext.i5Downstream)"
        XCTAssertTrue(i5Content.contains(expectedI5), "i5 should include flanking context")
    }

    func testAdapterContextConstants() {
        // Verify flanking sequences are reasonable DNA
        for seq in [IlluminaAdapterContext.i7Upstream, IlluminaAdapterContext.i7Downstream,
                    IlluminaAdapterContext.i5Upstream, IlluminaAdapterContext.i5Downstream] {
            XCTAssertFalse(seq.isEmpty)
            XCTAssertTrue(seq.allSatisfy { "ACGT".contains($0) }, "Should be valid DNA: \(seq)")
        }
    }

    // MARK: - BarcodeLocation

    func testBarcodeLocationCases() {
        XCTAssertEqual(BarcodeLocation.allCases.count, 3)
        XCTAssertEqual(BarcodeLocation.fivePrime.rawValue, "fivePrime")
        XCTAssertEqual(BarcodeLocation.threePrime.rawValue, "threePrime")
        XCTAssertEqual(BarcodeLocation.anywhere.rawValue, "anywhere")
    }

    // MARK: - Codable

    func testIlluminaBarcodeDefinitionCodable() throws {
        let kit = IlluminaBarcodeDefinition(
            id: "test-kit",
            displayName: "Test Kit",
            barcodes: [
                IlluminaBarcode(id: "A01", i7Sequence: "ACGT", i5Sequence: "TGCA", sampleName: "S1"),
            ]
        )

        let data = try JSONEncoder().encode(kit)
        let decoded = try JSONDecoder().decode(IlluminaBarcodeDefinition.self, from: data)

        XCTAssertEqual(kit, decoded)
    }
}
