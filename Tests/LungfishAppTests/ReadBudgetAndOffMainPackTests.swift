// ReadBudgetAndOffMainPackTests.swift - Displayed-depth cap bookkeeping, banner, and off-main packing
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

    // MARK: - Displayed-depth cap (owner decision D9)
    //
    // The old 50,000-read budget and its stride trim (`applyReadBudget`,
    // `ReadViewportPolicy.sampleReads`) are gone: a uniform count budget
    // hollowed shallow flanks beside a deep amplicon. The provider now caps
    // depth per bin (covered by LungfishIOTests.ReadDepthCapTests), so these
    // tests pin the view-side bookkeeping, banner wording and settings.

    private func outcome(
        reads: Int, total: Int, estimated: Bool, cap: Int?, truncated: Bool = false
    ) -> SequenceViewerView.TrackReadFetchOutcome {
        SequenceViewerView.TrackReadFetchOutcome(
            reads: (0..<reads).map { makeRead(name: "r\($0)", position: 100 + $0 % 100) },
            estimatedTotal: total,
            isEstimated: estimated,
            cappedDepth: cap,
            transportTruncated: truncated
        )
    }

    func testDefaultCapIsFiveHundredAndClampsToRangeAndStep() {
        XCTAssertEqual(ReadViewportPolicy.defaultMaxDisplayedDepth, 500)
        XCTAssertEqual(ReadViewportPolicy.clampMaxDisplayedDepth(500), 500)
        XCTAssertEqual(ReadViewportPolicy.clampMaxDisplayedDepth(0), 50)
        XCTAssertEqual(ReadViewportPolicy.clampMaxDisplayedDepth(-10), 50)
        XCTAssertEqual(ReadViewportPolicy.clampMaxDisplayedDepth(1_000_000), 5_000)
        XCTAssertEqual(ReadViewportPolicy.clampMaxDisplayedDepth(524), 500, "snaps to the 50x step")
        XCTAssertEqual(ReadViewportPolicy.clampMaxDisplayedDepth(525), 550)
        XCTAssertEqual(ReadViewportPolicy.clampMaxDisplayedDepth(4_990), 5_000)
    }

    func testCappedWindowBannerSaysOnlyDeepRegionsAreSampled() {
        let state = SequenceViewerView.readBudgetState(
            outcomes: [outcome(reads: 72_087, total: 2_050_000, estimated: true, cap: 500)],
            loadedAll: false
        )
        XCTAssertTrue(state.isSampled)
        XCTAssertEqual(state.displayedReads, 72_087)
        let banner = try? XCTUnwrap(state.bannerMessage)
        XCTAssertEqual(
            banner,
            "Showing 72,087 of ~2,050,000 reads \u{00B7} regions above 500x are sampled to about 500x, "
                + "all other regions show every read \u{00B7} depth, coverage and consensus use all reads"
        )
    }

    func testWindowUnderTheCapShowsNoBannerAndAnExactCount() {
        let state = SequenceViewerView.readBudgetState(
            outcomes: [outcome(reads: 1_200, total: 1_200, estimated: false, cap: nil)],
            loadedAll: false
        )
        XCTAssertFalse(state.isSampled)
        XCTAssertNil(state.bannerMessage)
        XCTAssertEqual(state.totalReads, 1_200)
        XCTAssertFalse(state.isEstimated)
    }

    func testOutcomesAreNeverTrimmedAgainAfterTheCap() {
        // A second count trim would thin the flanks the cap keeps whole.
        let outcomes = [
            outcome(reads: 60_000, total: 900_000, estimated: true, cap: 500),
            outcome(reads: 40_000, total: 40_000, estimated: false, cap: nil),
        ]
        let state = SequenceViewerView.readBudgetState(outcomes: outcomes, loadedAll: false)
        XCTAssertEqual(state.displayedReads, 100_000)
        XCTAssertEqual(state.totalReads, 940_000)
        XCTAssertTrue(state.isEstimated)
        XCTAssertEqual(state.cappedDepth, 500)
        XCTAssertTrue(state.bannerMessage?.contains("sampled to about 500x per track") == true,
                      "each track is capped on its own, so a merged view must say so")
    }

    func testLowestAppliedCapIsQuotedWhenTracksDiffer() {
        let state = SequenceViewerView.readBudgetState(
            outcomes: [
                outcome(reads: 10, total: 100, estimated: true, cap: 500),
                outcome(reads: 10, total: 100, estimated: true, cap: 350),
            ],
            loadedAll: false
        )
        XCTAssertEqual(state.cappedDepth, 350)
    }

    func testLoadAllClearsTheBanner() {
        let state = SequenceViewerView.readBudgetState(
            outcomes: [outcome(reads: 600, total: 600, estimated: false, cap: nil)],
            loadedAll: true
        )
        XCTAssertTrue(state.loadedAll)
        XCTAssertFalse(state.isSampled, "the banner must disappear once everything is loaded")
        XCTAssertNil(state.bannerMessage)
    }

    func testExactCountIsNotLabelledAsAnEstimate() {
        let state = ReadBudgetState(
            displayedReads: 40_000, totalReads: 600_000, isEstimated: false, loadedAll: false, cappedDepth: 500
        )
        XCTAssertTrue(state.bannerMessage?.contains("of 600,000 reads") == true)
        XCTAssertFalse(state.bannerMessage?.contains("~") == true)
    }

    func testTransportTruncatedBannerFlagsAnIncompleteWindow() {
        let capped = SequenceViewerView.readBudgetState(
            outcomes: [outcome(reads: 250_000, total: 1_200_000, estimated: true, cap: 500, truncated: true)],
            loadedAll: false
        )
        XCTAssertTrue(capped.bannerMessage?.contains("read safety limit reached, window may be incomplete") == true)
        XCTAssertTrue(capped.bannerMessage?.contains("sampled to about 500x") == true)

        // Truncation alone (nothing thinned) still raises the banner.
        let uncapped = SequenceViewerView.readBudgetState(
            outcomes: [outcome(reads: 250_000, total: 250_000, estimated: true, cap: nil, truncated: true)],
            loadedAll: false
        )
        XCTAssertTrue(uncapped.isSampled)
        XCTAssertFalse(uncapped.bannerMessage?.contains("sampled to about") == true)
        XCTAssertTrue(uncapped.bannerMessage?.contains("depth, coverage and consensus use all reads") == true)
    }

    // MARK: - Settings plumbing

    func testInspectorDefaultMatchesPolicyAndPayloadCarriesClampedCap() {
        let inspector = InspectorViewController()
        let model = inspector.viewModel.readStyleSectionViewModel
        XCTAssertEqual(model.maxDisplayedDepth, Double(ReadViewportPolicy.defaultMaxDisplayedDepth))

        model.maxDisplayedDepth = 1_230
        var payload = inspector.makeReadDisplaySettingsPayload(from: model)
        XCTAssertEqual(payload[NotificationUserInfoKey.maxDisplayedDepth] as? Int, 1_250)
        XCTAssertNil(payload["visibleReadBudget"], "the retired read-count budget is no longer sent")

        model.maxDisplayedDepth = 9_999
        payload = inspector.makeReadDisplaySettingsPayload(from: model)
        XCTAssertEqual(payload[NotificationUserInfoKey.maxDisplayedDepth] as? Int, 5_000)
    }

    func testViewerAppliesClampedCapAndRefetches() {
        let viewer = ViewerViewController()
        _ = viewer.view
        XCTAssertEqual(viewer.viewerView.maxDisplayedDepthSetting, ReadViewportPolicy.defaultMaxDisplayedDepth)

        let region = GenomicRegion(chromosome: "chr1", start: 100, end: 220)
        let stale = viewer.viewerView.testBeginReadFetch(bundleURL: nil, trackID: "t", region: region)
        viewer.applyReadDisplaySettings([NotificationUserInfoKey.maxDisplayedDepth: 20])

        XCTAssertEqual(viewer.viewerView.maxDisplayedDepthSetting, 50, "clamped to the range floor")
        XCTAssertEqual(viewer.viewerView.effectiveMaxDisplayedDepth, 50)
        XCTAssertFalse(
            viewer.viewerView.testCommitReadFetch(stale, reads: [makeRead(name: "stale", position: 120)], region: region),
            "changing the cap must supersede an in-flight fetch so the window refetches"
        )

        // A retired key from an older payload is ignored, not misapplied.
        let retired: [AnyHashable: Any] = ["visibleReadBudget": 50_000]
        viewer.applyReadDisplaySettings(retired)
        XCTAssertEqual(viewer.viewerView.maxDisplayedDepthSetting, 50)
    }

    // MARK: - View-level wiring

    func testViewHoldsTheFetchedReadsAndSetsBannerState() {
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 600))
        let fetched = outcome(reads: 44_000, total: 600_000, estimated: true, cap: 500)
        let state = SequenceViewerView.readBudgetState(outcomes: [fetched], loadedAll: false)

        let region = GenomicRegion(chromosome: "chr1", start: 100, end: 220)
        let token = view.testBeginReadFetch(bundleURL: nil, trackID: "t", region: region)
        XCTAssertTrue(view.testCommitReadFetch(token, reads: fetched.reads, region: region))
        view.setReadBudgetState(state)

        XCTAssertEqual(view.testCachedAlignedReads.count, 44_000)
        XCTAssertTrue(view.readBudgetState.isSampled)
        XCTAssertEqual(view.readBudgetState.totalReads, 600_000)
    }

    func testDepthQueryIsUnaffectedByTheDepthCap() {
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
            ReadBudgetState(displayedReads: 50_000, totalReads: 600_000, isEstimated: true, loadedAll: false, cappedDepth: 500)
        )
        view.loadAllButtonRect = CGRect(x: 100, y: 100, width: 60, height: 20)

        XCTAssertFalse(view.handleLoadAllClick(at: NSPoint(x: 10, y: 10)))
        XCTAssertFalse(view.loadAllReadsRequested)

        XCTAssertTrue(view.handleLoadAllClick(at: NSPoint(x: 120, y: 110)))
        XCTAssertTrue(view.loadAllReadsRequested)
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
