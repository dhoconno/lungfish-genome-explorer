import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class ONTFluidigmSampleMaterializerTests: XCTestCase {
    func testMaterializesPerSampleFastqsUsingExactFluidigmBarcodeAssignment() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let inputFASTQ = root.appendingPathComponent("barcode11.fastq")
        let barcodesCSV = root.appendingPathComponent("ONT09_NB11_samples.csv")
        let outputDirectory = root.appendingPathComponent("ont-fluidigm-samples", isDirectory: true)

        let cs1 = "ACACTGACGACATGGTTCTACA"
        let cs2rc = "AGACCAAGTCTCTGCTACCGTA"
        let lf2871Barcode = "AAAACCCCGG"
        let lf2872Barcode = "GGGGTTTTAA"
        let lf2871Read = cs1 + "ACGTACGTACGTACGT" + cs2rc + "CC" + lf2871Barcode
        let lf2872Read = cs1 + "TTTTCCCCAAAAGGGG" + cs2rc + "AA" + lf2872Barcode
        let reads = [
            ("read-1", lf2871Read),
            ("read-2", lf2871Read),
            ("read-3", lf2872Read),
            ("read-4", "NNNNNNNNNNNNNNNN"),
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

        let result = try await ONTFluidigmSampleMaterializer().run(
            ONTFluidigmSampleMaterializationRequest(
                inputURL: inputFASTQ,
                barcodeDefinitionsURL: barcodesCSV,
                outputDirectory: outputDirectory,
                force: true
            )
        )

        XCTAssertEqual(result.inputReadCount, 4)
        XCTAssertEqual(result.assignedReadCount, 3)
        XCTAssertEqual(result.unassignedReadCount, 1)
        XCTAssertEqual(result.outputBundleURLs.map(\.lastPathComponent), [
            "LF2871.lungfishfastq",
            "LF2872.lungfishfastq",
        ])

        let lf2871Bundle = outputDirectory.appendingPathComponent("LF2871.lungfishfastq", isDirectory: true)
        let lf2871FASTQ = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: lf2871Bundle))
        XCTAssertEqual(lf2871FASTQ.lastPathComponent, "reads.fastq.gz")
        let lf2871Records = try await FASTQReader(validateSequence: false).readAll(from: lf2871FASTQ)
        XCTAssertEqual(lf2871Records.map(\.identifier), ["read-1", "read-2"])
        XCTAssertTrue(lf2871Records.allSatisfy { $0.sequence.contains(lf2871Barcode) })
        XCTAssertTrue(lf2871Records.allSatisfy { $0.sequence.contains(cs1) })
        XCTAssertTrue(lf2871Records.allSatisfy { $0.sequence.contains(cs2rc) })

        let lf2872Bundle = outputDirectory.appendingPathComponent("LF2872.lungfishfastq", isDirectory: true)
        let lf2872FASTQ = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: lf2872Bundle))
        XCTAssertEqual(lf2872FASTQ.lastPathComponent, "reads.fastq.gz")
        let lf2872Records = try await FASTQReader(validateSequence: false).readAll(from: lf2872FASTQ)
        XCTAssertEqual(lf2872Records.map(\.identifier), ["read-3"])

        let manifest = try jsonObject(at: result.manifestURL)
        XCTAssertEqual(manifest["inputReadCount"] as? Int, 4)
        XCTAssertEqual(manifest["assignedReadCount"] as? Int, 3)
        XCTAssertEqual(manifest["unassignedReadCount"] as? Int, 1)
        let sampleTotals = try XCTUnwrap(manifest["sampleTotals"] as? [String: Int])
        XCTAssertEqual(sampleTotals["LF2871"], 2)
        XCTAssertEqual(sampleTotals["LF2872"], 1)
    }

    func testBarcodeAssignmentDoesNotCreateMatchesAcrossInvalidBases() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let inputFASTQ = root.appendingPathComponent("barcode11.fastq")
        let barcodesCSV = root.appendingPathComponent("ONT09_NB11_samples.csv")
        let outputDirectory = root.appendingPathComponent("ont-fluidigm-samples", isDirectory: true)

        let barcode = "AAAACCCCGG"
        let bridgedBarcode = "AAAACXCCCGG"
        try """
        @read-1
        \(bridgedBarcode)TTTT
        +
        IIIIIIIIIIIIIII
        """.write(to: inputFASTQ, atomically: true, encoding: .utf8)
        try """
        sample,barcode
        LF2871,\(barcode)
        """.write(to: barcodesCSV, atomically: true, encoding: .utf8)

        let result = try await ONTFluidigmSampleMaterializer().run(
            ONTFluidigmSampleMaterializationRequest(
                inputURL: inputFASTQ,
                barcodeDefinitionsURL: barcodesCSV,
                outputDirectory: outputDirectory,
                force: true
            )
        )

        XCTAssertEqual(result.inputReadCount, 1)
        XCTAssertEqual(result.assignedReadCount, 0)
        XCTAssertEqual(result.unassignedReadCount, 1)
        XCTAssertTrue(result.outputBundleURLs.isEmpty)
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTFluidigmSampleMaterializerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
