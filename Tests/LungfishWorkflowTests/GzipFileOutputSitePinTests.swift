// GzipFileOutputSitePinTests.swift - Pins of the gzip streams that write a file, from before Phase 2.13 lane 13.07
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

/// The sites that run `gzip` into a file or feed it from a writer: `gzipCompressFASTQ` (Fastp runner), the
/// counted materializer, the exact PacBio barcode materializer and the Viral Recon gzip sink. Each pin holds the
/// recorded argv, every byte of the gzip member (header included) and the failure words, and it passes unchanged
/// before and after the sites move onto `ToolProcess`.
final class GzipFileOutputSitePinTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "gzip-file-output-pins")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(scratch)
    }

    private static let fixture = Data("@r1\nACGTACGTAC\n+\nIIIIIIIIII\n@r2\nTTGCAACGGT\n+\nHHHHHHHHHH\n".utf8)

    /// SHA-256 of `gzip -c reads.fastq` for `fixture`, with the file's modification time set to 1700000000.
    private static let fastpDigest = "8a81f4cd94064dbc3b4ad4126c498c15aeceb30c8f1da55ad10f7e37f1f3ff90"

    private static func fastq(_ records: [(String, String)]) -> String {
        records.map { "@\($0.0)\n\($0.1)\n+\n\(String(repeating: "I", count: $0.1.count))\n" }.joined()
    }

    private static func reverseComplement(_ sequence: String) -> String {
        let complement: [Character: Character] = ["A": "T", "C": "G", "G": "C", "T": "A"]
        return String(sequence.reversed().map { complement[$0] ?? "N" })
    }

    // MARK: - FastpPairedRunner.swift gzipCompressFASTQ

    func testFastpGzipKeepsTheRecordedArgvTheMemberBytesAndTheSourceName() throws {
        let source = scratch.appendingPathComponent("reads.fastq")
        let output = scratch.appendingPathComponent("reads.fastq.gz")
        try Self.fixture.write(to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: source.path
        )
        try Data("stale".utf8).write(to: output)

        let result = try gzipCompressFASTQ(sourceURL: source, outputURL: output, failureDescription: "the pin copy of")

        XCTAssertEqual(result.command, ["/usr/bin/gzip", "-c", source.path])
        XCTAssertEqual(result.inputURL, source)
        XCTAssertEqual(result.outputURL, output)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertGreaterThanOrEqual(result.wallTime, 0)
        let bytes = try Data(contentsOf: output)
        XCTAssertEqual(GzipPin.sha256Hex(bytes), Self.fastpDigest)
        let (header, raw) = try GzipPin.assertGzipOfNamedFile(bytes, flags: [], scratch: scratch)
        XCTAssertEqual(header.name, "reads.fastq")
        XCTAssertEqual(header.modificationTime, 1_700_000_000)
        XCTAssertEqual(raw, Self.fixture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the source stays in place")
    }

    func testFastpGzipFailureNamesTheDescriptionTheOutputAndTheGzipMessage() throws {
        let missing = scratch.appendingPathComponent("missing.fastq")
        let output = scratch.appendingPathComponent("missing.fastq.gz")
        XCTAssertThrowsError(
            try gzipCompressFASTQ(sourceURL: missing, outputURL: output, failureDescription: "the pin copy of")
        ) { error in
            XCTAssertEqual(
                (error as? FastpPairedRunError)?.message,
                "gzip failed while compressing the pin copy of \(output.path): "
                    + "gzip: can't stat: \(missing.path) (\(missing.path)): No such file or directory"
            )
        }
    }

    // MARK: - CountedFASTQMaterializer.swift gzipCompress

    func testCountedGzipRecordsTheArgvAndWritesLevelOneBytesNamedAfterTheRawFile() async throws {
        let input = scratch.appendingPathComponent("input.fastq")
        let output = scratch.appendingPathComponent("counted.fastq.gz")
        try "@read1\nacgt\n+\nIIII\n@read2\nACGT\n+\nIIII\n@read3;size=3\nTTTT\n+\nIIII\n"
            .write(to: input, atomically: true, encoding: .utf8)

        let result = try await CountedFASTQMaterializer().materialize(
            inputs: [input], outputURL: output, compress: true
        )

        let compression = try XCTUnwrap(result.compression)
        XCTAssertEqual(compression.command, ["/usr/bin/gzip", "-1", "-c", result.materializedOutput.path])
        XCTAssertEqual(compression.exitCode, 0)
        XCTAssertEqual(compression.output.path, output.path)
        let bytes = try Data(contentsOf: output)
        let (header, raw) = try GzipPin.assertGzipOfNamedFile(bytes, flags: ["-1"], scratch: scratch)
        XCTAssertEqual(header.name, URL(fileURLWithPath: result.materializedOutput.path).lastPathComponent)
        XCTAssertEqual(header.extraFlags, 4, "gzip -1 marks the fastest algorithm")
        XCTAssertFalse(raw.isEmpty)
    }

    // MARK: - ONTPacBioBarcodeDemuxMaterializer.swift gzipFile

    func testPacBioExactDemuxGzipRunWritesNoNameNoDateBytesAndRecordsItsArgv() async throws {
        let inputDirectory = scratch.appendingPathComponent("barcode13", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
        let barcodesCSV = scratch.appendingPathComponent("NB13_MHC-I_plate1.barcodes.csv")
        let forward = "CACATATCAGAGTGCG"
        let reverse = "CTATACATAGTGATGT"
        let insert = String(repeating: "ACGT", count: 510)
        let read = String(repeating: "T", count: 60) + forward + insert
            + Self.reverseComplement(reverse) + String(repeating: "A", count: 60)
        try Self.fastq([("read-1", read)]).write(
            to: inputDirectory.appendingPathComponent("chunk-1.fastq"), atomically: true, encoding: .utf8
        )
        try "32286-001_DL46,BC1001,BC1021\n".write(to: barcodesCSV, atomically: true, encoding: .utf8)

        let result = try await ONTPacBioBarcodeDemuxMaterializer().run(
            ONTPacBioBarcodeDemuxMaterializationRequest(
                inputURL: inputDirectory,
                barcodeDefinitionsURL: barcodesCSV,
                outputDirectory: scratch.appendingPathComponent("mhc-pacbio-demux", isDirectory: true),
                force: true,
                threads: 1,
                chunkJobs: 2,
                maxReadsPerSlice: 0
            ),
            progress: { _, _ in }
        )

        XCTAssertEqual(result.assignedReadCount, 1)
        let bundle = try XCTUnwrap(result.outputBundleURLs.first)
        let fastqGz = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        XCTAssertEqual(fastqGz.lastPathComponent, "32286-001_DL46.fastq.gz")
        let bytes = try Data(contentsOf: fastqGz)
        let (header, raw) = try GzipPin.assertGzipOfNamedFile(bytes, flags: ["-n"], scratch: scratch)
        XCTAssertNil(header.name, "gzip -n stores no name")
        XCTAssertEqual(header.modificationTime, 0, "gzip -n stores no date")
        XCTAssertEqual(header.flags, 0)
        XCTAssertTrue(String(decoding: raw, as: UTF8.self).hasPrefix("@read-1"))

        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: result.manifestURL)) as? [String: Any]
        )
        let runs = try XCTUnwrap(manifest["gzipRuns"] as? [[String: Any]])
        XCTAssertEqual(runs.count, 1)
        let argv = try XCTUnwrap(runs[0]["argv"] as? [String])
        XCTAssertEqual(argv.count, 4)
        XCTAssertEqual(Array(argv.prefix(3)), ["/usr/bin/gzip", "-n", "-c"])
        XCTAssertEqual(runs[0]["input"] as? String, argv[3])
        XCTAssertEqual(runs[0]["exitStatus"] as? Int, 0)
        XCTAssertEqual(
            (runs[0]["output"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent },
            "32286-001_DL46.fastq.gz"
        )
    }

    // MARK: - ViralReconReadPairing.swift GzipFileSink

    func testViralReconGzipSinkWritesTheWrittenBytesAsOneGzipMember() throws {
        let destination = scratch.appendingPathComponent("mate_1.fastq.gz")
        let sink = try GzipFileSink(destination: destination)
        let half = Self.fixture.count / 2
        try sink.writeHandle.write(contentsOf: Self.fixture.prefix(half))
        try sink.writeHandle.write(contentsOf: Self.fixture.dropFirst(half))
        try sink.finish()
        try sink.finish()

        let bytes = try Data(contentsOf: destination)
        let (header, raw) = try GzipPin.assertGzipOfStandardInput(bytes)
        XCTAssertNil(header.name, "gzip reading standard input stores no name")
        XCTAssertEqual(header.flags, 0)
        XCTAssertEqual(raw, Self.fixture)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + ".tmp"))
    }

    func testViralReconGzipSinkAbortRemovesTheFileAndEndsGzipAtOnce() throws {
        let destination = scratch.appendingPathComponent("mate_2.fastq.gz")
        let sink = try GzipFileSink(destination: destination)
        try sink.writeHandle.write(contentsOf: Self.fixture)
        let started = Date()
        sink.abort()
        sink.abort()
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
