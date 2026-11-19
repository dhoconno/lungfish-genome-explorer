// DemultiplexOffsetGzipOutputTests.swift - A run that writes a line for each offset keeps every read of a large output
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// FIX-MEM-GZIP, F2 of TIMING-RELEASE. With a 5' Distance above 0 the single-index writer names the line of each offset by
// its row, `^N{a}X` for a from 0 to the distance. Cutadapt opens a writer for each line and keeps the last one of a name,
// so each other writer of the row ends its empty gzip stream, 20 bytes, at the start of the row's gzip output when
// Cutadapt closes it. An output that has passed Cutadapt's write buffer by then loses its first 20 bytes and reads as an
// empty gzip member and bytes that are no gzip stream. The check failed the run on it ("D701.fastq.gz is not a whole gzip
// file (zlib -3)"), and a run that does not check its reads counted only the reads of outputs small enough to stay
// whole. The unit tests before used outputs smaller than one 64 KB window. This test runs Cutadapt.

import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class DemultiplexOffsetGzipOutputTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemultiplexOffsetGzipOutputTests-\(UUID().uuidString).lungfish", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    }

    /// Reads of two rows of TruSeq Single Index Set A, `perRow` each, at offsets 0 to 8 behind the real P7 flank, then the
    /// index, the flank after it and 100 random bases. The name is `<row>|<n>`.
    static func reads(perRow: Int) -> [DemultiplexDualFormTests.Read] {
        var bases = DemultiplexDualFormTests.Bases()
        var reads: [DemultiplexDualFormTests.Read] = []
        let rows = BarcodeKitRegistry.truseqSingleA.barcodes.prefix(2)
        for index in 0..<perRow {
            for barcode in rows {
                let before = String(DemultiplexSingleOffsetShiftTests.truseqBefore.suffix(index % 9))
                reads.append((
                    "\(barcode.id)|\(index)",
                    before + barcode.i7Sequence + DemultiplexSingleOffsetShiftTests.truseqAfter + bases.next(100)
                ))
            }
        }
        return reads
    }

    /// The built-in TruSeq Single Index Set A at 5' End, 5' Distance 8, error rate 0.15 and 4 threads, the setup of F2, on
    /// 20,000 reads of D701 and D702. Each row's output holds 10,000 reads, several 64 KB windows of gzip. The run must end,
    /// every read must be in its own row's file, and the counts must add up to the input.
    func testATruSeqRunAtAFivePrimeDistanceKeepsEveryReadOfAnOutputOfSeveralWindows() async throws {
        let reads = Self.reads(perRow: 10_000)
        let input = dir.appendingPathComponent("truseq.fastq")
        let text = reads.map { "@\($0.name)\n\($0.sequence)\n+\n\(String(repeating: "I", count: $0.sequence.count))\n" }.joined()
        try text.write(to: input, atomically: true, encoding: .utf8)
        let output = dir.appendingPathComponent("demux", isDirectory: true)
        let config = DemultiplexConfig(
            inputURL: input, barcodeKit: BarcodeKitRegistry.truseqSingleA, outputDirectory: output,
            barcodeLocation: .fivePrime, errorRate: 0.15, maxDistanceFrom5Prime: 8, maxDistanceFrom3Prime: 0,
            trimBarcodes: true, threads: 4, engine: .cutadapt
        )
        let result = try await DemultiplexingPipeline().run(config: config, progress: { _, _ in })

        var placed: [String: Int] = [:]
        var wrong: [String] = []
        for barcode in result.manifest.barcodes {
            let bundle = output.appendingPathComponent(barcode.bundleRelativePath, isDirectory: true)
            let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle), barcode.barcodeID)
            let bytes = try XCTUnwrap(try fastq.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            XCTAssertGreaterThan(bytes, 3 * 65_536, "\(barcode.barcodeID)'s file is several 64 KB windows")
            var count = 0
            for try await record in FASTQReader(validateSequence: false).records(from: fastq) {
                count += 1
                if !record.identifier.hasPrefix(barcode.barcodeID + "|") { wrong.append("\(record.identifier) in \(barcode.barcodeID)") }
            }
            placed[barcode.barcodeID] = count
            XCTAssertEqual(barcode.readCount, count, "\(barcode.barcodeID): the manifest counts the reads its file holds")
        }
        print("GZIPOUTPUT placed \(placed.sorted { $0.key < $1.key }); unassigned \(result.manifest.unassigned.readCount); "
              + "ambiguousReads \(result.ambiguousReads.map(String.init) ?? "nil"); wrong \(wrong.prefix(8))")
        XCTAssertEqual(placed, ["D701": 10_000, "D702": 10_000])
        XCTAssertEqual(wrong, [])
        XCTAssertEqual(result.manifest.unassigned.readCount, 0)
        XCTAssertEqual(result.ambiguousReads, 0, "the run checked its reads and no two rows tied")
    }
}
