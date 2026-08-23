// ReadBudgetAndOffMainPackTests.swift - Visible-read budget, banner, and off-main packing
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

/// An extreme-depth window must not put 600k reads on screen or pack them on
/// the main thread. These tests pin both halves of that: the budget keeps the
/// displayed set bounded and honest, and `draw(_:)` never invokes the packer.
@MainActor
final class ReadBudgetAndOffMainPackTests: XCTestCase {

    // MARK: - Fixtures

    private func makeRead(name: String, position: Int, length: Int = 150) -> AlignedRead {
        let seq = String(repeating: "A", count: length)
        return AlignedRead(
            name: name,
            flag: 0,
            chromosome: "chr1",
            position: position,
            mapq: 60,
            cigar: [CIGAROperation(op: .match, length: length)],
            sequence: seq,
            qualities: Array(repeating: 30, count: length)
        )
    }

    /// 600k reads piled into a ~100 bp microsatellite window — the shape that
    /// hung the viewport behind "Loading mapped reads...".
    private func makeExtremeDepthPile(count: Int) -> [AlignedRead] {
        (0..<count).map { makeRead(name: "r\($0)", position: 100 + ($0 % 100)) }
    }

    private func makeFrame(pixelWidth: Int = 1_200) -> ReferenceFrame {
        ReferenceFrame(chromosome: "chr1", start: 100, end: 220, pixelWidth: pixelWidth)
    }

    // MARK: - Budget

    func testExtremeDepthPileIsSampledDownToBudget() {
        let reads = makeExtremeDepthPile(count: 600_000)
        let budget = ReadViewportPolicy.defaultVisibleReadBudget

        let result = SequenceViewerView.applyReadBudget(
            reads: reads,
            budget: budget,
            exactTotal: 600_000,
            estimatedTotal: nil,
            loadedAll: false
        )

        XCTAssertEqual(result.reads.count, budget)
        XCTAssertEqual(result.state.displayedReads, budget)
        XCTAssertEqual(result.state.totalReads, 600_000)
        XCTAssertFalse(result.state.isEstimated)
        XCTAssertTrue(result.state.isSampled)
    }

    func testLoadAllPathKeepsEveryRead() {
        let reads = makeExtremeDepthPile(count: 600_000)

        let result = SequenceViewerView.applyReadBudget(
            reads: reads,
            budget: ReadViewportPolicy.defaultVisibleReadBudget,
            exactTotal: 600_000,
            estimatedTotal: nil,
            loadedAll: true
        )

        XCTAssertEqual(result.reads.count, 600_000)
        XCTAssertTrue(result.state.loadedAll)
        XCTAssertFalse(result.state.isSampled, "the banner must disappear once everything is loaded")
    }

    func testNormalDepthIsUntouchedByTheBudget() {
        // The whole point of a budget is that ordinary windows never notice it.
        let reads = makeExtremeDepthPile(count: 1_200)

        let result = SequenceViewerView.applyReadBudget(
            reads: reads,
            budget: ReadViewportPolicy.defaultVisibleReadBudget,
            exactTotal: nil,
            estimatedTotal: nil,
            loadedAll: false
        )

        XCTAssertEqual(result.reads.count, 1_200)
        XCTAssertEqual(result.reads.map(\.id), reads.map(\.id))
        XCTAssertFalse(result.state.isSampled)
        XCTAssertNil(result.state.bannerMessage)
    }

    func testSamplingIsDeterministicAndUniform() {
        let reads = makeExtremeDepthPile(count: 100_000)
        let first = ReadViewportPolicy.sampleReads(reads, budget: 10_000)
        let second = ReadViewportPolicy.sampleReads(reads, budget: 10_000)

        XCTAssertEqual(first.map(\.id), second.map(\.id), "sampling must be stable across redraws")
        XCTAssertEqual(first.count, 10_000)
        // A uniform stride over 100k picks every 10th read.
        XCTAssertEqual(first[0].name, reads[0].name)
        XCTAssertEqual(first[1].name, reads[10].name)
        XCTAssertEqual(first[9_999].name, reads[99_990].name)
    }

    func testBannerStatesSampledCountsAndProtectsDepthReading() {
        let state = ReadBudgetState(
            displayedReads: 50_000, totalReads: 600_000, isEstimated: false, loadedAll: false
        )
        let message = try? XCTUnwrap(state.bannerMessage)
        let banner = message ?? ""
        XCTAssertTrue(banner.contains("50,000"))
        XCTAssertTrue(banner.contains("600,000"))
        XCTAssertTrue(
            banner.contains("depth, coverage and consensus use all reads"),
            "a sampled pileup must say the coverage curve under it is still complete"
        )
        XCTAssertFalse(banner.contains("~"), "an exact count must not be labelled as an estimate")
    }

    func testEstimatedTotalIsLabelledAsAnEstimate() {
        let state = ReadBudgetState(
            displayedReads: 50_000, totalReads: 480_000, isEstimated: true, loadedAll: false
        )
        XCTAssertTrue(state.bannerMessage?.contains("~480,000") == true)
    }

    func testDepthDerivedEstimateUsesMeanDepthOverReadLength() {
        // 600,000x mean depth across 100 bp with 150 bp reads -> 400,000 reads.
        XCTAssertEqual(
            ReadBudgetState.estimateReadCount(meanDepth: 600_000, windowSpan: 100, meanReadLength: 150),
            400_000
        )
        XCTAssertNil(ReadBudgetState.estimateReadCount(meanDepth: 0, windowSpan: 100, meanReadLength: 150))
        XCTAssertNil(ReadBudgetState.estimateReadCount(meanDepth: 10, windowSpan: 0, meanReadLength: 150))
    }

    func testFetchLimitAsksForOneMoreThanTheBudgetToDetectOverflow() {
        XCTAssertEqual(ReadViewportPolicy.fetchLimit(forBudget: 50_000), 50_001)
        XCTAssertEqual(ReadViewportPolicy.fetchLimit(forBudget: Int.max), Int.max)
    }

    func testBudgetOverflowWithoutAnyCountIsReportedAsAnEstimate() {
        // The fetch was capped at budget + 1, so the true total is unknown; the
        // banner must not present the cap as if it were the real count.
        let reads = makeExtremeDepthPile(count: 50_001)
        let result = SequenceViewerView.applyReadBudget(
            reads: reads, budget: 50_000, exactTotal: nil, estimatedTotal: nil, loadedAll: false
        )
        XCTAssertEqual(result.reads.count, 50_000)
        XCTAssertTrue(result.state.isEstimated)
    }

    // MARK: - View-level budget wiring

    func testViewHoldsOnlyTheBudgetedReadsAndSetsBannerState() {
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 600))
        let reads = makeExtremeDepthPile(count: 600_000)
        let budgeted = SequenceViewerView.applyReadBudget(
            reads: reads,
            budget: ReadViewportPolicy.defaultVisibleReadBudget,
            exactTotal: 600_000,
            estimatedTotal: nil,
            loadedAll: false
        )

        let region = GenomicRegion(chromosome: "chr1", start: 100, end: 220)
        let token = view.testBeginReadFetch(bundleURL: nil, trackID: "t", region: region)
        XCTAssertTrue(view.testCommitReadFetch(token, reads: budgeted.reads, region: region))
        view.setReadBudgetState(budgeted.state)

        XCTAssertEqual(view.testCachedAlignedReads.count, ReadViewportPolicy.defaultVisibleReadBudget)
        XCTAssertTrue(view.readBudgetState.isSampled)
        XCTAssertEqual(view.readBudgetState.totalReads, 600_000)
    }

    func testDepthQueryIsUnaffectedByTheReadBudget() {
        // Depth comes from a separate whole-BAM query and must keep every read.
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 600))
        let region = GenomicRegion(chromosome: "chr1", start: 100, end: 220)
        let points = (100..<220).map {
            ReadTrackRenderer.CoveragePoint(position: $0, depth: 600_000)
        }

        let readToken = view.testBeginReadFetch(bundleURL: nil, trackID: "t", region: region)
        _ = view.testCommitReadFetch(readToken, reads: makeExtremeDepthPile(count: 50_000), region: region)
        let depthToken = view.testBeginDepthFetch(bundleURL: nil, trackID: "t", region: region)
        XCTAssertTrue(view.testCommitDepthFetch(depthToken, points: points, region: region))

        XCTAssertEqual(view.testCachedDepthPoints.count, 120)
        XCTAssertEqual(view.testCachedDepthPoints.map(\.depth).max(), 600_000)
    }

    func testLoadAllClickOutsideTheTargetIsIgnored() {
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 600))
        view.setReadBudgetState(
            ReadBudgetState(displayedReads: 50_000, totalReads: 600_000, isEstimated: false, loadedAll: false)
        )
        view.loadAllButtonRect = CGRect(x: 100, y: 100, width: 60, height: 20)

        XCTAssertFalse(view.handleLoadAllClick(at: NSPoint(x: 10, y: 10)))
        XCTAssertFalse(view.loadAllReadsRequested)

        XCTAssertTrue(view.handleLoadAllClick(at: NSPoint(x: 120, y: 110)))
        XCTAssertTrue(view.loadAllReadsRequested)
        XCTAssertEqual(view.effectiveReadBudget, ReadViewportPolicy.loadAllReadCeiling)
    }

    // MARK: - Off-main packing

    func testDrawDoesNotPackAFreshReadSet() {
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 600))
        view.testSetCachedAlignedReads(makeExtremeDepthPile(count: 20_000))
        let before = view.testPackInvocationCount

        // Exercise the real draw path against a fresh read set.
        view.displayIfNeeded()
        view.draw(view.bounds)

        XCTAssertEqual(
            view.testPackInvocationCount, before,
            "draw(_:) must never pack a fresh read set on the main thread"
        )
    }

    func testBackgroundPackInstallsLayoutWithoutBumpingMainThreadPackCounter() {
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 600))
        let reads = makeExtremeDepthPile(count: 500)
        view.testSetCachedAlignedReads(reads)
        let before = view.testPackInvocationCount

        let key = ReadPackCacheKey(
            readGeneration: view.testCachedReadSetGeneration,
            chromosome: "chr1",
            scaleTier: ReadPackCacheKey.quantizeScale(0.1),
            sortMode: "position",
            sortPosition: nil,
            maxRows: nil,
            verticalCompress: true,
            prioritizedRegion: nil,
            filterWindow: nil
        )
        let packed = ReadTrackRenderer.packReads(reads, frame: makeFrame(), maxRows: nil, sortMode: .position)

        XCTAssertTrue(
            view.commitPackedLayout(
                generation: view.packRequestGeneration, key: key,
                packed: packed.packed, overflow: packed.overflow
            )
        )
        XCTAssertEqual(view.testCachedPackedReads.count, packed.packed.count)
        XCTAssertNotNil(view.testCachedPackedReadLayout)
        XCTAssertEqual(view.testPackInvocationCount, before)
    }

    func testStaleBackgroundPackIsRejectedAfterCancellation() {
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 600))
        let reads = makeExtremeDepthPile(count: 300)
        view.testSetCachedAlignedReads(reads)

        let staleGeneration = view.packRequestGeneration
        let key = ReadPackCacheKey(
            readGeneration: view.testCachedReadSetGeneration,
            chromosome: "chr1",
            scaleTier: ReadPackCacheKey.quantizeScale(0.1),
            sortMode: "position",
            sortPosition: nil,
            maxRows: nil,
            verticalCompress: true,
            prioritizedRegion: nil,
            filterWindow: nil
        )
        let packed = ReadTrackRenderer.packReads(reads, frame: makeFrame(), maxRows: nil, sortMode: .position)

        // The user zooms (or hits Escape) while the pack is in flight.
        view.cancelReadLoad()

        XCTAssertFalse(
            view.commitPackedLayout(
                generation: staleGeneration, key: key,
                packed: packed.packed, overflow: packed.overflow
            ),
            "a pack superseded by a newer request must not install its layout"
        )
        XCTAssertTrue(view.testCachedPackedReads.isEmpty)
        XCTAssertNil(view.cachedPackKey)
    }

    func testCancelReadLoadClearsFetchStateAndKeepsDepth() {
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 600))
        let region = GenomicRegion(chromosome: "chr1", start: 100, end: 220)
        let depthToken = view.testBeginDepthFetch(bundleURL: nil, trackID: "t", region: region)
        _ = view.testCommitDepthFetch(
            depthToken,
            points: [ReadTrackRenderer.CoveragePoint(position: 100, depth: 600_000)],
            region: region
        )
        _ = view.testBeginReadFetch(bundleURL: nil, trackID: "t", region: region)
        XCTAssertTrue(view.testIsFetchingReads)

        view.cancelReadLoad()

        XCTAssertFalse(view.testIsFetchingReads)
        XCTAssertNil(view.readLoadPhase)
        XCTAssertEqual(
            view.testCachedDepthPoints.count, 1,
            "cancelling a read load must leave the coverage tier visible"
        )
    }

    func testCancelledFetchResultCannotCommit() {
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 600))
        let region = GenomicRegion(chromosome: "chr1", start: 100, end: 220)
        let token = view.testBeginReadFetch(bundleURL: nil, trackID: "t", region: region)

        view.cancelReadLoad()

        XCTAssertFalse(
            view.testCommitReadFetch(token, reads: makeExtremeDepthPile(count: 10), region: region),
            "a fetch already cancelled must not install its reads"
        )
        XCTAssertTrue(view.testCachedAlignedReads.isEmpty)
    }

    // MARK: - Progress phases

    func testLoadPhaseMessagesDistinguishFetchingFromPacking() {
        XCTAssertEqual(
            ReadLoadPhase.fetching(readsSoFar: 120_000).badgeMessage,
            "Loading mapped reads\u{2026} 120,000"
        )
        XCTAssertEqual(
            ReadLoadPhase.fetching(readsSoFar: nil).badgeMessage,
            "Loading mapped reads\u{2026}"
        )
        XCTAssertEqual(
            ReadLoadPhase.packing(readCount: 50_000).badgeMessage,
            "Packing 50,000 reads\u{2026}"
        )
    }
}
