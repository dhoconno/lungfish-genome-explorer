// ReadDepthCapTests.swift - Depth-capped viewport read fetch (owner decision D9)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A uniform `--subsample` over a mixed-depth window hollows the shallow
// flanks (50x drawn at ~4x) to afford the deep block. The depth cap thins
// only the bins above the cap. These tests pin the plan arithmetic and, on a
// real synthetic BAM, the provider contract: flanks keep every read, the deep
// block is drawn at about the cap, each read appears once, and repeat fetches
// are identical.

import XCTest
@testable import LungfishIO
import LungfishCore
import LungfishTestSupport

final class ReadDepthCapPlanTests: XCTestCase {

    func testFractionIsOneAtOrUnderTheCap() {
        XCTAssertEqual(ReadDepthCapPlan.quantizedFraction(maxDepth: 0, cap: 500), 1)
        XCTAssertEqual(ReadDepthCapPlan.quantizedFraction(maxDepth: 500, cap: 500), 1)
    }

    func testFractionIsQuantizedDownToSqrtTwoSteps() {
        // Exact powers stay exact.
        XCTAssertEqual(ReadDepthCapPlan.quantizedFraction(maxDepth: 1_000, cap: 500), 0.5, accuracy: 1e-12)
        XCTAssertEqual(ReadDepthCapPlan.quantizedFraction(maxDepth: 2_000, cap: 500), 0.25, accuracy: 1e-12)
        // 5,000x under a 500x cap wants 0.1 and gets 2^-3.5 = 0.0884 (442x).
        XCTAssertEqual(ReadDepthCapPlan.quantizedFraction(maxDepth: 5_000, cap: 500), pow(2, -3.5), accuracy: 1e-12)
        // 501x wants 0.998 and gets 2^-0.5.
        XCTAssertEqual(ReadDepthCapPlan.quantizedFraction(maxDepth: 501, cap: 500), pow(2, -0.5), accuracy: 1e-12)
        // The quantized fraction never lets expected depth exceed the cap.
        for depth in stride(from: 501, through: 1_000_000, by: 7_919) {
            let fraction = ReadDepthCapPlan.quantizedFraction(maxDepth: depth, cap: 500)
            XCTAssertLessThanOrEqual(fraction * Double(depth), 500.000_001, "depth \(depth)")
            XCTAssertGreaterThan(fraction * Double(depth), 500 / 2.0.squareRoot() - 0.001, "depth \(depth)")
        }
    }

    func testBinSizeIsAboutOneKilobaseAndBoundedInCount() {
        XCTAssertEqual(ReadDepthCapPlan.binSize(forSpan: 60_000), 1_000)
        XCTAssertEqual(ReadDepthCapPlan.binSize(forSpan: 12_000), 300)
        XCTAssertEqual(ReadDepthCapPlan.binSize(forSpan: 1_000), 100)
        let huge = ReadDepthCapPlan.binSize(forSpan: 10_000_000)
        XCTAssertLessThanOrEqual(10_000_000 / huge, 512)
    }

    func testAdjacentBinsWithTheSameFractionMergeIntoOneRegion() {
        let groups = ReadDepthCapPlan.groups(
            binFractions: [1, 1, 0.5, 0.5, 1, 0.25],
            windowStart: 1_000, windowEnd: 6_500, binSize: 1_000
        )
        XCTAssertEqual(groups.map(\.fraction), [1, 0.5, 0.25], "highest fraction first")
        XCTAssertEqual(groups[0].regions, [1_000..<3_000, 5_000..<6_000])
        XCTAssertEqual(groups[1].regions, [3_000..<5_000])
        XCTAssertEqual(groups[2].regions, [6_000..<6_500], "the last bin is clipped to the window end")
    }

    func testPlanKeepsShallowBinsWholeAndThinsDeepBins() {
        // 0..<2000 at 50x, 2000..<3000 at 5,000x, 3000..<4000 at 50x.
        let depth = (0..<4_000).map { (position: $0, depth: (2_000..<3_000).contains($0) ? 5_000 : 50) }
        let plan = ReadDepthCapPlan.make(
            depth: depth, windowStart: 0, windowEnd: 4_000, maxDisplayedDepth: 500, binSize: 1_000
        )
        XCTAssertEqual(plan.binFractions.count, 4)
        XCTAssertEqual(plan.binFractions[0], 1)
        XCTAssertEqual(plan.binFractions[1], 1)
        XCTAssertEqual(plan.binFractions[2], pow(2, -3.5), accuracy: 1e-12)
        XCTAssertEqual(plan.binFractions[3], 1)
        XCTAssertEqual(plan.groups.count, 2, "one samtools call per distinct fraction")
        XCTAssertTrue(plan.isSampled)
        XCTAssertEqual(plan.peakDepth, 5_000)
        XCTAssertEqual(plan.maxDisplayedDepth, 500)
    }

    func testReadsBeforeTheWindowBelongToTheFirstBin() {
        let plan = ReadDepthCapPlan.make(
            depth: [(position: 100, depth: 10)], windowStart: 100, windowEnd: 1_100,
            maxDisplayedDepth: 500, binSize: 250
        )
        XCTAssertEqual(plan.binIndex(forReadStart: 0), 0)
        XCTAssertEqual(plan.binIndex(forReadStart: 349), 0)
        XCTAssertEqual(plan.binIndex(forReadStart: 350), 1)
        XCTAssertEqual(plan.binIndex(forReadStart: 5_000), 3, "clamped to the last bin")
    }

    func testBaseBudgetLowersTheCapAndReportsTheLoweredCap() {
        let depth = (0..<10_000).map { (position: $0, depth: 5_000) }
        let plan = ReadDepthCapPlan.make(
            depth: depth, windowStart: 0, windowEnd: 10_000, maxDisplayedDepth: 5_000,
            maxDisplayedBases: 1_000_000, binSize: 1_000
        )
        XCTAssertLessThanOrEqual(plan.expectedDisplayedBases, 1_000_000)
        XCTAssertLessThan(plan.maxDisplayedDepth, 5_000)
        XCTAssertGreaterThan(plan.expectedDisplayedBases, 1_000_000 / 2)
    }
}

final class ReadDepthCapProviderTests: XCTestCase {

    private var samtoolsPath: String?
    private var workDir: URL?

    override func setUp() async throws {
        try await super.setUp()
        do {
            samtoolsPath = try await ToolAvailability.require("samtools", environment: "samtools").path
        } catch {
            samtoolsPath = nil
        }
    }

    override func tearDown() {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
        super.tearDown()
    }

    /// Writes a single-end BAM: flank reads start every `flankStride` bp and
    /// deep-block reads `deepCopies` per bp, all `readLength` bp long. Read
    /// groups alternate "a"/"b".
    private func makeMixedDepthBAM(
        contigLength: Int, deepBlock: Range<Int>, readLength: Int,
        flankStride: Int, deepCopies: Int
    ) throws -> (bam: String, bai: String, readCount: Int) {
        guard let samtoolsPath else { throw XCTSkip("samtools not available") }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("depth-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workDir = dir
        let samURL = dir.appendingPathComponent("reads.sam")
        FileManager.default.createFile(atPath: samURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: samURL)
        var buffer = "@HD\tVN:1.6\tSO:coordinate\n@SQ\tSN:synth\tLN:\(contigLength)\n@RG\tID:a\n@RG\tID:b\n"
        let seq = String(repeating: "A", count: readLength)
        let qual = String(repeating: "I", count: readLength)
        var count = 0
        for position in 0...(contigLength - readLength) {
            let copies: Int
            if deepBlock.contains(position) {
                copies = deepCopies
            } else {
                copies = position % flankStride == 0 ? 1 : 0
            }
            for _ in 0..<copies {
                count += 1
                buffer += "r\(count)\t0\tsynth\t\(position + 1)\t60\t\(readLength)M\t*\t0\t0\t\(seq)\t\(qual)\tRG:Z:\(count % 2 == 0 ? "a" : "b")\n"
            }
            if buffer.utf8.count > 4 << 20 {
                handle.write(Data(buffer.utf8)); buffer = ""
            }
        }
        handle.write(Data(buffer.utf8))
        try handle.close()
        let bam = dir.appendingPathComponent("reads.bam").path
        try run(samtoolsPath, ["sort", "-@", "4", "-o", bam, samURL.path])
        try run(samtoolsPath, ["index", bam])
        return (bam, bam + ".bai", count)
    }

    private func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AlignmentFetchError.samtoolsFailed("samtools \(arguments.first ?? "") failed")
        }
    }

    private func displayedDepth(_ reads: [AlignedRead], window: Range<Int>) -> [Int] {
        var depth = [Int](repeating: 0, count: window.count)
        for read in reads {
            let lower = max(window.lowerBound, read.position)
            let upper = min(window.upperBound, read.alignmentEnd)
            guard upper > lower else { continue }
            for position in lower..<upper { depth[position - window.lowerBound] += 1 }
        }
        return depth
    }

    func testDepthCapKeepsShallowFlanksWholeAndThinsTheDeepBlock() async throws {
        guard samtoolsPath != nil else { throw XCTSkip("samtools not available") }
        // 12 kb contig, 300 bp bins. Flanks 20x (100 bp reads every 5 bp);
        // bin-aligned block 3,900..<8,100 at 1,000x (10 reads per bp).
        let contigLength = 12_000
        let deep = 3_900..<8_100
        let built = try makeMixedDepthBAM(
            contigLength: contigLength, deepBlock: deep, readLength: 100, flankStride: 5, deepCopies: 10
        )
        let provider = AlignmentDataProvider(alignmentPath: built.bam, indexPath: built.bai)
        let cap = 100

        let all = try await provider.fetchReads(chromosome: "synth", start: 0, end: contigLength, maxReads: 1_000_000)
        XCTAssertEqual(all.count, built.readCount)

        let sketch = try await provider.fetchDepthCappedReads(
            chromosome: "synth", start: 0, end: contigLength, maxDisplayedDepth: cap
        )
        XCTAssertEqual(sketch.plan.binSize, 300)
        XCTAssertTrue(sketch.isDepthCapped)
        XCTAssertFalse(sketch.transportTruncated)
        XCTAssertEqual(sketch.samtoolsCalls, 3, "one depth query plus one view per distinct fraction")

        // Each read appears exactly once.
        let names = sketch.reads.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "no duplicate reads")

        // Flanks keep every read. The bin right of the block (8,100..<8,400)
        // still holds deep reads spilling past 8,100, so it is thinned too.
        let shallow: (Int) -> Bool = { $0 < deep.lowerBound || $0 >= deep.upperBound + 300 }
        XCTAssertTrue(all.filter { shallow($0.position) }.allSatisfy { sketch.plan.fraction(forReadStart: $0.position) == 1 })
        let flankNames = Set(all.filter { shallow($0.position) }.map(\.name))
        let keptFlank = Set(sketch.reads.filter { shallow($0.position) }.map(\.name))
        XCTAssertEqual(keptFlank, flankNames, "reads in bins at or under the cap are all shown")

        // Flank reads that span a bin boundary (start and end in different
        // 300 bp bins) are present, exactly once.
        let spanning = all.filter {
            shallow($0.position) && $0.position / 300 != ($0.alignmentEnd - 1) / 300
        }
        XCTAssertFalse(spanning.isEmpty)
        let counts = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
        for read in spanning { XCTAssertEqual(counts[read.name], 1, read.name) }

        // The deep block is drawn at about the cap, never far above it.
        let depth = displayedDepth(sketch.reads, window: 0..<contigLength)
        let deepInterior = depth[(deep.lowerBound + 100)..<(deep.upperBound - 100)]
        let mean = Double(deepInterior.reduce(0, +)) / Double(deepInterior.count)
        XCTAssertGreaterThan(mean, Double(cap) / 2, "deep block keeps a useful sample")
        XCTAssertLessThanOrEqual(mean, Double(cap), "mean displayed depth respects the cap")
        // Sampling noise plus one-read-length boundary spill from a 20x flank.
        XCTAssertLessThanOrEqual(depth.max() ?? 0, cap * 3 / 2, "peak displayed depth stays near the cap")

        // The estimate is close to the true count.
        XCTAssertTrue(sketch.isEstimated)
        XCTAssertEqual(Double(sketch.estimatedTotalReads), Double(built.readCount), accuracy: Double(built.readCount) * 0.05)

        // Deterministic across runs.
        let again = try await provider.fetchDepthCappedReads(
            chromosome: "synth", start: 0, end: contigLength, maxDisplayedDepth: cap
        )
        XCTAssertEqual(again.reads.map(\.name), names)
    }

    func testWindowUnderTheCapIsReturnedWholeWithAnExactCount() async throws {
        guard samtoolsPath != nil else { throw XCTSkip("samtools not available") }
        let built = try makeMixedDepthBAM(
            contigLength: 6_000, deepBlock: 0..<0, readLength: 100, flankStride: 5, deepCopies: 0
        )
        let provider = AlignmentDataProvider(alignmentPath: built.bam, indexPath: built.bai)
        let sketch = try await provider.fetchDepthCappedReads(
            chromosome: "synth", start: 0, end: 6_000, maxDisplayedDepth: 500
        )
        XCTAssertFalse(sketch.isDepthCapped)
        XCTAssertFalse(sketch.isEstimated)
        XCTAssertEqual(sketch.reads.count, built.readCount)
        XCTAssertEqual(sketch.estimatedTotalReads, built.readCount)
        XCTAssertEqual(sketch.samtoolsCalls, 2)
    }

    func testReadGroupFilterAppliesToTheDepthQueryAndTheFetch() async throws {
        guard samtoolsPath != nil else { throw XCTSkip("samtools not available") }
        let deep = 3_900..<8_100
        let built = try makeMixedDepthBAM(
            contigLength: 12_000, deepBlock: deep, readLength: 100, flankStride: 5, deepCopies: 10
        )
        let provider = AlignmentDataProvider(alignmentPath: built.bam, indexPath: built.bai)
        let depth = try await provider.fetchReadFilterDepth(
            chromosome: "synth", start: 0, end: 12_000, excludeFlags: 0x904, minMapQ: 0, readGroups: ["a"]
        )
        let peak = depth.map(\.depth).max() ?? 0
        XCTAssertEqual(Double(peak), 500, accuracy: 10, "depth counts only read group a (half of 1,000x)")

        let sketch = try await provider.fetchDepthCappedReads(
            chromosome: "synth", start: 0, end: 12_000, readGroups: ["a"], maxDisplayedDepth: 100
        )
        XCTAssertFalse(sketch.reads.isEmpty)
        XCTAssertTrue(sketch.reads.allSatisfy { $0.readGroup == "a" })
    }

    func testReadCeilingReportsTransportTruncation() async throws {
        guard samtoolsPath != nil else { throw XCTSkip("samtools not available") }
        let built = try makeMixedDepthBAM(
            contigLength: 6_000, deepBlock: 0..<0, readLength: 100, flankStride: 5, deepCopies: 0
        )
        let provider = AlignmentDataProvider(alignmentPath: built.bam, indexPath: built.bai)
        let sketch = try await provider.fetchDepthCappedReads(
            chromosome: "synth", start: 0, end: 6_000, maxDisplayedDepth: 500, maxReads: 100
        )
        XCTAssertTrue(sketch.transportTruncated)
        XCTAssertLessThanOrEqual(sketch.reads.count, 100)
    }

    /// Opt-in timing guard on the orchestrator's prototype shape: 60 kb, 50x
    /// flanks, a 20 kb block at 5,000x, 150 bp reads (~680k reads). Building
    /// the BAM is too slow for the unit tier, so it follows the existing
    /// `LUNGFISH_PERF_BAM_BENCH=1` opt-in.
    func testDepthCappedFetchTimeOnLargeMixedDepthBAM() async throws {
        guard samtoolsPath != nil else { throw XCTSkip("samtools not available") }
        guard ProcessInfo.processInfo.environment["LUNGFISH_PERF_BAM_BENCH"] == "1" else {
            throw XCTSkip("opt-in perf benchmark; set LUNGFISH_PERF_BAM_BENCH=1 to run")
        }
        let deep = 20_000..<40_000
        // 50x at 150 bp is one read per 3 bp; 5,000x is ~33 reads per bp.
        let built = try makeMixedDepthBAM(
            contigLength: 60_000, deepBlock: deep, readLength: 150, flankStride: 3, deepCopies: 33
        )
        let provider = AlignmentDataProvider(alignmentPath: built.bam, indexPath: built.bai)
        let start = Date()
        let sketch = try await provider.fetchDepthCappedReads(
            chromosome: "synth", start: 0, end: 60_000, maxDisplayedDepth: 500
        )
        let elapsed = Date().timeIntervalSince(start)
        let depth = displayedDepth(sketch.reads, window: 0..<60_000)
        let flankMean = Double(depth[1_000..<19_000].reduce(0, +)) / 18_000
        let deepMean = Double(depth[21_000..<39_000].reduce(0, +)) / 18_000
        print("[perf] depth cap: \(sketch.reads.count) of \(built.readCount) reads, \(sketch.samtoolsCalls) samtools calls, \(String(format: "%.3f", elapsed)) s, flank \(String(format: "%.1f", flankMean))x, deep \(String(format: "%.1f", deepMean))x")
        // The replaced path, for comparison: count + one uniform subsample.
        let uniformStart = Date()
        let uniform = try await provider.fetchReadSketch(
            chromosome: "synth", start: 0, end: 60_000, targetReads: 50_000
        )
        let uniformElapsed = Date().timeIntervalSince(uniformStart)
        let uniformDepth = displayedDepth(uniform.reads, window: 0..<60_000)
        let uniformFlank = Double(uniformDepth[1_000..<19_000].reduce(0, +)) / 18_000
        print("[perf] uniform 50k sketch: \(uniform.reads.count) reads, \(String(format: "%.3f", uniformElapsed)) s, flank \(String(format: "%.1f", uniformFlank))x")
        XCTAssertLessThan(elapsed, 5)
        XCTAssertGreaterThan(flankMean, 45)
        XCTAssertLessThanOrEqual(deepMean, 500)
    }
}
