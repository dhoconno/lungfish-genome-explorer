// StagingScratchNeedTests.swift - the fixed-order staging refuses a disk too small for its scratch, before it writes any
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Row FASTP-STAGING-MEMORY (ruling BIO-ROWS-1-3, item 6). The fastp trims (`fastq trim`, quality-trim, adapter-trim and
// fixed-trim, through FastpPairedRunner) and the Viral Recon staging write the reads out again in a seeded order. D1b
// measured the trim at 18,693,724 KB of scratch for 604,385,740 bytes of gzip reads, and the Viral Recon staging at
// 1,719,860 KB, and neither said anything before the run. Each now compares the free space of the disk that holds its
// work with a need taken from that run, and refuses with words when the disk has less. The tests replace the free-space
// reader for one run, so no test needs a full disk or a managed tool.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class StagingScratchNeedTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "staging-scratch-need")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// Collects what a `@Sendable` callback reports, in order.
    private final class Recorder<Element: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Element] = []

        func add(_ item: Element) {
            lock.lock()
            defer { lock.unlock() }
            items.append(item)
        }

        var all: [Element] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    /// A stand-in fastp that counts its calls and fails, so a run that passes the disk check ends in fastp's own error.
    private func failingFastp(_ calls: Recorder<String>) -> FastpPairedRunner.Executor {
        { tool, arguments in
            calls.add(tool.rawValue)
            return NativeToolResult(exitCode: 1, stdout: "", stderr: "stand-in fastp", arguments: arguments)
        }
    }

    private func gigabytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - The need

    /// A gzip file whose statistics sidecar states `reads` reads of `bases` bases in all, as an import writes it.
    private func gzipFile(_ name: String, bytes: Int, statingReads reads: Int?, bases: Int64 = 0) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        if let reads {
            let statistics = FASTQDatasetStatistics(
                readCount: reads, baseCount: bases,
                meanReadLength: 75, minReadLength: 75, maxReadLength: 76, medianReadLength: 75, n50ReadLength: 75,
                meanQuality: 30, q20Percentage: 95, q30Percentage: 90, gcContent: 0.4,
                readLengthHistogram: [75: reads], qualityScoreHistogram: [:], perPositionQuality: []
            )
            try FASTQMetadataStore.write(PersistedFASTQMetadata(computedStatistics: statistics), for: url)
        }
        return url
    }

    /// D1b at 19,279,040 pairs held 7,740,781,880 bytes of text in 604,385,740 bytes of gzip. The trim's work peaked at
    /// 18,693,724 KB, 2.47 times the text, and the Viral Recon staging at 1,719,860 KB, 0.23 times. D1b's reads are 84%
    /// duplicates with one constant quality line, which LZ4 packs far below ordinary reads: 45,574 real HG002 chr20
    /// pairs, shuffled as bucket entries and packed with compression_tool, came to 0.644 of the text. The need is three
    /// times and three quarters of the text, rounded up, so the Viral Recon figure carries a margin of 1.16 over that.
    func testNeedIsTheMeasuredMultipleOfTheText() {
        XCTAssertEqual(StagingScratchNeed.needBytes(textBytes: 7_740_781_880, route: .fastpTrim), 23_222_345_640)
        XCTAssertEqual(StagingScratchNeed.needBytes(textBytes: 7_740_781_880, route: .viralReconStaging), 5_805_586_410)
        XCTAssertEqual(StagingScratchNeed.needBytes(textBytes: 3, route: .viralReconStaging), 3, "rounded up")
        XCTAssertEqual(StagingScratchNeed.needBytes(textBytes: -5, route: .fastpTrim), 0)
        XCTAssertEqual(StagingScratchNeed.needBytes(textBytes: Int64.max, route: .fastpTrim), Int64.max)
        XCTAssertEqual(StagingScratchNeed.needBytes(textBytes: Int64.max, route: .viralReconStaging), Int64.max)
    }

    /// The text is what each file states (F2): a plain file its size, a gzip file the reads and bases of its sidecar at two
    /// bytes a base and 64 a read. D1b's 7,740,781,880 bytes of text stated that way are 8,240,007,312, 6% over. Only a
    /// gzip file that states nothing is counted at a ratio, four times its size, as ordinary unclumped reads pack, so an
    /// ordinary run that fits is not refused for a ratio of clumped reads.
    func testTheTextIsWhatTheFilesState() throws {
        let plain = root.appendingPathComponent("reads.fastq")
        try Data(repeating: 0x41, count: 1_000).write(to: plain)
        let stated = try gzipFile("stated.fastq.gz", bytes: 100, statingReads: 10, bases: 1_500)
        let unstated = try gzipFile("unstated.fastq.gz", bytes: 100, statingReads: nil)
        let d1b = try gzipFile("d1b.fastq.gz", bytes: 1_000, statingReads: 38_558_080, bases: 2_886_145_096)
        // A sidecar that states less text than the gzip file holds bytes describes another file, so it states nothing.
        let stale = try gzipFile("stale.fastq.gz", bytes: 10_000, statingReads: 1, bases: 10)

        XCTAssertEqual(ReadTextSize.stated(by: plain), 1_000)
        XCTAssertEqual(ReadTextSize.stated(by: stated), 3_640)
        XCTAssertNil(ReadTextSize.stated(by: unstated))
        XCTAssertEqual(ReadTextSize.stated(by: d1b), 8_240_007_312)
        XCTAssertNil(ReadTextSize.stated(by: stale))
        XCTAssertEqual(StagingScratchNeed.needBytes(inputFiles: [plain, stated, unstated], route: .fastpTrim), 3 * (1_000 + 3_640 + 400))
        XCTAssertEqual(StagingScratchNeed.needBytes(inputFiles: [plain, stated, unstated], route: .viralReconStaging), 3_780)
        XCTAssertEqual(StagingScratchNeed.needBytes(inputFiles: [stale], route: .fastpTrim), 3 * 40_000)
    }

    /// F1: a gzip bundle file of 1.2 M pairs (12,177,543 bytes, 475,153,254 bytes of text) was counted at four times its
    /// size, so all its text went into one bucket and the Viral Recon staging peaked at 1.8 GB. The bucket count now
    /// follows the text the sidecar states, and a gzip file that states nothing counts at forty times its size, as the
    /// most packed of D1b's inputs held 39 times.
    func testBucketCountFollowsTheStatedText() throws {
        let stated = try gzipFile("p1200k.fastq.gz", bytes: 1_000_000, statingReads: 2_400_000, bases: 179_644_531)
        XCTAssertEqual(SeededPairOrder.bucketCount(for: [stated]), 8, "512,889,062 bytes of stated text in 64 MiB buckets")
        let unstated = try gzipFile("unstated.fastq.gz", bytes: 2_000_000, statingReads: nil)
        XCTAssertEqual(SeededPairOrder.bucketCount(for: [unstated]), 2, "80,000,000 bytes at forty times the gzip size")
    }

    // MARK: - fastp trim

    /// One byte under the need refuses the trim before it makes its scratch folder, starts fastp or writes the output.
    func testTrimRefusesBelowTheNeedBeforeAnyWork() async throws {
        let input = root.appendingPathComponent("pairs.fastq")
        try InterleavedFASTQFixture.write(pairCount: 40, naming: .casava, to: input)
        let output = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let need = StagingScratchNeed.needBytes(inputFiles: [input], route: .fastpTrim)
        XCTAssertGreaterThan(need, 0)
        let free = need - 1
        let asked = Recorder<URL>()
        let calls = Recorder<String>()

        do {
            _ = try await StagingScratchNeed.$freeSpaceReader.withValue({ folder in
                asked.add(folder)
                return free
            }) {
                try await FastpPairedRunner.run(
                    inputURL: input, outputPath: output.appendingPathComponent("trimmed.fastq").path,
                    plan: .interleaved(pairs: 40), options: ["-w", "1"], detectPairedAdapters: true,
                    failureLabel: "fastp adapter trim", stepNamePrefix: "lungfish fastq adapter-trim", execute: failingFastp(calls)
                )
            }
            XCTFail("the trim should be refused")
        } catch let error as FastpPairedRunError {
            let needText = gigabytes(need)
            XCTAssertEqual(needText, gigabytes(free), "one byte under the need reads the same in the Finder's units")
            XCTAssertTrue(error.message.hasPrefix("Trimming needs about \(needText) free"), error.message)
            XCTAssertTrue(error.message.contains("has just under \(needText) free"), error.message)
            XCTAssertTrue(error.message.contains(output.path), "the sentence names the disk's folder: \(error.message)")
            XCTAssertTrue(error.message.contains("Free up space"), "the sentence says what to do: \(error.message)")
            XCTAssertTrue(error.message.contains("nothing was trimmed"), error.message)
        }
        XCTAssertEqual(asked.all.map(\.standardizedFileURL), [output.standardizedFileURL], "the reader was asked once, about the output's folder")
        XCTAssertTrue(calls.all.isEmpty, "fastp never started: \(calls.all)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [], "no scratch folder and no output")
    }

    /// Free space equal to the need passes, and a volume that does not answer lets the trim go ahead. Both end in the
    /// stand-in fastp's own error and never in the refusal.
    func testTrimGoesAheadAtTheExactNeedAndWhenTheVolumeDoesNotAnswer() async throws {
        let input = root.appendingPathComponent("pairs.fastq")
        try InterleavedFASTQFixture.write(pairCount: 40, naming: .casava, to: input)
        let output = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let need = StagingScratchNeed.needBytes(inputFiles: [input], route: .fastpTrim)
        XCTAssertGreaterThan(need, 0)

        for free in [Optional(need), nil] {
            let calls = Recorder<String>()
            do {
                _ = try await StagingScratchNeed.$freeSpaceReader.withValue({ _ in free }) {
                    try await FastpPairedRunner.run(
                        inputURL: input, outputPath: output.appendingPathComponent("trimmed.fastq").path,
                        plan: .interleaved(pairs: 40), options: ["-w", "1"], detectPairedAdapters: true,
                        failureLabel: "fastp adapter trim", stepNamePrefix: "lungfish fastq adapter-trim", execute: failingFastp(calls)
                    )
                }
                XCTFail("the stand-in fastp fails, so the run should end in its error")
            } catch let error as FastpPairedRunError {
                XCTAssertTrue(error.message.contains("failed on the mate pairs"), error.message)
                XCTAssertFalse(error.message.contains("needs about"), "the disk check refused: \(error.message)")
            }
            XCTAssertEqual(calls.all, ["fastp"], "the run went on to fastp (free space \(String(describing: free)))")
        }
    }

    /// A single-end trim writes no scratch beside its output, so it asks the reader nothing.
    func testSingleEndTrimAsksNothingAboutTheDisk() async throws {
        let input = root.appendingPathComponent("reads.fastq")
        try InterleavedFASTQFixture.write(pairCount: 10, naming: .casava, to: input)
        let asked = Recorder<URL>()
        let calls = Recorder<String>()
        do {
            _ = try await StagingScratchNeed.$freeSpaceReader.withValue({ folder in
                asked.add(folder)
                return 0
            }) {
                try await FastpPairedRunner.run(
                    inputURL: input, outputPath: root.appendingPathComponent("single.fastq").path,
                    plan: .singleEnd, options: ["-w", "1"], detectPairedAdapters: false,
                    failureLabel: "fastp quality trim", stepNamePrefix: "lungfish fastq quality-trim", execute: failingFastp(calls)
                )
            }
            XCTFail("the stand-in fastp fails")
        } catch let error as FastpPairedRunError {
            XCTAssertFalse(error.message.contains("needs about"), error.message)
        }
        XCTAssertTrue(asked.all.isEmpty, "the reader was asked about \(asked.all)")
        XCTAssertEqual(calls.all, ["fastp"])
    }

    // MARK: - Viral Recon staging

    /// A bundle row is staged through the seeded order. One byte under the need refuses it before any file is written
    /// under the split folder, with the words the run shows for a bundle it could not stage.
    func testViralReconBundleStagingRefusesBelowTheNeedBeforeAnyWrite() async throws {
        let bundle = try InterleavedFASTQFixture.writeBundle(named: "clumped", in: root, pairCount: 40, naming: .casava)
        let bundleURL = bundle.fastqURL.deletingLastPathComponent()
        let need = StagingScratchNeed.needBytes(inputFiles: [bundle.fastqURL], route: .viralReconStaging)
        XCTAssertGreaterThan(need, 0)
        let free = need - 1
        let splitRoot = root.appendingPathComponent("split", isDirectory: true)
        try FileManager.default.createDirectory(at: splitRoot, withIntermediateDirectories: true)
        let sample = ViralReconSample(
            sampleName: "clumped", sourceBundleURL: bundleURL, fastqURLs: [bundleURL], barcode: nil, sequencingSummaryURL: nil
        )
        let asked = Recorder<URL>()

        do {
            _ = try await StagingScratchNeed.$freeSpaceReader.withValue({ folder in
                asked.add(folder)
                return free
            }) {
                try await ViralReconReadPairing.prepareIlluminaSamples([sample], splitRoot: splitRoot)
            }
            XCTFail("the staging should be refused")
        } catch let error as ViralReconReadPairing.PairingError {
            guard case .bundleStagingFailed(let name, let reason) = error else { return XCTFail("expected the staging error, got \(error)") }
            let needText = gigabytes(need)
            XCTAssertEqual(name, "clumped")
            XCTAssertTrue(reason.hasPrefix("Staging the reads for Viral Recon needs about \(needText) free"), reason)
            XCTAssertTrue(reason.contains("has just under \(needText) free"), reason)
            XCTAssertTrue(reason.contains("Free up space"), "the sentence says what to do: \(reason)")
            XCTAssertTrue(reason.contains("nothing was staged"), reason)
            XCTAssertTrue(reason.contains(splitRoot.path), "the sentence names the folder that holds the staging: \(reason)")
        }
        XCTAssertEqual(asked.all.count, 1, "the reader was asked once")
        XCTAssertTrue(asked.all.first?.standardizedFileURL.path.hasPrefix(splitRoot.standardizedFileURL.path) == true, "\(asked.all)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: splitRoot.path), [], "nothing was staged")
    }

    /// A strictly interleaved file split for Viral Recon is refused the same way, and free space equal to the need passes.
    func testViralReconSplitRefusesBelowTheNeedAndGoesAheadAtIt() async throws {
        let input = root.appendingPathComponent("pairs.fastq")
        try InterleavedFASTQFixture.write(pairCount: 40, naming: .casava, to: input)
        let need = StagingScratchNeed.needBytes(inputFiles: [input], route: .viralReconStaging)
        XCTAssertGreaterThan(need, 0)

        let refusedDirectory = root.appendingPathComponent("refused/pairs", isDirectory: true)
        do {
            _ = try await StagingScratchNeed.$freeSpaceReader.withValue({ _ in need - 1 }) {
                try await ViralReconReadPairing.splitInterleavedInput(input, into: refusedDirectory)
            }
            XCTFail("the split should be refused")
        } catch let error as StagingScratchNeed.Refusal {
            XCTAssertEqual(error.needBytes, need)
            XCTAssertEqual(error.freeBytes, need - 1)
            XCTAssertTrue(error.localizedDescription.contains("nothing was staged"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: refusedDirectory.path), "the split's folder is gone")

        let split = try await StagingScratchNeed.$freeSpaceReader.withValue({ _ in need }) {
            try await ViralReconReadPairing.splitInterleavedInput(input, into: root.appendingPathComponent("allowed/pairs", isDirectory: true))
        }
        XCTAssertEqual(split.counts.r1Records, 40, "free space equal to the need was not refused")
    }
}
