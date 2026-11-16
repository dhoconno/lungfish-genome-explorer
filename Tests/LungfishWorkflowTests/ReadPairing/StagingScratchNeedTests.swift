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

    /// D1b at 19,279,040 pairs: the trim peaked at 31.7 times its 604,385,740 gzip bytes and the Viral Recon staging at
    /// 2.9 times. The need is 40 times and 4 times, so each carries a margin over the measurement. A plain file counts
    /// at its size and a gzip file at ten times its size, as D1b's reads expanded.
    func testNeedIsTheMeasuredMultipleOfTheReads() throws {
        XCTAssertEqual(StagingScratchNeed.needBytes(plainBytes: 0, gzipBytes: 604_385_740, route: .fastpTrim), 24_175_429_600)
        XCTAssertEqual(StagingScratchNeed.needBytes(plainBytes: 0, gzipBytes: 604_385_740, route: .viralReconStaging), 2_417_542_960)
        XCTAssertEqual(StagingScratchNeed.needBytes(plainBytes: 6_000_000_000, gzipBytes: 0, route: .fastpTrim), 24_000_000_000)
        XCTAssertEqual(StagingScratchNeed.needBytes(plainBytes: 1_000_000_000, gzipBytes: 0, route: .viralReconStaging), 400_000_000)
        XCTAssertEqual(StagingScratchNeed.needBytes(plainBytes: -5, gzipBytes: -5, route: .fastpTrim), 0)
        XCTAssertEqual(StagingScratchNeed.needBytes(plainBytes: Int64.max, gzipBytes: 0, route: .fastpTrim), Int64.max)
        XCTAssertEqual(StagingScratchNeed.needBytes(plainBytes: 0, gzipBytes: Int64.max, route: .viralReconStaging), Int64.max)

        let plain = root.appendingPathComponent("reads.fastq")
        let packed = root.appendingPathComponent("reads.fastq.gz")
        try Data(repeating: 0x41, count: 1_000).write(to: plain)
        try Data(repeating: 0x42, count: 100).write(to: packed)
        XCTAssertEqual(StagingScratchNeed.needBytes(inputFiles: [plain, packed], route: .fastpTrim), 8_000)
        XCTAssertEqual(StagingScratchNeed.needBytes(inputFiles: [plain, packed], route: .viralReconStaging), 800)
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
