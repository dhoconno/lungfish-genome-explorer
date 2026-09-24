// ReadViewportSpreadSamplingTests.swift - The viewport's overflow sample must
// span the whole fetch window, not just its coordinate-sorted prefix.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Root cause this guards against: a window with more reads than the display
// budget used to be fetched with a plain `samtools view` capped at
// `budget + 1`, which returns the FIRST reads in coordinate order. An even
// stride over that already-clustered prefix only ever sampled the leftmost
// slice of the window. `AlignmentDataProvider.fetchReadSketch` fixes this by
// counting the window first (`samtools view -c`, index-only) and then, when
// the count exceeds the target, fetching with `samtools --subsample` so the
// kept reads are drawn from across the whole region.
//
// These tests build a real, coordinate-sorted BAM with a read starting at
// every position across a contig (so "spread across deciles" is unambiguous)
// and exercise `fetchReadSketch` against the managed samtools binary.

import XCTest
@testable import LungfishIO
import LungfishCore
import LungfishTestSupport

final class ReadViewportSpreadSamplingTests: XCTestCase {

    private var samtoolsPath: String?
    private var workDir: URL?

    override func setUp() async throws {
        try await super.setUp()
        do {
            let url = try await ToolAvailability.require("samtools", environment: "samtools")
            samtoolsPath = url.path
        } catch {
            samtoolsPath = nil
        }
    }

    override func tearDown() {
        if let workDir {
            try? FileManager.default.removeItem(at: workDir)
        }
        workDir = nil
        super.tearDown()
    }

    /// Builds a coordinate-sorted, indexed BAM on a single contig with one
    /// 100 bp read starting at every position from 0 to `contigLength -
    /// readLength`, so the contig has `contigLength - readLength + 1` reads
    /// uniformly spread from end to end.
    private func makeUniformlySpreadBAM(
        contigName: String = "synthcontig",
        contigLength: Int,
        readLength: Int = 100,
        stride: Int = 1,
        readsPerPosition: Int = 1
    ) throws -> (bamPath: String, indexPath: String, readCount: Int) {
        guard let samtoolsPath else {
            throw XCTSkip("samtools not available")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spread-sampling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workDir = dir

        let samPath = dir.appendingPathComponent("reads.sam").path
        var sam = "@HD\tVN:1.6\tSO:coordinate\n"
        sam += "@SQ\tSN:\(contigName)\tLN:\(contigLength)\n"
        var readCount = 0
        var position = 0
        let seq = String(repeating: "A", count: readLength)
        let qual = String(repeating: "I", count: readLength)
        while position + readLength <= contigLength {
            for copy in 0..<readsPerPosition {
                readCount += 1
                let name = "r\(readCount)_p\(position)_\(copy)"
                // 1-based POS for SAM.
                sam += "\(name)\t0\t\(contigName)\t\(position + 1)\t60\t\(readLength)M\t*\t0\t0\t\(seq)\t\(qual)\n"
            }
            position += stride
        }
        try sam.write(toFile: samPath, atomically: true, encoding: .utf8)

        let bamPath = dir.appendingPathComponent("reads.bam").path
        try runSamtools(samtoolsPath, ["sort", "-o", bamPath, samPath])
        try runSamtools(samtoolsPath, ["index", bamPath])

        return (bamPath, bamPath + ".bai", readCount)
    }

    private func runSamtools(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTFail("samtools \(arguments.joined(separator: " ")) failed: \(err)")
            throw AlignmentFetchError.samtoolsFailed(err)
        }
    }

    /// Splits `range` into `bins` equal buckets and returns true iff every
    /// bucket contains at least one of `positions`.
    private func spansEveryDecile(_ positions: [Int], range: Range<Int>, bins: Int = 10) -> Bool {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return false }
        let binWidth = max(1, span / bins)
        var covered = Array(repeating: false, count: bins)
        for position in positions {
            let offset = position - range.lowerBound
            guard offset >= 0 else { continue }
            let bin = min(bins - 1, offset / binWidth)
            covered[bin] = true
        }
        return covered.allSatisfy { $0 }
    }

    // MARK: - Behavioural: overflow sample spans the window

    func testOverflowSampleSpansEveryDecileOfTheWindow() async throws {
        guard samtoolsPath != nil else { throw XCTSkip("samtools not available") }
        // 20,000 reads across a 20,100 bp contig (one read per position),
        // sampled down to a budget of 2,000 — comfortably over budget so the
        // old bug (prefix-then-stride) would visibly cluster near position 0.
        let contigLength = 20_100
        let built = try makeUniformlySpreadBAM(contigLength: contigLength, readLength: 100, stride: 1)
        XCTAssertGreaterThan(built.readCount, 15_000)

        let provider = AlignmentDataProvider(alignmentPath: built.bamPath, indexPath: built.indexPath)
        let sketch = try await provider.fetchReadSketch(
            chromosome: "synthcontig", start: 0, end: contigLength,
            targetReads: 2_000
        )

        XCTAssertTrue(sketch.isSubsampled)
        XCTAssertLessThanOrEqual(sketch.reads.count, 2_000 * 2, "sketch fetch parses at most ~2x target before trimming")
        XCTAssertGreaterThan(sketch.reads.count, 0)
        XCTAssertEqual(sketch.estimatedTotalReads, built.readCount)

        let positions = sketch.reads.map(\.position)
        XCTAssertTrue(
            spansEveryDecile(positions, range: 0..<contigLength),
            "sampled positions must cover every decile of the window, not just the leftmost slice"
        )
        // The old bug's signature: every kept read clustered under the first
        // ~budget positions. Assert the sample reaches well past that.
        XCTAssertGreaterThan(positions.max() ?? 0, contigLength / 2)
    }

    func testBelowBudgetWindowIsReturnedInFullAndUnsampled() async throws {
        guard samtoolsPath != nil else { throw XCTSkip("samtools not available") }
        let contigLength = 2_100
        let built = try makeUniformlySpreadBAM(contigLength: contigLength, readLength: 100, stride: 1)

        let provider = AlignmentDataProvider(alignmentPath: built.bamPath, indexPath: built.indexPath)
        let sketch = try await provider.fetchReadSketch(
            chromosome: "synthcontig", start: 0, end: contigLength,
            targetReads: 50_000
        )

        XCTAssertFalse(sketch.isSubsampled, "a window under budget must not be sampled at all")
        XCTAssertEqual(sketch.reads.count, built.readCount)
        XCTAssertEqual(sketch.estimatedTotalReads, built.readCount)
    }

    func testSampleSizeNeverExceedsRequestedTarget() async throws {
        guard samtoolsPath != nil else { throw XCTSkip("samtools not available") }
        let contigLength = 10_100
        let built = try makeUniformlySpreadBAM(contigLength: contigLength, readLength: 100, stride: 1)

        let provider = AlignmentDataProvider(alignmentPath: built.bamPath, indexPath: built.indexPath)
        let sketch = try await provider.fetchReadSketch(
            chromosome: "synthcontig", start: 0, end: contigLength,
            targetReads: 500
        )
        // fetchReadSketch parses up to 2x target from the subsampled stream
        // before any final view-side trim; the viewport's own budget trim
        // (ReadViewportPolicy.sampleReads) is what brings it down to exactly
        // the display budget. Assert the raw sketch stays within that 2x
        // ceiling rather than silently growing unbounded.
        XCTAssertLessThanOrEqual(sketch.reads.count, 1_000)
    }

    func testFetchIsDeterministicAcrossRepeatedCalls() async throws {
        guard samtoolsPath != nil else { throw XCTSkip("samtools not available") }
        let contigLength = 10_100
        let built = try makeUniformlySpreadBAM(contigLength: contigLength, readLength: 100, stride: 1)
        let provider = AlignmentDataProvider(alignmentPath: built.bamPath, indexPath: built.indexPath)

        let first = try await provider.fetchReadSketch(
            chromosome: "synthcontig", start: 0, end: contigLength, targetReads: 500
        )
        let second = try await provider.fetchReadSketch(
            chromosome: "synthcontig", start: 0, end: contigLength, targetReads: 500
        )

        XCTAssertEqual(first.reads.map(\.name), second.reads.map(\.name), "the fixed subsample seed must make the sample stable across redraws and runs")
    }

    // MARK: - Performance: whole-contig window on a large synthetic BAM

    /// Not a correctness assertion — logs fetch time before/after the fix for
    /// the release-notes/report comparison the brief asks for. Skipped by
    /// default (opt in with LUNGFISH_PERF_BAM_BENCH=1) since building a
    /// multi-million-read BAM is too slow for the default unit tier.
    func testFetchTimeOnLargeSyntheticBAM() async throws {
        guard samtoolsPath != nil else { throw XCTSkip("samtools not available") }
        guard ProcessInfo.processInfo.environment["LUNGFISH_PERF_BAM_BENCH"] == "1" else {
            throw XCTSkip("opt-in perf benchmark; set LUNGFISH_PERF_BAM_BENCH=1 to run")
        }
        // ~3M reads piled onto a 30 kb contig (viral-genome scale): 100 reads
        // starting at every position, the same "microsatellite at extreme
        // depth" shape that motivated the budget in the first place.
        let contigLength = 30_000
        let built = try makeUniformlySpreadBAM(
            contigLength: contigLength, readLength: 150, stride: 1, readsPerPosition: 100
        )
        let provider = AlignmentDataProvider(alignmentPath: built.bamPath, indexPath: built.indexPath)

        let sketchStart = Date()
        let sketch = try await provider.fetchReadSketch(
            chromosome: "synthcontig", start: 0, end: contigLength, targetReads: 50_000
        )
        let sketchElapsed = Date().timeIntervalSince(sketchStart)

        let prefixStart = Date()
        let prefixReads = try await provider.fetchReads(
            chromosome: "synthcontig", start: 0, end: contigLength, maxReads: 50_001
        )
        let prefixElapsed = Date().timeIntervalSince(prefixStart)

        print("[perf] spread sketch: \(sketch.reads.count) reads in \(sketchElapsed)s; old prefix fetch: \(prefixReads.count) reads in \(prefixElapsed)s (contig=\(built.readCount) reads)")
        XCTAssertGreaterThan(sketch.reads.count, 0)
    }
}
