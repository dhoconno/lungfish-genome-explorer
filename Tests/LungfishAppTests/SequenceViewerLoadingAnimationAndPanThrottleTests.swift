// SequenceViewerLoadingAnimationAndPanThrottleTests.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishCore
@testable import LungfishIO

/// PERF-09 regression tests: the loading-badge spinner must invalidate only the badge rect(s)
/// drawn on the last pass, not the whole view, and horizontal-pan redraws must be throttled
/// (redraw as soon as a frame interval has elapsed) rather than debounced (reset a one-shot
/// timer on every event, which can starve entirely under fast input).
@MainActor
final class SequenceViewerLoadingAnimationAndPanThrottleTests: XCTestCase {

    // MARK: - Loading badge animation

    func testLoadingAnimationTickInvalidatesOnlyLastDrawnBadgeRectsNotWholeView() {
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        // Simulate a completed draw pass that recorded one badge rect (what
        // drawTrackLoadingBadge appends every time it draws).
        let badgeRect = CGRect(x: 8, y: 8, width: 160, height: 18)
        view.lastDrawnLoadingBadgeRects = [badgeRect]
        view.testLoadingAnimationInvalidatedRects = []

        view.advanceLoadingAnimationTick()

        XCTAssertEqual(view.testLoadingAnimationInvalidatedRects.count, 1)
        let invalidated = try! XCTUnwrap(view.testLoadingAnimationInvalidatedRects.first)
        XCTAssertNotEqual(
            invalidated, view.bounds,
            "a spinner tick during a fetch must not invalidate the whole view (PERF-09)"
        )
        // The invalidated rect must fully contain the badge (allowing the documented 2pt outset)
        // and must not be anywhere near the size of the 800x600 view.
        XCTAssertTrue(invalidated.contains(badgeRect.insetBy(dx: 1, dy: 1)))
        XCTAssertLessThan(invalidated.width, 200)
        XCTAssertLessThan(invalidated.height, 40)
    }

    func testLoadingAnimationTickFallsBackToFullInvalidateBeforeFirstDrawPass() {
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.lastDrawnLoadingBadgeRects = []
        view.testLoadingAnimationInvalidatedRects = []

        view.advanceLoadingAnimationTick()

        XCTAssertEqual(view.testLoadingAnimationInvalidatedRects, [view.bounds])
    }

    func testLoadingAnimationTickAdvancesPhaseAndWrapsAtTwoPi() {
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.lastDrawnLoadingBadgeRects = [CGRect(x: 0, y: 0, width: 10, height: 10)]
        view.trackLoadingAnimationPhase = 0

        for _ in 0..<20 {
            view.advanceLoadingAnimationTick()
            XCTAssertLessThan(view.trackLoadingAnimationPhase, .pi * 2)
            XCTAssertGreaterThanOrEqual(view.trackLoadingAnimationPhase, 0)
        }
    }

    // MARK: - Pan redraw throttle

    func testThrottledPanRedrawFiresImmediatelyWhenFrameIntervalHasElapsed() {
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.lastPanRedrawTime = 0 // "long ago" relative to CACurrentMediaTime()

        view.throttledPanRedraw()

        XCTAssertGreaterThan(view.lastPanRedrawTime, 0, "an elapsed-frame redraw must fire immediately, not schedule a timer")
        XCTAssertNil(view.scrollRedrawTimer, "an immediate redraw must not leave a pending trailing timer")
    }

    func testThrottledPanRedrawCoalescesBurstIntoOneTrailingRedraw() {
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        // First call redraws immediately and stamps lastPanRedrawTime.
        view.throttledPanRedraw()
        let firstRedrawTime = view.lastPanRedrawTime
        XCTAssertNil(view.scrollRedrawTimer)

        // A burst of calls arriving well within the same frame must not each reset a fresh
        // timer (the old debounce bug) — exactly one trailing timer should exist afterward.
        view.throttledPanRedraw()
        let timerAfterFirstBurstEvent = view.scrollRedrawTimer
        XCTAssertNotNil(timerAfterFirstBurstEvent, "a call within the frame budget must schedule exactly one trailing redraw")

        view.throttledPanRedraw()
        view.throttledPanRedraw()
        XCTAssertTrue(
            view.scrollRedrawTimer === timerAfterFirstBurstEvent,
            "subsequent calls within the same frame must not cancel and reschedule the trailing timer (that was the debounce-starvation bug)"
        )
        XCTAssertEqual(view.lastPanRedrawTime, firstRedrawTime, "no redraw should have happened yet for the coalesced burst")

        view.scrollRedrawTimer?.invalidate()
    }

    // MARK: - Per-frame maxReadSpan scan (PERF-09)

    func testCachedMaxReadSpanIsRecomputedOnlyWhenReadSetChangesNotPerDraw() {
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertNil(view.cachedMaxReadSpan)

        let reads = [
            makeRead(name: "r1", position: 100, cigar: "150M"),
            makeRead(name: "r2", position: 300, cigar: "20M"),
        ]
        view.testSetCachedAlignedReads(reads)

        XCTAssertEqual(view.cachedMaxReadSpan, 150, "cachedMaxReadSpan must reflect the widest read span in the committed set")

        // Re-fetching an unrelated field must not silently invalidate the cache; only a fresh
        // assignment to cachedAlignedReads (which bumps cachedReadSetGeneration) should.
        let previous = view.cachedMaxReadSpan
        view.readScrollOffset = 42
        XCTAssertEqual(view.cachedMaxReadSpan, previous)

        view.testSetCachedAlignedReads([])
        XCTAssertNil(view.cachedMaxReadSpan, "an empty read set must clear the cached span")
    }

    // MARK: - Helpers

    private func makeRead(name: String, position: Int, cigar: String) -> AlignedRead {
        let ops = CIGAROperation.parse(cigar) ?? []
        let queryLength = ops.reduce(0) { $0 + ($1.consumesQuery ? $1.length : 0) }
        return AlignedRead(
            name: name,
            flag: 0,
            chromosome: "chr1",
            position: position,
            mapq: 60,
            cigar: ops,
            sequence: String(repeating: "A", count: max(1, queryLength)),
            qualities: Array(repeating: 37, count: max(1, queryLength))
        )
    }
}
