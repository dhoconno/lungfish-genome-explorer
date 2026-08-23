// ReadRowAllocatorTests.swift - Oracle + performance tests for O(n log n) read packing
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore

/// The heap/segment-tree packer must place every read in exactly the row the
/// old linear first-fit scan placed it in. These tests keep that original scan
/// as an executable oracle and compare row-for-row over randomized inputs.
@MainActor
final class ReadRowAllocatorTests: XCTestCase {

    // MARK: - Oracle (the pre-optimization linear packer, verbatim)

    /// The row-assignment loop exactly as it read before the segment tree
    /// replaced it. Sorting/prioritization is shared with the real packer, so
    /// only the assignment half is duplicated here.
    private func oracleAssign(
        ordered: [AlignedRead],
        frame: ReferenceFrame,
        maxRows: Int?
    ) -> (packed: [(row: Int, read: AlignedRead)], overflow: Int) {
        let rowCap = maxRows.flatMap { $0 > 0 ? $0 : nil }
        var rowEndPixels = rowCap.map { [CGFloat](repeating: -1, count: $0) } ?? []
        var packed: [(Int, AlignedRead)] = []
        var overflow = 0

        for read in ordered {
            let startPx = frame.genomicToPixel(Double(read.position))
            let endPx = frame.genomicToPixel(Double(read.alignmentEnd))
            guard endPx - startPx >= ReadTrackRenderer.minReadPixels else { continue }

            var placed = false
            if let rowCap {
                for row in 0..<rowCap where startPx >= rowEndPixels[row] + 2 {
                    packed.append((row, read))
                    rowEndPixels[row] = endPx
                    placed = true
                    break
                }
                if !placed { overflow += 1 }
            } else {
                for row in rowEndPixels.indices where startPx >= rowEndPixels[row] + 2 {
                    packed.append((row, read))
                    rowEndPixels[row] = endPx
                    placed = true
                    break
                }
                if !placed {
                    let newRow = rowEndPixels.count
                    rowEndPixels.append(endPx)
                    packed.append((newRow, read))
                }
            }
        }
        return (packed, overflow)
    }

    // MARK: - Fixtures

    private func makeRead(
        name: String,
        position: Int,
        length: Int,
        chromosome: String = "chr1"
    ) -> AlignedRead {
        let seq = String(repeating: "A", count: max(1, length))
        return AlignedRead(
            name: name,
            flag: 0,
            chromosome: chromosome,
            position: position,
            mapq: 60,
            cigar: [CIGAROperation(op: .match, length: max(1, length))],
            sequence: seq,
            qualities: Array(repeating: 30, count: seq.count)
        )
    }

    private func makeFrame(start: Double, end: Double, pixelWidth: Int) -> ReferenceFrame {
        ReferenceFrame(chromosome: "chr1", start: start, end: end, pixelWidth: pixelWidth)
    }

    /// Deterministic PRNG so a failure is always reproducible from its seed.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    // MARK: - Oracle equivalence

    func testHeapPackerMatchesLinearOracleOverRandomInputs() {
        for seed in 0..<1_000 {
            var rng = SeededGenerator(seed: UInt64(seed) &+ 1)

            let regionSpan = Int.random(in: 200...20_000, using: &rng)
            let pixelWidth = Int.random(in: 200...1_600, using: &rng)
            let frame = makeFrame(start: 0, end: Double(regionSpan), pixelWidth: pixelWidth)

            let readCount = Int.random(in: 0...120, using: &rng)
            var reads: [AlignedRead] = []
            reads.reserveCapacity(readCount)
            for index in 0..<readCount {
                let position = Int.random(in: 0..<max(1, regionSpan), using: &rng)
                // Deliberately include reads short enough to be dropped by the
                // `minReadPixels` guard, so the filter is exercised too.
                let length = Int.random(in: 1...max(2, regionSpan / 10), using: &rng)
                reads.append(makeRead(name: "r\(index)", position: position, length: length))
            }

            // Cover unlimited rows, tight caps, and generous caps.
            let capChoice = Int.random(in: 0...3, using: &rng)
            let maxRows: Int? = [nil, 1, 5, 75][capChoice]
            let usePriority = Bool.random(using: &rng)
            let priorityLow = Int.random(in: 0..<max(1, regionSpan), using: &rng)
            let prioritized: Range<Int>? = usePriority
                ? priorityLow..<(priorityLow + max(1, regionSpan / 4))
                : nil

            // The oracle only re-implements row assignment, so feed it the same
            // ordering the real packer builds internally.
            let ordered = ReadTrackRenderer.orderReadsForPacking(
                reads,
                sortMode: .position,
                sortPosition: nil,
                prioritizedRegion: prioritized
            )
            let expected = oracleAssign(ordered: ordered, frame: frame, maxRows: maxRows)
            let actual = ReadTrackRenderer.packReads(
                reads,
                frame: frame,
                maxRows: maxRows,
                sortMode: .position,
                prioritizedRegion: prioritized
            )

            XCTAssertEqual(
                actual.overflow, expected.overflow,
                "overflow mismatch for seed \(seed)"
            )
            XCTAssertEqual(
                actual.packed.count, expected.packed.count,
                "placed-read count mismatch for seed \(seed)"
            )
            guard actual.packed.count == expected.packed.count else { continue }
            for index in actual.packed.indices {
                XCTAssertEqual(
                    actual.packed[index].row, expected.packed[index].row,
                    "row mismatch at \(index) for seed \(seed)"
                )
                XCTAssertEqual(
                    actual.packed[index].read.id, expected.packed[index].read.id,
                    "read identity/order mismatch at \(index) for seed \(seed)"
                )
            }
        }
    }

    func testHeapPackerMatchesOracleForNonPositionSortModes() {
        let modes: [ReadSortMode] = [
            .position, .readName, .strand, .mappingQuality, .insertSize,
        ]
        for (modeIndex, mode) in modes.enumerated() {
            var rng = SeededGenerator(seed: UInt64(9_000 + modeIndex))
            let frame = makeFrame(start: 0, end: 5_000, pixelWidth: 800)
            var reads: [AlignedRead] = []
            for index in 0..<200 {
                reads.append(
                    makeRead(
                        name: String(format: "read%04d", Int.random(in: 0...9_999, using: &rng)),
                        position: Int.random(in: 0..<5_000, using: &rng),
                        length: Int.random(in: 50...400, using: &rng)
                    )
                )
            }
            for maxRows in [nil, 8, 75] as [Int?] {
                let ordered = ReadTrackRenderer.orderReadsForPacking(
                    reads, sortMode: mode, sortPosition: nil, prioritizedRegion: nil
                )
                let expected = oracleAssign(ordered: ordered, frame: frame, maxRows: maxRows)
                let actual = ReadTrackRenderer.packReads(
                    reads, frame: frame, maxRows: maxRows, sortMode: mode
                )
                XCTAssertEqual(actual.overflow, expected.overflow, "mode \(mode) cap \(String(describing: maxRows))")
                XCTAssertEqual(actual.packed.map(\.row), expected.packed.map(\.row), "mode \(mode) cap \(String(describing: maxRows))")
            }
        }
    }

    func testHeapPackerMatchesOracleForBaseAtPositionSort() {
        var rng = SeededGenerator(seed: 4_242)
        let frame = makeFrame(start: 0, end: 3_000, pixelWidth: 900)
        var reads: [AlignedRead] = []
        for index in 0..<250 {
            reads.append(
                makeRead(
                    name: "r\(index)",
                    position: Int.random(in: 0..<3_000, using: &rng),
                    length: Int.random(in: 60...500, using: &rng)
                )
            )
        }
        for maxRows in [nil, 4, 75] as [Int?] {
            let ordered = ReadTrackRenderer.orderReadsForPacking(
                reads, sortMode: .baseAtPosition, sortPosition: 1_500, prioritizedRegion: nil
            )
            let expected = oracleAssign(ordered: ordered, frame: frame, maxRows: maxRows)
            let actual = ReadTrackRenderer.packReads(
                reads, frame: frame, maxRows: maxRows, sortMode: .baseAtPosition, sortPosition: 1_500
            )
            XCTAssertEqual(actual.overflow, expected.overflow)
            XCTAssertEqual(actual.packed.map(\.row), expected.packed.map(\.row))
        }
    }

    // MARK: - Allocator unit behavior

    func testAllocatorPlacesInLowestFittingRowIndex() {
        var allocator = ReadRowAllocator(rowCap: nil)
        // Three overlapping reads open rows 0, 1, 2.
        XCTAssertEqual(allocator.place(startPx: 0, endPx: 100, gap: 2).rowValue, 0)
        XCTAssertEqual(allocator.place(startPx: 10, endPx: 200, gap: 2).rowValue, 1)
        XCTAssertEqual(allocator.place(startPx: 20, endPx: 50, gap: 2).rowValue, 2)
        // Row 2 frees first by end pixel, but row 0 is the lowest *index* that
        // fits at startPx 210, and first-fit must prefer it.
        XCTAssertEqual(allocator.place(startPx: 210, endPx: 300, gap: 2).rowValue, 0)
    }

    func testAllocatorReportsOverflowWhenCapped() {
        var allocator = ReadRowAllocator(rowCap: 2)
        // Rows start at end pixel -1, so a read must begin at >= 1 to take a
        // fresh row — exactly as the linear scan's `startPx >= -1 + 2` did.
        XCTAssertEqual(allocator.place(startPx: 1, endPx: 100, gap: 2).rowValue, 0)
        XCTAssertEqual(allocator.place(startPx: 5, endPx: 100, gap: 2).rowValue, 1)
        XCTAssertNil(allocator.place(startPx: 10, endPx: 100, gap: 2).rowValue)
    }

    func testAllocatorGrowsBeyondInitialCapacity() {
        var allocator = ReadRowAllocator(rowCap: nil, expectedRows: 2)
        for index in 0..<500 {
            // Every read overlaps every other, forcing a fresh row each time.
            XCTAssertEqual(allocator.place(startPx: 0, endPx: 1_000, gap: 2).rowValue, index)
        }
        XCTAssertEqual(allocator.rowCount, 500)
    }

    // MARK: - Performance

    /// 600k reads in a ~100 bp microsatellite window is the shape that hung the
    /// viewport. Guarded because a debug-configuration CI machine is not a
    /// meaningful timing environment.
    func testPacks600kReadsUnderTwoSeconds() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LUNGFISH_PERF_TESTS"] == "1",
            "Set LUNGFISH_PERF_TESTS=1 to run read-packing performance tests"
        )
        var rng = SeededGenerator(seed: 777)
        let frame = makeFrame(start: 0, end: 120, pixelWidth: 1_200)
        var reads: [AlignedRead] = []
        reads.reserveCapacity(600_000)
        for index in 0..<600_000 {
            reads.append(
                makeRead(
                    name: "r\(index)",
                    position: Int.random(in: 0..<100, using: &rng),
                    length: Int.random(in: 80...150, using: &rng)
                )
            )
        }
        // Row assignment is the half this work made `O(n log rows)`; the sort
        // that precedes it is inherent to any packer and was never the hang.
        // Timing them separately keeps the assertion pointed at the change.
        let ordered = ReadTrackRenderer.orderReadsForPacking(
            reads, sortMode: .position, sortPosition: nil, prioritizedRegion: nil
        )
        let started = Date()
        let result = ReadTrackRenderer.assignRows(
            ordered: ordered, frame: ReadPackFrame(frame), maxRows: nil
        )
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertFalse(result.packed.isEmpty)
        XCTAssertLessThan(elapsed, 2.0, "row assignment for 600k reads took \(elapsed)s")
    }

    /// The realistic hot path: the display budget caps the packed set at 50k, so
    /// a whole pack — sort included — has to stay well inside a frame budget's
    /// worth of background work.
    func testPacksBudgetedReadSetQuickly() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LUNGFISH_PERF_TESTS"] == "1",
            "Set LUNGFISH_PERF_TESTS=1 to run read-packing performance tests"
        )
        var rng = SeededGenerator(seed: 778)
        let frame = makeFrame(start: 0, end: 120, pixelWidth: 1_200)
        let budget = ReadViewportPolicy.defaultVisibleReadBudget
        var reads: [AlignedRead] = []
        reads.reserveCapacity(budget)
        for index in 0..<budget {
            reads.append(
                makeRead(
                    name: "r\(index)",
                    position: Int.random(in: 0..<100, using: &rng),
                    length: Int.random(in: 80...150, using: &rng)
                )
            )
        }
        let started = Date()
        let result = ReadTrackRenderer.packReads(
            reads, frame: frame, maxRows: nil, sortMode: .position
        )
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertFalse(result.packed.isEmpty)
        XCTAssertLessThan(elapsed, 2.0, "packing a budgeted \(budget)-read set took \(elapsed)s")
    }
}

private extension ReadRowAllocator.Placement {
    /// Row index, or nil for overflow — keeps the assertions terse.
    var rowValue: Int? {
        switch self {
        case .placed(let row): return row
        case .overflow: return nil
        }
    }
}
