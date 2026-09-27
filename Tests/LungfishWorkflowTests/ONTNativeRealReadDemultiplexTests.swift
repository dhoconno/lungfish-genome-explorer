import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

/// The built-in ONT native barcoding kit on real, untrimmed reads.
final class ONTNativeRealReadDemultiplexTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let projectDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTNativeRealReadDemultiplexTests-\(UUID().uuidString).lungfish", isDirectory: true)
        let dir = projectDir.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeFASTQ(_ reads: [(id: String, sequence: String)], to url: URL) throws {
        var lines: [String] = []
        for read in reads {
            lines += ["@\(read.id)", read.sequence, "+", String(repeating: "I", count: read.sequence.count)]
        }
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Three untrimmed reads from ENA PRJEB62796 (SQK-NBD114-96) plus the
    /// reverse complement of one, standing in for a read sequenced from the
    /// other strand. The built-in kit must assign all four to the barcode
    /// their run folder names (MinKNOW's barcode85 is the kit's NB85; the
    /// pipeline names bundles by the kit id), with every read accounted for.
    func testONTNativeKitAssignsRealNBD114ReadsInBothOrientations() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir.deletingLastPathComponent()) }

        let reads: [(id: String, barcode: String, sequence: String)] = [
            ("ERR12259924.34418", "NB85", "TGTACTTCGTTCAGTTACGTATTGCTGGTGCTGAACGGAGGAGTTAGTTGGATGATCTTAACCTTTCTGTTGGTGCTGATACCTTGGTTCAAGGCAGGCTGTTCTGTAATCGATAAACCCCGTTCTGCAAATAGAAAACAGGAAAGAAGATAGAGCGACAGGCAAGTAGGTTAAAGATCATCCAACTAACTCCTCCGTTCAGCACCAACT"),
            ("ERR12259928.27826", "NB89", "GCTGTACTTCGTTCAGTTACGTATTGCTGGTGCTGACAGCATCAATGTTTGGCTAGTTGTTAACCTACTTGCCTGTCGCTCTATCTTCGAGCAGCAACAAGAAAGCAGCACCAACTGAACATGCTCCTATTCAGGCAGAGACAGAAAGTGGACGTACTGTAGAAGCTGGCCATTACGTAGTTTTGGCAGCGATCACCAGTAAACTCATTTGGGCACTTTCTTGGTTTTGGACTTTCATGGGCACATTCTCAGTACATCTTACTCCAGTGAATCCAGGTTGGCACTTGCACAAGTATCTCGAGGGTTTGAAGGTCTTTCACCATGAAGCACTCCCCTCCATTCACACAGAAAGTTTTCTCCTTCTCCGCACATTTTACAAGATGGCTTGTCCCAGTGGTGGATGTAGATGTAGATGAGAAAAGTATTTGCTCCCTCTGTGGATACTGATGTTCTAATGGGAGACTCTGAAGACACATATGCTCCTTCAGTTGAGGCTGGCATACCGAGAGAGTGATGATCTCTGAAAAAAAGGTGATAGGACATTATGATATATAAACAGGAGGCCGGGAGCAGGTACCACAGCCTGCCTTGGAACTAAGCAATATCAGCACCAGCAAAGGAAAGGTTAACAACTAGCCAAACATTGATGCTGTCAGCACCAGCAATACG"),
            ("ERR12259930.19365", "NB91", "GCGTACTTCGTTCAGTTACGTATTGGTGCTGGGCTCCATAGGAACTCACGCTACTTTAACCTACTTGCCTGTCGCTCTATCTTCGATGCAGCAACAAGAAAACAGCACCAACTGAGCATGCTCCTATTCAGGCAGAGACAGAAGAGAGTGGACGTACTGTAGAAGCTGGCCATTACGTAGTTTTGGCAGCGATCACCAGTAAACTCATTTGGGCACTTTTCTTGGTTTTGGACTTTCGTGGGCACATTCTCAGTACATCTTGCTCAGTGAATCCAAGGTTGGCACTTGCACAAGTATCTCGAGGGGTTTGAAAGGTCTTTCACCATGAAGCACTCCCCTCCATTCACACAGAAAGTTTTCTCCTTCTCCGCACATTTTACAAGATGGCTTGTCCCAGTGGTGGATGTAGATGTAGATGAAGAAGTATTTGCTCCTTCTGTGGATACTGATATTCTAATGGGAGACTCTGAAGACACATGCTCCTTCAGTTGAGGCTGGCATACCAGTGATGACCTCTGAAAAAAAAAAGGTGATAGGACATTATGATATATAAACGGGGCGGGAGCAGGTACTACAGCCTGCGGAACTAAGCAATATCAGCACCAACAGAAAGGTTAAAGTAGCGTGAGTTCCTATGGAGCCCAGCACCAACAATACATGTAT"),
        ]
        let otherStrand = (id: "ERR12259924.34418.rc", sequence: PlatformAdapters.reverseComplement(reads[0].sequence))

        let inputFASTQ = tempDir.appendingPathComponent("input.fastq")
        try writeFASTQ(reads.map { ($0.id, $0.sequence) } + [otherStrand], to: inputFASTQ)

        let outputDir = tempDir.appendingPathComponent("demux-out", isDirectory: true)
        let result = try await DemultiplexingPipeline().run(
            config: DemultiplexConfig(
                inputURL: inputFASTQ,
                barcodeKit: BarcodeKitRegistry.ontNativeBarcoding96,
                outputDirectory: outputDir,
                barcodeLocation: .bothEnds,
                trimBarcodes: true,
                threads: 1
            ),
            progress: { _, _ in }
        )

        XCTAssertTrue(result.manifest.parameters.requireBothEnds)
        XCTAssertEqual(result.manifest.inputReadCount, 4)
        let counts = Dictionary(uniqueKeysWithValues: result.manifest.barcodes.map { ($0.barcodeID, $0.readCount) })
        XCTAssertEqual(counts, ["NB85": 2, "NB89": 1, "NB91": 1])
        XCTAssertEqual(result.manifest.unassigned.readCount, 0)

        let barcode85 = try XCTUnwrap(result.outputBundleURLs.first { $0.lastPathComponent == "NB85.lungfishfastq" }, "bundles: \(result.outputBundleURLs.map(\.lastPathComponent))")
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: barcode85))
        var trimmed: [String: Int] = [:]
        for try await record in FASTQReader(validateSequence: false).records(from: fastq) {
            trimmed[record.identifier] = record.length
        }
        XCTAssertEqual(Set(trimmed.keys), ["ERR12259924.34418", "ERR12259924.34418.rc"])
        for (id, length) in trimmed {
            XCTAssertLessThan(length, reads[0].sequence.count - 60, "\(id) keeps only the insert after both-end trimming")
        }
    }

    /// The manifest must say both ends were required whenever the pipeline
    /// enforced it, which for long-read symmetric kits is every location.
    func testSymmetricLongReadManifestReportsBothEndsRequiredForAnyLocation() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir.deletingLastPathComponent()) }
        let kit = BarcodeKitRegistry.ontNativeBarcoding24
        let barcode = try XCTUnwrap(kit.barcodes.first(where: { $0.id == "barcode13" }))
        let context = ONTNativeAdapterContext()
        let insert = String(repeating: "GATTACA", count: 20)
        let inputFASTQ = tempDir.appendingPathComponent("input.fastq")
        try writeFASTQ([
            ("both", context.fivePrimeSpec(barcodeSequence: barcode.i7Sequence) + insert
                + context.threePrimeSpec(barcodeSequence: barcode.i7Sequence)),
            ("five-only", context.fivePrimeSpec(barcodeSequence: barcode.i7Sequence) + insert),
        ], to: inputFASTQ)
        XCTAssertTrue(kit.searchesFullPlatformConstruct)

        let result = try await DemultiplexingPipeline().run(
            config: DemultiplexConfig(
                inputURL: inputFASTQ,
                barcodeKit: kit,
                outputDirectory: tempDir.appendingPathComponent("demux-out", isDirectory: true),
                barcodeLocation: .fivePrime,
                errorRate: 0.0,
                minimumOverlap: 20,
                trimBarcodes: true,
                threads: 1
            ),
            progress: { _, _ in }
        )
        XCTAssertTrue(result.manifest.parameters.requireBothEnds, "5'-only location does not switch off the both-end pass")
        XCTAssertEqual(result.manifest.barcodes.first?.readCount, 1)
        XCTAssertEqual(result.manifest.unassigned.readCount, 1)
    }
}
