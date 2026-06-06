import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class ONTFluidigmAmpliconMaterializerTests: XCTestCase {
    func testMaterializesPerSampleCountedAmpliconFastqsAfterBarcodeAssignment() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let inputFASTQ = root.appendingPathComponent("barcode11.fastq")
        let barcodesCSV = root.appendingPathComponent("ONT09_NB11_samples.csv")
        let outputDirectory = root.appendingPathComponent("ont-fluidigm-amplicons", isDirectory: true)

        let cs1 = ONTFluidigmAmpliconMaterializer.defaultForwardPrimer
        let cs2 = ONTFluidigmAmpliconMaterializer.defaultReversePrimer
        let readRightPrimer = Self.reverseComplement(cs2)
        let lf2871Barcode = "AAAACCCCGG"
        let lf2872Barcode = "GGGGTTTTAA"
        let lf2871Insert = "ACGTACGTACGTACGT"
        let lf2872Insert = "TTTTCCCCAAAAGGGG"
        let reads = [
            ("read-1", cs1 + lf2871Insert + readRightPrimer + "CC" + lf2871Barcode),
            ("read-2", cs1 + lf2871Insert + readRightPrimer + "GG" + lf2871Barcode),
            ("read-3", cs1 + lf2872Insert + readRightPrimer + "AA" + lf2872Barcode),
        ]
        let fastq = reads.map { identifier, sequence in
            "@\(identifier)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
        }.joined()
        try fastq.write(to: inputFASTQ, atomically: true, encoding: .utf8)
        try """
        sample,barcode
        LF2871,\(lf2871Barcode)
        LF2872,\(lf2872Barcode)
        """.write(to: barcodesCSV, atomically: true, encoding: .utf8)

        let result = try await ONTFluidigmAmpliconMaterializer().run(
            ONTFluidigmAmpliconMaterializationRequest(
                inputURL: inputFASTQ,
                barcodeDefinitionsURL: barcodesCSV,
                outputDirectory: outputDirectory,
                primerMismatches: 0,
                minimumInsertLength: 8,
                canonicalizeReverseComplements: false,
                force: true
            )
        )

        XCTAssertEqual(result.inputReadCount, 3)
        XCTAssertEqual(result.assignedReadCount, 3)
        XCTAssertEqual(result.extractedReadCount, 3)
        XCTAssertEqual(result.uniqueSequenceCount, 2)
        XCTAssertEqual(result.outputBundleURLs.map(\.lastPathComponent), [
            "LF2871.lungfishfastq",
            "LF2872.lungfishfastq",
        ])

        let lf2871Bundle = outputDirectory.appendingPathComponent("LF2871.lungfishfastq", isDirectory: true)
        let lf2871FASTQ = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: lf2871Bundle))
        XCTAssertEqual(lf2871FASTQ.lastPathComponent, "deduplicated-amplicons.fastq.gz")
        let lf2871Records = try await fastqRecords(at: lf2871FASTQ)
        XCTAssertEqual(lf2871Records.map(\.identifier), ["u000001;size=2"])
        XCTAssertEqual(lf2871Records.map(\.sequence), [lf2871Insert])
        XCTAssertFalse(lf2871Records.contains { $0.sequence.contains(lf2871Barcode) })
        XCTAssertFalse(lf2871Records.contains { $0.sequence.contains(cs1) })
        XCTAssertFalse(lf2871Records.contains { $0.sequence.contains(readRightPrimer) })
        let lf2871Manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: lf2871Bundle))
        XCTAssertEqual(lf2871Manifest.cachedStatistics.readCount, 1)
        XCTAssertEqual(lf2871Manifest.cachedStatistics.baseCount, Int64(lf2871Insert.count))

        let lf2872Bundle = outputDirectory.appendingPathComponent("LF2872.lungfishfastq", isDirectory: true)
        let lf2872FASTQ = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: lf2872Bundle))
        let lf2872Records = try await fastqRecords(at: lf2872FASTQ)
        XCTAssertEqual(lf2872Records.map(\.identifier), ["u000001;size=1"])
        XCTAssertEqual(lf2872Records.map(\.sequence), [lf2872Insert])

        let manifest = try jsonObject(at: result.manifestURL)
        XCTAssertEqual(manifest["inputReadCount"] as? Int, 3)
        XCTAssertEqual(manifest["assignedReadCount"] as? Int, 3)
        XCTAssertEqual(manifest["extractedReadCount"] as? Int, 3)
        XCTAssertEqual(manifest["uniqueSequenceCount"] as? Int, 2)
        XCTAssertNotNil(manifest["sampleTotals"])
        let samples = try XCTUnwrap(manifest["samples"] as? [[String: Any]])
        let lf2871Sample = try XCTUnwrap(samples.first { $0["sample"] as? String == "LF2871" })
        XCTAssertEqual(lf2871Sample["baseCount"] as? Int, lf2871Insert.count)
        XCTAssertEqual(lf2871Sample["weightedBaseCount"] as? Int, lf2871Insert.count * 2)
    }

    func testAmpliconBarcodeAssignmentDoesNotCreateMatchesAcrossInvalidBases() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let inputFASTQ = root.appendingPathComponent("barcode11.fastq")
        let barcodesCSV = root.appendingPathComponent("ONT09_NB11_samples.csv")
        let outputDirectory = root.appendingPathComponent("ont-fluidigm-amplicons", isDirectory: true)

        let barcode = "AAAACCCCGG"
        let bridgedBarcode = "AAAACXCCCGG"
        let cs1 = ONTFluidigmAmpliconMaterializer.defaultForwardPrimer
        let cs2rc = Self.reverseComplement(ONTFluidigmAmpliconMaterializer.defaultReversePrimer)
        let insert = "ACGTACGTACGTACGT"
        try """
        @read-1
        \(cs1)\(insert)\(cs2rc)\(bridgedBarcode)
        +
        \(String(repeating: "I", count: cs1.count + insert.count + cs2rc.count + bridgedBarcode.count))
        """.write(to: inputFASTQ, atomically: true, encoding: .utf8)
        try """
        sample,barcode
        LF2871,\(barcode)
        """.write(to: barcodesCSV, atomically: true, encoding: .utf8)

        let result = try await ONTFluidigmAmpliconMaterializer().run(
            ONTFluidigmAmpliconMaterializationRequest(
                inputURL: inputFASTQ,
                barcodeDefinitionsURL: barcodesCSV,
                outputDirectory: outputDirectory,
                primerMismatches: 0,
                minimumInsertLength: 8,
                force: true
            )
        )

        XCTAssertEqual(result.inputReadCount, 1)
        XCTAssertEqual(result.assignedReadCount, 0)
        XCTAssertEqual(result.extractedReadCount, 0)
        XCTAssertEqual(result.outputBundleURLs, [])
    }

    private static func reverseComplement(_ sequence: String) -> String {
        let table: [Character: Character] = [
            "A": "T", "C": "G", "G": "C", "T": "A",
            "a": "t", "c": "g", "g": "c", "t": "a",
        ]
        return String(sequence.reversed().map { table[$0] ?? "N" }).uppercased()
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func fastqRecords(at url: URL) async throws -> [FASTQRecord] {
        var records: [FASTQRecord] = []
        let reader = FASTQReader(validateSequence: false)
        for try await record in reader.records(from: url) {
            records.append(record)
        }
        return records
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTFluidigmAmpliconMaterializerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
