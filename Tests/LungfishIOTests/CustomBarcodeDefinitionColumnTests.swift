import XCTest
@testable import LungfishIO

/// Column roles of custom barcode definitions: positional without a header,
/// named by the header otherwise, with sequence columns validated so a
/// sample name never reaches cutadapt as a barcode.
final class CustomBarcodeDefinitionColumnTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CustomBarcodeDefinitionColumnTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeDefinition(_ text: String, name: String = "barcodes.csv") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testHeaderNamesSampleNameAsThirdColumn() throws {
        let url = try writeDefinition("""
        id,sequence,sample_name
        NB85,AACGGAGGAGTTAGTTGGATGATC,IPSC-progenitors-long
        NB86,AGGTGATCCCAACAAGCGTAAGTA,IPSC-macrophages-long
        """)
        let kit = try BarcodeKitRegistry.loadCustomKit(from: url, name: "NRG1")
        XCTAssertFalse(kit.isDualIndexed)
        XCTAssertEqual(kit.pairingMode, .singleEnd)
        XCTAssertEqual(kit.barcodes.map(\.sampleName), ["IPSC-progenitors-long", "IPSC-macrophages-long"])
        XCTAssertEqual(kit.barcodes.map(\.i5Sequence), [nil, nil])
    }

    func testHeaderNamesSampleBeforeSecondarySequence() throws {
        let url = try writeDefinition("""
        barcode_id\tsequence\tsample\ti5
        A01\tACGTACGT\tSample-1\tTGCATGCA
        A02\tGGTTAACC\tSample-2\t
        """, name: "barcodes.tsv")
        let kit = try BarcodeKitRegistry.loadCustomKit(from: url, name: "Swapped")
        XCTAssertTrue(kit.isDualIndexed)
        XCTAssertEqual(kit.barcodes[0].i5Sequence, "TGCATGCA")
        XCTAssertEqual(kit.barcodes[0].sampleName, "Sample-1")
        XCTAssertNil(kit.barcodes[1].i5Sequence)
        XCTAssertEqual(kit.barcodes[1].sampleName, "Sample-2")
    }

    func testEmptyThirdColumnStillCarriesSampleNameInFourth() throws {
        let url = try writeDefinition("""
        id,sequence,secondary_sequence,sample_name
        NB85,AACGGAGGAGTTAGTTGGATGATC,,IPSC-progenitors-long
        """)
        let kit = try BarcodeKitRegistry.loadCustomKit(from: url, name: "NRG1")
        XCTAssertFalse(kit.isDualIndexed)
        XCTAssertEqual(kit.barcodes.first?.sampleName, "IPSC-progenitors-long")
    }

    func testHeaderlessFourColumnFormStillWorks() throws {
        let url = try writeDefinition("""
        NB85,AACGGAGGAGTTAGTTGGATGATC,,IPSC-progenitors-long
        A01,ACGTACGT,TGCATGCA,Sample-1
        """)
        let kit = try BarcodeKitRegistry.loadCustomKit(from: url, name: "Mixed")
        XCTAssertTrue(kit.isDualIndexed)
        XCTAssertEqual(kit.barcodes[0].sampleName, "IPSC-progenitors-long")
        XCTAssertEqual(kit.barcodes[1].i5Sequence, "TGCATGCA")
    }

    func testHeaderlessThirdColumnThatIsNotASequenceIsRejectedWithGuidance() throws {
        let url = try writeDefinition("""
        NB85,AACGGAGGAGTTAGTTGGATGATC,IPSC-progenitors-long
        """)
        XCTAssertThrowsError(try BarcodeKitRegistry.loadCustomKit(from: url, name: "NRG1")) { error in
            XCTAssertEqual(
                error as? BarcodeKitLoadError,
                .ambiguousThirdColumn(row: 1, id: "NB85", value: "IPSC-progenitors-long")
            )
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("id,sequence,,sample_name"), text)
            XCTAssertTrue(text.contains("id,sequence,sample_name"), text)
        }
    }

    func testHeaderedSecondaryColumnThatIsNotASequenceIsRejected() throws {
        let url = try writeDefinition("""
        id,sequence,i5_sequence
        NB85,AACGGAGGAGTTAGTTGGATGATC,BARCODE85
        """)
        XCTAssertThrowsError(try BarcodeKitRegistry.loadCustomKit(from: url, name: "NRG1")) { error in
            XCTAssertEqual(
                error as? BarcodeKitLoadError,
                .invalidSecondarySequence(row: 2, id: "NB85", value: "BARCODE85")
            )
            XCTAssertTrue(error.localizedDescription.contains("sample_name"))
        }
    }

    func testPrimarySequenceThatIsNotASequenceIsRejected() throws {
        let url = try writeDefinition("""
        NB85,Sample-1
        """)
        XCTAssertThrowsError(try BarcodeKitRegistry.loadCustomKit(from: url, name: "Broken")) { error in
            XCTAssertEqual(error as? BarcodeKitLoadError, .invalidSequence(row: 1, id: "NB85", value: "Sample-1"))
        }
    }

    func testIUPACAmbiguityCodesCountAsSequences() throws {
        let url = try writeDefinition("""
        id,sequence,sample_name
        X1,ACGTNRYK,mixed
        """)
        let kit = try BarcodeKitRegistry.loadCustomKit(from: url, name: "IUPAC")
        XCTAssertEqual(kit.barcodes.first?.i7Sequence, "ACGTNRYK")
        XCTAssertEqual(kit.barcodes.first?.sampleName, "mixed")
    }

    func testONTAndPacBioSymmetricKitsSearchFullPlatformConstruct() {
        XCTAssertTrue(BarcodeKitRegistry.ontNativeBarcoding96.searchesFullPlatformConstruct)
        XCTAssertTrue(BarcodeKitRegistry.ontRapidBarcoding96.searchesFullPlatformConstruct)
        XCTAssertTrue(BarcodeKitRegistry.fluidigmAccessArray.searchesFullPlatformConstruct)
        XCTAssertFalse(BarcodeKitRegistry.truseqSingleA.searchesFullPlatformConstruct)
        XCTAssertFalse(BarcodeKitRegistry.pacbioSequel16V3.searchesFullPlatformConstruct)
    }
}
