import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class ONTPacBioBarcodeDemuxMaterializerTests: XCTestCase {
    func testSampleNameResolverPreservesUniqueSampleName() throws {
        let resolved = try ONTPacBioBarcodeSampleNameResolver.resolve([
            barcodeSheetRow(2, sampleID: "Unique Sample"),
        ])

        XCTAssertEqual(resolved.map(\.resolvedSampleID), ["Unique_Sample"])
        XCTAssertEqual(resolved.map(\.originalSampleID), ["Unique Sample"])
        XCTAssertEqual(resolved.map(\.sourceRow), [2])
    }

    func testSampleNameResolverNumbersEveryRepeatedNameInSheetOrder() throws {
        let resolved = try ONTPacBioBarcodeSampleNameResolver.resolve([
            barcodeSheetRow(2, sampleID: "Repeated"),
            barcodeSheetRow(4, sampleID: "Repeated"),
            barcodeSheetRow(7, sampleID: "Repeated"),
        ])

        XCTAssertEqual(resolved.map(\.resolvedSampleID), [
            "Repeated_1",
            "Repeated_2",
            "Repeated_3",
        ])
        XCTAssertEqual(resolved.map(\.sourceRow), [2, 4, 7])
    }

    func testSampleNameResolverGroupsFilesystemEquivalentNamesIgnoringCase() throws {
        let resolved = try ONTPacBioBarcodeSampleNameResolver.resolve([
            barcodeSheetRow(2, sampleID: "Sample A"),
            barcodeSheetRow(3, sampleID: "Sample_A"),
            barcodeSheetRow(4, sampleID: "sample_a"),
        ])

        XCTAssertEqual(resolved.map(\.resolvedSampleID), [
            "Sample_A_1",
            "Sample_A_2",
            "sample_a_3",
        ])
    }

    func testSampleNameResolverRejectsGeneratedNameCollidingWithExplicitName() throws {
        XCTAssertThrowsError(try ONTPacBioBarcodeSampleNameResolver.resolve([
            barcodeSheetRow(2, sampleID: "Sample"),
            barcodeSheetRow(3, sampleID: "Sample"),
            barcodeSheetRow(8, sampleID: "Sample_1"),
        ])) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Sample_1"), message)
            XCTAssertTrue(message.contains("rows 2 and 8"), message)
        }
    }

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

    func testRepeatedPacBioSampleNamesMaterializeNumberedBundlesInSheetOrder() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let inputDirectory = root.appendingPathComponent("barcode13", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
        let chunk = inputDirectory.appendingPathComponent("chunk-1.fastq")
        let barcodesCSV = root.appendingPathComponent("repeated-samples.csv")
        let outputDirectory = root.appendingPathComponent("mhc-pacbio-demux", isDirectory: true)

        try writeFASTQ(records: [
            (
                "read-for-first-row",
                exactBarcodeRead(forward: "CACATATCAGAGTGCG", reverse: "CTATACATAGTGATGT")
            ),
            (
                "read-for-second-row",
                exactBarcodeRead(forward: "ACACACAGACTGTGAG", reverse: "CACTCACGTGTGATAT")
            ),
        ], to: chunk)
        try """
        sample_id,barcode_1,barcode_2
        LN94_Mamu-E,bc1001,bc1021

        LN94_Mamu-E,bc1002,bc1022
        LN94_Mamu-E,bc1003,bc1023
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

        XCTAssertEqual(result.outputBundleURLs.map(\.lastPathComponent).sorted(), [
            "LN94_Mamu-E_1.lungfishfastq",
            "LN94_Mamu-E_2.lungfishfastq",
        ])
        let firstFASTQ = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(
            for: outputDirectory.appendingPathComponent("LN94_Mamu-E_1.lungfishfastq")
        ))
        let secondFASTQ = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(
            for: outputDirectory.appendingPathComponent("LN94_Mamu-E_2.lungfishfastq")
        ))
        let firstRecords = try await FASTQReader(validateSequence: false).readAll(from: firstFASTQ)
        let secondRecords = try await FASTQReader(validateSequence: false).readAll(from: secondFASTQ)
        XCTAssertEqual(firstRecords.map(\.identifier), ["read-for-first-row"])
        XCTAssertEqual(secondRecords.map(\.identifier), ["read-for-second-row"])

        let manifest = try jsonObject(at: result.manifestURL)
        let nameAssignments = try XCTUnwrap(manifest["sampleNameAssignments"] as? [[String: Any]])
        XCTAssertEqual(nameAssignments.count, 3)
        XCTAssertEqual(nameAssignments.compactMap { $0["sourceRow"] as? Int }, [2, 4, 5])
        XCTAssertEqual(nameAssignments.compactMap { $0["originalSampleID"] as? String }, [
            "LN94_Mamu-E",
            "LN94_Mamu-E",
            "LN94_Mamu-E",
        ])
        XCTAssertEqual(nameAssignments.compactMap { $0["resolvedSampleID"] as? String }, [
            "LN94_Mamu-E_1",
            "LN94_Mamu-E_2",
            "LN94_Mamu-E_3",
        ])
        XCTAssertEqual(nameAssignments.compactMap { $0["barcode_1"] as? String }, [
            "bc1001",
            "bc1002",
            "bc1003",
        ])
        XCTAssertEqual(nameAssignments.compactMap { $0["barcode_2"] as? String }, [
            "bc1021",
            "bc1022",
            "bc1023",
        ])

        let firstBundleManifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(
            in: outputDirectory.appendingPathComponent("LN94_Mamu-E_1.lungfishfastq")
        ))
        let firstNotes = try XCTUnwrap(firstBundleManifest.provenance?.notes)
        XCTAssertTrue(firstNotes.contains("Original sample ID: LN94_Mamu-E"), firstNotes)
        XCTAssertTrue(firstNotes.contains("Resolved output ID: LN94_Mamu-E_1"), firstNotes)
        XCTAssertTrue(firstNotes.contains("Source row: 2"), firstNotes)
        XCTAssertTrue(firstNotes.contains("Barcode pair: bc1001 / bc1021"), firstNotes)
    }

    func testConflictingResolvedPacBioSampleNamesFailBeforeCreatingOutputDirectory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let inputDirectory = root.appendingPathComponent("barcode13", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
        let barcodesCSV = root.appendingPathComponent("conflicting-samples.csv")
        let outputDirectory = root.appendingPathComponent("mhc-pacbio-demux", isDirectory: true)
        try """
        sample_id,barcode_1,barcode_2
        Sample,bc1001,bc1021
        Sample,bc1002,bc1022
        Sample_1,bc1003,bc1023
        """.write(to: barcodesCSV, atomically: true, encoding: .utf8)

        do {
            _ = try await ONTPacBioBarcodeDemuxMaterializer().run(
                ONTPacBioBarcodeDemuxMaterializationRequest(
                    inputURL: inputDirectory,
                    barcodeDefinitionsURL: barcodesCSV,
                    outputDirectory: outputDirectory
                )
            )
            XCTFail("Expected conflicting resolved sample names to fail validation")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Sample_1"), message)
            XCTAssertTrue(message.contains("rows 2 and 4"), message)
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputDirectory.path))
        }
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

    private func barcodeSheetRow(
        _ sourceRow: Int,
        sampleID: String
    ) -> ONTPacBioBarcodeSheetAssignment {
        ONTPacBioBarcodeSheetAssignment(
            sourceRow: sourceRow,
            assignment: FASTQSampleBarcodeAssignment(
                sampleID: sampleID,
                forwardBarcodeID: "bc1001",
                reverseBarcodeID: "bc1021"
            )
        )
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

    private func exactBarcodeRead(forward: String, reverse: String) -> String {
        forward + String(repeating: "A", count: 2_050) + reverseComplement(reverse)
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
