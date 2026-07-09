import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class ONTPacBioBarcodeDemuxMaterializerTests: XCTestCase {
    func testDefaultChunkJobsUsesActiveProcessorCount() {
        let expected = max(1, ProcessInfo.processInfo.activeProcessorCount)

        let request = ONTPacBioBarcodeDemuxMaterializationRequest(
            inputURL: URL(fileURLWithPath: "/tmp/fastq_pass/barcode13"),
            barcodeDefinitionsURL: URL(fileURLWithPath: "/tmp/NB13_MHC-I_plate1.barcodes.csv"),
            outputDirectory: URL(fileURLWithPath: "/tmp/mhc-pacbio-demux")
        )

        XCTAssertEqual(ONTPacBioBarcodeDemuxMaterializationRequest.defaultChunkJobs, expected)
        XCTAssertEqual(request.chunkJobs, expected)
    }

    func testHeaderlessPacBioSampleSheetMaterializesPerSampleOutputs() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let inputDirectory = root.appendingPathComponent("barcode13", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
        let chunk1 = inputDirectory.appendingPathComponent("chunk-1.fastq")
        let chunk2 = inputDirectory.appendingPathComponent("chunk-2.fastq")
        let hiddenSidecar = inputDirectory.appendingPathComponent("._chunk-1.fastq")
        let barcodesCSV = root.appendingPathComponent("NB13_MHC-I_plate1.barcodes.csv")
        let outputDirectory = root.appendingPathComponent("mhc-pacbio-demux", isDirectory: true)

        let forward = "CACATATCAGAGTGCG"
        let reverse = "CTATACATAGTGATGT"
        let reverseForward = reverseComplement(reverse)
        let reverseReverse = reverseComplement(forward)
        let insert = String(repeating: "ACGT", count: 510)
        let sampleForwardRead = String(repeating: "T", count: 60) + forward + insert + reverseComplement(reverse) + String(repeating: "A", count: 60)
        let sampleReverseRead = String(repeating: "G", count: 50) + reverseForward + insert + reverseReverse + String(repeating: "C", count: 50)
        let offTargetRead = String(repeating: "N", count: sampleForwardRead.count)

        try writeFASTQ(records: [
            ("read-1", sampleForwardRead),
            ("read-2", offTargetRead),
        ], to: chunk1)
        try writeFASTQ(records: [
            ("read-3", sampleReverseRead),
        ], to: chunk2)
        try writeFASTQ(records: [
            ("hidden-read", sampleForwardRead),
        ], to: hiddenSidecar)
        try """
        32286-001_DL46,BC1001,BC1021
        """.write(to: barcodesCSV, atomically: true, encoding: .utf8)

        let progressRecorder = ProgressRecorder()
        let result = try await ONTPacBioBarcodeDemuxMaterializer().run(
            ONTPacBioBarcodeDemuxMaterializationRequest(
                inputURL: inputDirectory,
                barcodeDefinitionsURL: barcodesCSV,
                outputDirectory: outputDirectory,
                force: true,
                threads: 1,
                chunkJobs: 2,
                maxReadsPerSlice: 0
            ),
            progress: { fraction, message in
                progressRecorder.append(fraction, message)
            }
        )

        XCTAssertEqual(result.inputChunkCount, 2)
        XCTAssertEqual(result.executedCutadaptChunkCount, 0)
        XCTAssertEqual(result.cutadaptRuns, [])
        XCTAssertEqual(result.chunkJobs, 1)
        XCTAssertEqual(result.assignedReadCount, 2)
        XCTAssertEqual(result.unassignedReadCount, 1)
        XCTAssertEqual(result.outputBundleURLs.map(\.lastPathComponent), [
            "32286-001_DL46.lungfishfastq",
        ])

        let sampleBundle = try XCTUnwrap(result.outputBundleURLs.first)
        let sampleFASTQ = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: sampleBundle))
        XCTAssertEqual(sampleFASTQ.lastPathComponent, "32286-001_DL46.fastq.gz")
        let records = try await FASTQReader(validateSequence: false).readAll(from: sampleFASTQ)
        XCTAssertEqual(records.map(\.identifier), ["read-1", "read-3"])
        let recordLengthHistogram = Dictionary(grouping: records, by: \.length)
            .mapValues(\.count)
        let sampleDerivedManifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: sampleBundle))
        XCTAssertEqual(sampleDerivedManifest.cachedStatistics.readLengthHistogram, recordLengthHistogram)
        XCTAssertEqual(sampleDerivedManifest.cachedStatistics.minReadLength, records.map(\.length).min())
        XCTAssertEqual(sampleDerivedManifest.cachedStatistics.maxReadLength, records.map(\.length).max())
        XCTAssertEqual(sampleDerivedManifest.cachedStatistics.n50ReadLength, records.map(\.length).max())

        let manifest = try jsonObject(at: result.manifestURL)
        XCTAssertEqual(manifest["inputChunkCount"] as? Int, 2)
        XCTAssertEqual(manifest["assignmentEngine"] as? String, "exact-barcode-demux")
        XCTAssertEqual(manifest["executedCutadaptChunkCount"] as? Int, 0)
        XCTAssertEqual(manifest["assignedReadCount"] as? Int, 2)
        XCTAssertEqual(manifest["unassignedReadCount"] as? Int, 1)

        let progressEvents = progressRecorder.events()
        XCTAssertTrue(progressEvents.contains { $0.1.contains("Running exact PacBio barcode demultiplexing") })
        XCTAssertTrue(progressEvents.contains { $0.1.contains("PacBio barcode demultiplexing complete") })
    }

    func testBuiltInPacBioSampleSheetMatchesONTReadsWithAdapterFlanks() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let inputDirectory = root.appendingPathComponent("barcode17", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
        let chunk = inputDirectory.appendingPathComponent("chunk-1.fastq")
        let barcodesCSV = root.appendingPathComponent("pacbio-samples.csv")
        let outputDirectory = root.appendingPathComponent("mhc-pacbio-demux", isDirectory: true)

        let forward = "CACATATCAGAGTGCG" // bc1001
        let reverse = "CTATACATAGTGATGT" // bc1021
        let ontLeadingFlank = "CTGCCCCTGCCAGCCCCTTCGGTTCAGTTACGTATTGCTAAGGTTAAACCCTCCAGGAAAGTACCTCTGATCAGCACCT"
        let ontTrailingFlank = "AGGTGCTGATCAGAGGTACTTCCTGGAGGGTTTAACCTTAGCAATA"
        let insert = String(repeating: "ACGT", count: 510)
        let read = ontLeadingFlank + forward + insert + reverseComplement(reverse) + ontTrailingFlank
        try writeFASTQ(records: [
            ("read-1", read),
            ("read-2", String(repeating: "N", count: read.count)),
        ], to: chunk)
        try """
        sample_id,barcode_1,barcode_2
        PN358,bc1001,bc1021
        """.write(to: barcodesCSV, atomically: true, encoding: .utf8)

        let result = try await ONTPacBioBarcodeDemuxMaterializer().run(
            ONTPacBioBarcodeDemuxMaterializationRequest(
                inputURL: inputDirectory,
                barcodeDefinitionsURL: barcodesCSV,
                outputDirectory: outputDirectory,
                force: true,
                threads: 1,
                chunkJobs: 1,
                maxReadsPerSlice: 0
            ),
            progress: { _, _ in }
        )

        XCTAssertEqual(result.inputChunkCount, 1)
        XCTAssertEqual(result.executedCutadaptChunkCount, 0)
        XCTAssertEqual(result.cutadaptRuns, [])
        XCTAssertEqual(result.inputReadCount, 2)
        XCTAssertEqual(result.assignedReadCount, 1)
        XCTAssertEqual(result.unassignedReadCount, 1)
        XCTAssertEqual(result.outputBundleURLs.map(\.lastPathComponent), [
            "PN358.lungfishfastq",
        ])
        let sampleBundle = try XCTUnwrap(result.outputBundleURLs.first)
        let sampleFASTQ = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: sampleBundle))
        let records = try await FASTQReader(validateSequence: false).readAll(from: sampleFASTQ)
        XCTAssertEqual(records.map(\.identifier), ["read-1"])

        let manifest = try jsonObject(at: result.manifestURL)
        XCTAssertEqual(manifest["assignmentEngine"] as? String, "exact-barcode-demux")
        XCTAssertEqual(manifest["executedCutadaptChunkCount"] as? Int, 0)
    }

    func testInvalidPacBioSampleSheetFailsBeforeCreatingOutputDirectory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let inputDirectory = root.appendingPathComponent("barcode13", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
        let chunk = inputDirectory.appendingPathComponent("chunk-1.fastq")
        let barcodesCSV = root.appendingPathComponent("NB13_MHC-I_plate1.barcodes.csv")
        let outputDirectory = root.appendingPathComponent("mhc-pacbio-demux", isDirectory: true)

        let read = String(repeating: "A", count: 2500)
        try writeFASTQ(records: [
            ("read-1", read),
        ], to: chunk)
        try """
        sample,barcode
        32286-001_DL46,BC1001
        """.write(to: barcodesCSV, atomically: true, encoding: .utf8)

        do {
            _ = try await ONTPacBioBarcodeDemuxMaterializer().run(
                ONTPacBioBarcodeDemuxMaterializationRequest(
                    inputURL: inputDirectory,
                    barcodeDefinitionsURL: barcodesCSV,
                    outputDirectory: outputDirectory,
                    force: true,
                    threads: 1,
                    chunkJobs: 8,
                    maxReadsPerSlice: 1,
                    maxInputBytesPerCutadapt: 1
                ),
                progress: { _, _ in }
            )
            XCTFail("Expected malformed PacBio sample sheet to fail validation")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("sample_id,barcode_1,barcode_2"), message)
            XCTAssertTrue(message.contains("BC1001"), message)
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputDirectory.path))
        }
    }

    private func writeFASTQ(records: [(String, String)], to url: URL) throws {
        let text = records.map { identifier, sequence in
            "@\(identifier)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
        }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func reverseComplement(_ sequence: String) -> String {
        let complements: [Character: Character] = [
            "A": "T",
            "C": "G",
            "G": "C",
            "T": "A",
            "N": "N",
        ]
        return String(sequence.reversed().map { complements[$0] ?? "N" })
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func temporaryDirectory() throws -> URL {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTPacBioBarcodeDemuxMaterializerTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathExtension("lungfish")
        let url = projectURL.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

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
