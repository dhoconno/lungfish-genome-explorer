import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class ONTFluidigmAmpliconMaterializerTests: XCTestCase {
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedEvents: [(Double, String)] = []

        func append(_ fraction: Double, _ message: String) {
            lock.lock()
            recordedEvents.append((fraction, message))
            lock.unlock()
        }

        func events() -> [(Double, String)] {
            lock.lock()
            defer { lock.unlock() }
            return recordedEvents
        }
    }

    func testMaterializesPerSampleCountedInsertFastqsAfterBarcodeAssignment() async throws {
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
            ("read-2", cs1 + lf2871Insert + readRightPrimer + "CC" + lf2871Barcode),
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
        XCTAssertEqual(lf2871FASTQ.lastPathComponent, "deduplicated-sample-reads.fastq.gz")
        let lf2871Records = try await fastqRecords(at: lf2871FASTQ)
        XCTAssertEqual(lf2871Records.map(\.identifier), ["u000001;size=2"])
        XCTAssertEqual(lf2871Records.map(\.sequence), [
            lf2871Insert
        ])
        XCTAssertFalse(lf2871Records.contains { $0.sequence.contains(lf2871Barcode) })
        XCTAssertFalse(lf2871Records.contains { $0.sequence.contains(cs1) })
        XCTAssertFalse(lf2871Records.contains { $0.sequence.contains(readRightPrimer) })
        let lf2871Manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: lf2871Bundle))
        XCTAssertEqual(lf2871Manifest.cachedStatistics.readCount, 2)
        XCTAssertEqual(lf2871Manifest.cachedStatistics.baseCount, Int64(lf2871Insert.count * 2))
        XCTAssertEqual(lf2871Manifest.cachedStatistics.readLengthHistogram, [lf2871Insert.count: 2])
        XCTAssertEqual(lf2871Manifest.cachedStatistics.minReadLength, lf2871Insert.count)
        XCTAssertEqual(lf2871Manifest.cachedStatistics.maxReadLength, lf2871Insert.count)
        XCTAssertEqual(lf2871Manifest.cachedStatistics.n50ReadLength, lf2871Insert.count)
        XCTAssertEqual(lf2871Manifest.cachedStatistics.q30Percentage, 100.0)
        XCTAssertEqual(lf2871Manifest.cachedStatistics.perPositionQuality.count, lf2871Insert.count)

        let lf2872Bundle = outputDirectory.appendingPathComponent("LF2872.lungfishfastq", isDirectory: true)
        let lf2872FASTQ = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: lf2872Bundle))
        let lf2872Records = try await fastqRecords(at: lf2872FASTQ)
        XCTAssertEqual(lf2872Records.map(\.identifier), ["u000001;size=1"])
        XCTAssertEqual(lf2872Records.map(\.sequence), [lf2872Insert])
        let lf2872Manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: lf2872Bundle))
        XCTAssertEqual(lf2872Manifest.cachedStatistics.readLengthHistogram, [lf2872Insert.count: 1])
        XCTAssertEqual(lf2872Manifest.cachedStatistics.minReadLength, lf2872Insert.count)
        XCTAssertEqual(lf2872Manifest.cachedStatistics.maxReadLength, lf2872Insert.count)
        XCTAssertEqual(lf2872Manifest.cachedStatistics.n50ReadLength, lf2872Insert.count)
        XCTAssertEqual(lf2872Manifest.cachedStatistics.q30Percentage, 100.0)
        XCTAssertEqual(lf2872Manifest.cachedStatistics.perPositionQuality.count, lf2872Insert.count)

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

    func testReportsProgressWhileScanningInputFASTQChunks() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let inputDirectory = root.appendingPathComponent("barcode11", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
        let chunk1 = inputDirectory.appendingPathComponent("chunk-1.fastq")
        let chunk2 = inputDirectory.appendingPathComponent("chunk-2.fastq")
        let hiddenSidecar = inputDirectory.appendingPathComponent("._chunk-1.fastq")
        let barcodesCSV = root.appendingPathComponent("ONT09_NB11_samples.csv")
        let outputDirectory = root.appendingPathComponent("ont-fluidigm-amplicons", isDirectory: true)

        let cs1 = ONTFluidigmAmpliconMaterializer.defaultForwardPrimer
        let cs2rc = Self.reverseComplement(ONTFluidigmAmpliconMaterializer.defaultReversePrimer)
        let barcode = "AAAACCCCGG"
        let insert = "ACGTACGTACGTACGT"
        try writeFASTQ(records: [("read-1", cs1 + insert + cs2rc + barcode)], to: chunk1)
        try writeFASTQ(records: [("read-2", cs1 + insert + cs2rc + barcode)], to: chunk2)
        try writeFASTQ(records: [("hidden-read", cs1 + insert + cs2rc + barcode)], to: hiddenSidecar)
        try """
        sample,barcode
        LF2871,\(barcode)
        """.write(to: barcodesCSV, atomically: true, encoding: .utf8)

        let progressRecorder = ProgressRecorder()
        let result = try await ONTFluidigmAmpliconMaterializer().run(
            ONTFluidigmAmpliconMaterializationRequest(
                inputURL: inputDirectory,
                barcodeDefinitionsURL: barcodesCSV,
                outputDirectory: outputDirectory,
                primerMismatches: 0,
                minimumInsertLength: 8,
                canonicalizeReverseComplements: false,
                force: true
            ),
            progress: { fraction, message in
                progressRecorder.append(fraction, message)
            }
        )

        XCTAssertEqual(result.inputReadCount, 2)
        let progressEvents = progressRecorder.events()
        XCTAssertTrue(progressEvents.contains { $0.1.contains("Found 2 ONT FASTQ chunks") })
        XCTAssertTrue(progressEvents.contains { $0.1.contains("Scanning chunk 1/2") })
        XCTAssertTrue(progressEvents.contains { $0.1.contains("Scanning chunk 2/2") })
        XCTAssertTrue(progressEvents.contains { $0.1.contains("Writing 1 sample bundle") })
        XCTAssertEqual(progressEvents.last?.0, 1.0)
    }

    func testExtractsCS1CS2InsertBeforeCountingDuplicateSampleReads() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let inputFASTQ = root.appendingPathComponent("barcode11.fastq")
        let barcodesCSV = root.appendingPathComponent("ONT09_NB11_samples.csv")
        let outputDirectory = root.appendingPathComponent("ont-fluidigm-amplicons", isDirectory: true)

        let cs1 = ONTFluidigmAmpliconMaterializer.defaultForwardPrimer
        let cs2 = ONTFluidigmAmpliconMaterializer.defaultReversePrimer
        let readRightPrimer = Self.reverseComplement(cs2)
        let barcode = "AAAACCCCGG"
        let insert = "ACGTACGTACGTACGT"
        let reads = [
            ("read-1", "GGTT" + cs1 + insert + readRightPrimer + "CC" + barcode),
            ("read-2", "TTAA" + cs1 + insert + readRightPrimer + "GGGG" + barcode + "AAAA"),
        ]
        let fastq = reads.map { identifier, sequence in
            "@\(identifier)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
        }.joined()
        try fastq.write(to: inputFASTQ, atomically: true, encoding: .utf8)
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
                canonicalizeReverseComplements: false,
                force: true
            )
        )

        XCTAssertEqual(result.inputReadCount, 2)
        XCTAssertEqual(result.assignedReadCount, 2)
        XCTAssertEqual(result.extractedReadCount, 2)
        XCTAssertEqual(result.uniqueSequenceCount, 1)

        let bundle = outputDirectory.appendingPathComponent("LF2871.lungfishfastq", isDirectory: true)
        let fastqURL = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        let records = try await fastqRecords(at: fastqURL)
        XCTAssertEqual(records.map(\.identifier), ["u000001;size=2"])
        XCTAssertEqual(records.map(\.sequence), [insert])
        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: bundle))
        XCTAssertEqual(manifest.cachedStatistics.readCount, 2)
        XCTAssertEqual(manifest.cachedStatistics.baseCount, Int64(insert.count * 2))
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

    func testAmpliconBarcodeAssignmentIgnoresBarcodeSequenceEmbeddedInPrimer() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let inputFASTQ = root.appendingPathComponent("barcode11.fastq")
        let barcodesCSV = root.appendingPathComponent("ONT09_NB11_samples.csv")
        let outputDirectory = root.appendingPathComponent("ont-fluidigm-amplicons", isDirectory: true)

        let cs1 = ONTFluidigmAmpliconMaterializer.defaultForwardPrimer
        let cs2rc = Self.reverseComplement(ONTFluidigmAmpliconMaterializer.defaultReversePrimer)
        let insert = "ACGTACGTACGTACGT"
        let lf2840Barcode = "CATGTCGTCA"
        XCTAssertTrue(cs1.contains(Self.reverseComplement(lf2840Barcode)))

        let sequence = "\(cs1)\(insert)\(cs2rc)"
        try """
        @read-1
        \(sequence)
        +
        \(String(repeating: "I", count: sequence.count))
        """.write(to: inputFASTQ, atomically: true, encoding: .utf8)
        try """
        sample,barcode
        LF2840,\(lf2840Barcode)
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

    /// R3-R3H-5: two barcode-sheet rows sharing the identical barcode string
    /// must be rejected at load time, not silently resolved to whichever
    /// sample happened to load first via BarcodeMatcher's `map[code]?.first`.
    func testRunThrowsOnDuplicateBarcodeSequence() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let inputFASTQ = root.appendingPathComponent("barcode11.fastq")
        let barcodesCSV = root.appendingPathComponent("ONT09_NB11_samples.csv")
        let outputDirectory = root.appendingPathComponent("ont-fluidigm-amplicons", isDirectory: true)

        try "@read-1\nACGT\n+\nIIII\n".write(to: inputFASTQ, atomically: true, encoding: .utf8)
        let sharedBarcode = "AAAACCCCGG"
        try """
        sample,barcode
        LF2871,\(sharedBarcode)
        LF2872,\(sharedBarcode)
        """.write(to: barcodesCSV, atomically: true, encoding: .utf8)

        do {
            _ = try await ONTFluidigmAmpliconMaterializer().run(
                ONTFluidigmAmpliconMaterializationRequest(
                    inputURL: inputFASTQ,
                    barcodeDefinitionsURL: barcodesCSV,
                    outputDirectory: outputDirectory,
                    force: true
                )
            )
            XCTFail("Expected duplicateBarcodeSequence error to be thrown")
        } catch let error as ONTFluidigmAmpliconMaterializerError {
            guard case .duplicateBarcodeSequence(let first, let second, let barcode) = error else {
                return XCTFail("Expected duplicateBarcodeSequence, got \(error)")
            }
            XCTAssertEqual(Set([first, second]), Set(["LF2871", "LF2872"]))
            XCTAssertEqual(barcode, sharedBarcode)
        }
    }

    /// R3-R3H-5: a collision via reverse-complement (one row's forward
    /// barcode equal to another row's reverse-complement) must also be
    /// rejected -- BarcodeMatcher indexes both orientations into the same
    /// code map.
    func testRunThrowsOnReverseComplementBarcodeCollision() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let inputFASTQ = root.appendingPathComponent("barcode11.fastq")
        let barcodesCSV = root.appendingPathComponent("ONT09_NB11_samples.csv")
        let outputDirectory = root.appendingPathComponent("ont-fluidigm-amplicons", isDirectory: true)

        try "@read-1\nACGT\n+\nIIII\n".write(to: inputFASTQ, atomically: true, encoding: .utf8)
        let barcodeA = "AAAACCCCGG"
        let barcodeB = Self.reverseComplement(barcodeA)
        try """
        sample,barcode
        LF2871,\(barcodeA)
        LF2872,\(barcodeB)
        """.write(to: barcodesCSV, atomically: true, encoding: .utf8)

        do {
            _ = try await ONTFluidigmAmpliconMaterializer().run(
                ONTFluidigmAmpliconMaterializationRequest(
                    inputURL: inputFASTQ,
                    barcodeDefinitionsURL: barcodesCSV,
                    outputDirectory: outputDirectory,
                    force: true
                )
            )
            XCTFail("Expected duplicateBarcodeSequence error to be thrown")
        } catch let error as ONTFluidigmAmpliconMaterializerError {
            guard case .duplicateBarcodeSequence(let first, let second, _) = error else {
                return XCTFail("Expected duplicateBarcodeSequence, got \(error)")
            }
            XCTAssertEqual(Set([first, second]), Set(["LF2871", "LF2872"]))
        }
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

    private func writeFASTQ(records: [(String, String)], to url: URL) throws {
        let text = records.map { identifier, sequence in
            "@\(identifier)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
        }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
