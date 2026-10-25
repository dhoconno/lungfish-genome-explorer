// ClumpifyDiskNeedTests.swift - A Mac import refuses a sample whose disk cannot hold clumpify's work
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishIO
import LungfishTestSupport

/// Before each sample's clumpify the Mac import needs free space of five times the sample's read files on the disk that
/// holds clumpify's work folder, or that sample is refused (C5 lane DISK, the BIO and QA ruling). The tests replace the
/// free-space reader for one import and read errors, the folders the reader was asked about, the progress the pipeline
/// reported and the files on disk. None of them needs a managed tool: the refusal and the pass both come before any
/// tool starts, and a run that goes on without the tools ends in another error.
final class ClumpifyDiskNeedTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "clumpify-disk-need")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// C4's node run: 422,847,301 bytes of reads need 2,114,236,505 bytes (2.1 GB) free.
    func testClumpifyDiskNeedIsFiveTimesInputBytes() {
        XCTAssertEqual(ClumpifyDiskNeed.needBytes(inputBytes: 422_847_301), 2_114_236_505)
        XCTAssertEqual(ClumpifyDiskNeed.needBytes(inputBytes: 60_000_000_000), 300_000_000_000, "a 60 GB sample needs 300 GB")
        XCTAssertEqual(ClumpifyDiskNeed.needBytes(inputBytes: 0), 0)
        XCTAssertEqual(ClumpifyDiskNeed.needBytes(inputBytes: -1), 0, "a negative size counts as zero")
        XCTAssertEqual(ClumpifyDiskNeed.needBytes(inputBytes: Int64.max), Int64.max, "an overflow saturates and never wraps")
    }

    /// Free space of one byte less than the need refuses the sample. The batch records it as a failed sample through
    /// its own failure path, writes no bundle, and the pipeline reports no clumpify progress and writes nothing.
    func testImportRefusesClumpifyBelowDiskNeed() async throws {
        let run = "SRR9100002"
        let reads = try writeReads("\(run).fastq")
        let need = ClumpifyDiskNeed.needBytes(inputBytes: try byteCount(of: reads))
        let free = need - 1
        let project = try makeProject()

        let askedAbout = Recorder<URL>()
        let events = Recorder<ImportLogEvent>()
        let samples = FASTQBatchImporter.detectPairs(from: [reads])
        XCTAssertEqual(samples.map(\.sampleName), [run])
        let result = await ClumpifyDiskNeed.$freeSpaceReader.withValue({ folder in
            askedAbout.add(folder)
            return free
        }) {
            await FASTQBatchImporter.runBatchImport(
                pairs: samples,
                config: importConfig(project: project, clumpingTool: .bbtools),
                log: { events.add($0) }
            )
        }

        XCTAssertEqual(result.completed, 0)
        XCTAssertEqual(result.failed, 1)
        let failure = try XCTUnwrap(result.errors.first)
        XCTAssertEqual(failure.sample, run)
        let needText = ByteCountFormatter.string(fromByteCount: need, countStyle: .file)
        let freeText = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        XCTAssertTrue(failure.error.hasPrefix("\(run) needs about \(needText) free for clumpify"), failure.error)
        XCTAssertTrue(failure.error.contains("has \(freeText) free"), failure.error)
        XCTAssertTrue(failure.error.contains("--clumping-tool none"), failure.error)
        let failedLines = events.all.compactMap { event -> String? in
            if case .sampleFailed(let sample, let error) = event, sample == run { return error }
            return nil
        }
        XCTAssertEqual(failedLines, [failure.error], "the batch's one sampleFailed event carries the refusal")
        let finished = events.all.filter { if case .stepComplete = $0 { return true } else { return false } }
        XCTAssertTrue(finished.isEmpty, "the storage step never finished for the sample")
        XCTAssertEqual(askedAbout.all.count, 1, "the reader was asked once for the sample")
        XCTAssertTrue(
            askedAbout.all.first?.path.contains("/.tmp/fastq-import-") == true,
            "the reader was asked about the sample's workspace in the project's .tmp folder"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: FASTQBatchImporter.bundleOutputURL(for: samples[0], in: project).path),
            "no bundle"
        )

        // The pipeline alone: the refusal comes before the sort step reports anything, and nothing is written.
        let outputDirectory = root.appendingPathComponent("refused-output", isDirectory: true)
        let progress = Recorder<String>()
        do {
            _ = try await ClumpifyDiskNeed.$freeSpaceReader.withValue({ _ in free }) {
                try await FASTQIngestionPipeline().run(
                    config: pipelineConfig(reads, outputDirectory: outputDirectory, clumpingTool: .bbtools),
                    progress: { _, message in progress.add(message) }
                )
            }
            XCTFail("the sample should be refused")
        } catch let error as FASTQIngestionError {
            guard case .insufficientDiskForClumpify(let sample, let needBytes, let freeBytes, let folder) = error else {
                return XCTFail("expected the disk refusal, got \(error)")
            }
            XCTAssertEqual(sample, run)
            XCTAssertEqual(needBytes, need)
            XCTAssertEqual(freeBytes, free)
            XCTAssertEqual(folder.standardizedFileURL, outputDirectory.standardizedFileURL)
            XCTAssertEqual(error.errorDescription, failure.error.replacingOccurrences(
                of: askedAbout.all.first?.path ?? "", with: outputDirectory.path
            ), "the pipeline's refusal reads as the batch's")
        }
        XCTAssertTrue(progress.all.isEmpty, "clumpify was never started: \(progress.all)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path), [], "nothing was written")
        XCTAssertTrue(FileManager.default.fileExists(atPath: reads.path), "the reads are untouched")
    }

    /// Free space equal to the need passes, and the pipeline goes on to clumpify.
    func testImportClumpsAtExactDiskNeed() async throws {
        let reads = try writeReads("SRR9100003.fastq")
        let need = ClumpifyDiskNeed.needBytes(inputBytes: try byteCount(of: reads))
        let outputDirectory = root.appendingPathComponent("exact-output", isDirectory: true)
        let askedAbout = Recorder<URL>()
        let progress = Recorder<String>()

        var result: FASTQIngestionResult?
        var thrown: Error?
        do {
            result = try await ClumpifyDiskNeed.$freeSpaceReader.withValue({ folder in
                askedAbout.add(folder)
                return need
            }) {
                try await FASTQIngestionPipeline().run(
                    config: pipelineConfig(reads, outputDirectory: outputDirectory, clumpingTool: .bbtools),
                    progress: { _, message in progress.add(message) }
                )
            }
        } catch {
            thrown = error
        }

        XCTAssertEqual(askedAbout.all.map(\.standardizedFileURL), [outputDirectory.standardizedFileURL])
        XCTAssertEqual(progress.all.first, "Sorting reads by k-mer similarity...", "the pipeline went on to clumpify")
        if let thrown {
            // Without the managed tools the run ends in the tools' own error. It is never the disk refusal.
            if case .insufficientDiskForClumpify? = thrown as? FASTQIngestionError {
                XCTFail("free space equal to the need was refused: \(thrown)")
            }
        } else {
            XCTAssertEqual(result?.processingTool, "clumpify.sh")
        }
    }

    /// A volume that does not answer lets the import go ahead, with one log line that names the folder.
    func testDiskCheckFailsOpenWhenVolumeUnreadable() async throws {
        let reads = try writeReads("SRR9100004.fastq")
        let outputDirectory = root.appendingPathComponent("unreadable-output", isDirectory: true)

        let verdict = ClumpifyDiskNeed.verdict(inputFiles: [reads], folder: outputDirectory, freeSpace: { _ in nil })
        guard case .unreadable(let logLine) = verdict else { return XCTFail("expected unreadable, got \(verdict)") }
        XCTAssertTrue(logLine.contains(outputDirectory.path), logLine)
        XCTAssertNil(ClumpifyDiskNeed.volumeFreeSpace(root.appendingPathComponent("no-such-folder")))
        XCTAssertGreaterThan(ClumpifyDiskNeed.volumeFreeSpace(root) ?? 0, 0, "the Mac's reader answers for a real folder")

        let progress = Recorder<String>()
        let askedAbout = Recorder<URL>()
        var thrown: Error?
        do {
            _ = try await ClumpifyDiskNeed.$freeSpaceReader.withValue({ folder in
                askedAbout.add(folder)
                return nil
            }) {
                try await FASTQIngestionPipeline().run(
                    config: pipelineConfig(reads, outputDirectory: outputDirectory, clumpingTool: .bbtools),
                    progress: { _, message in progress.add(message) }
                )
            }
        } catch {
            thrown = error
        }
        XCTAssertEqual(
            askedAbout.all.map(\.standardizedFileURL), [outputDirectory.standardizedFileURL],
            "the reader was asked once about the work folder"
        )
        XCTAssertEqual(progress.all.first, "Sorting reads by k-mer similarity...", "the import went ahead")
        if case .insufficientDiskForClumpify? = thrown as? FASTQIngestionError {
            XCTFail("an unreadable volume refused the sample: \(String(describing: thrown))")
        }
    }

    /// `--clumping-tool none` and Trim Galore run no BBTools clumpify, so neither asks the reader, even on a full disk.
    func testNoDiskCheckWithoutClumpify() async throws {
        let run = "SRR9100005"
        let reads = try writeReads("\(run).fastq")
        let project = try makeProject()
        let askedAbout = Recorder<URL>()

        let result = await ClumpifyDiskNeed.$freeSpaceReader.withValue({ folder in
            askedAbout.add(folder)
            return 0
        }) {
            await FASTQBatchImporter.runBatchImport(
                pairs: FASTQBatchImporter.detectPairs(from: [reads]),
                config: importConfig(project: project, clumpingTool: ClumpingTool.none)
            )
        }
        XCTAssertFalse(result.errors.contains { $0.error.contains("free for clumpify") }, "\(result.errors)")

        for tool in [ClumpingTool.none, ClumpingTool.trimGalore] {
            do {
                _ = try await ClumpifyDiskNeed.$freeSpaceReader.withValue({ folder in
                    askedAbout.add(folder)
                    return 0
                }) {
                    try await FASTQIngestionPipeline().run(
                        config: pipelineConfig(
                            reads, outputDirectory: root.appendingPathComponent("\(tool.rawValue)-output", isDirectory: true),
                            clumpingTool: tool
                        ),
                        progress: { _, _ in }
                    )
                }
            } catch {
                if case .insufficientDiskForClumpify? = error as? FASTQIngestionError {
                    XCTFail("\(tool.rawValue) was refused for disk: \(error)")
                }
            }
        }
        XCTAssertTrue(askedAbout.all.isEmpty, "the reader was asked about \(askedAbout.all)")
    }

    // MARK: - Helpers

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

    private func makeProject() throws -> URL {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }

    private func importConfig(project: URL, clumpingTool: ClumpingTool) -> FASTQBatchImporter.ImportConfig {
        FASTQBatchImporter.ImportConfig(
            projectDirectory: project,
            platform: .given(.illumina),
            qualityBinning: QualityBinningScheme.none,
            optimizeStorage: true,
            clumpingTool: clumpingTool,
            threads: 2
        )
    }

    private func pipelineConfig(_ reads: URL, outputDirectory: URL, clumpingTool: ClumpingTool) -> FASTQIngestionConfig {
        FASTQIngestionConfig(
            inputFiles: [reads],
            pairingMode: .singleEnd,
            outputDirectory: outputDirectory,
            threads: 2,
            deleteOriginals: false,
            clumpingTool: clumpingTool
        )
    }

    private func byteCount(of url: URL) throws -> Int64 {
        Int64(try Data(contentsOf: url).count)
    }

    /// 40 reads of 100 bases, long enough for clumpify's 31-base k-mers.
    private func writeReads(_ name: String) throws -> URL {
        let folder = root.appendingPathComponent("reads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        let alphabet: [Character] = ["A", "C", "G", "T"]
        let text = (1...40).map { spot -> String in
            var state = UInt64(truncatingIfNeeded: spot) &* 0x9E37_79B9_7F4A_7C15 &+ 1
            let bases = String((0..<100).map { _ -> Character in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return alphabet[Int((state >> 33) % 4)]
            })
            return "@read.\(spot) \(spot) length=100\n\(bases)\n+\n\(String(repeating: "I", count: 100))\n"
        }.joined()
        try Data(text.utf8).write(to: url)
        return url
    }
}
