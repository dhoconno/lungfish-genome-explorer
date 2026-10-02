// SequenceViewerLoadingAnimationAndPanThrottleTests.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishCore
@testable import LungfishIO

/// Regression tests: the loading-badge spinner must invalidate only the badge rect(s)
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
            "a spinner tick during a fetch must not invalidate the whole view"
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
    //
    // These tests drive `panRedrawClock` with a clock that only the test advances, so the frame
    // interval is measured in fake seconds and no assertion depends on how long the machine takes
    // to run the test body. The trailing redraw is a real `Timer`, but a test body never spins
    // the run loop, so that timer cannot fire while an assertion runs.

    /// One 60 Hz frame, the interval `throttledPanRedraw` coalesces redraws to.
    private let frame: CFTimeInterval = 1.0 / 60.0

    /// A viewer whose pan redraw throttle reads a fake clock that starts at `start`.
    private func makeViewWithManualClock(
        startingAt start: CFTimeInterval = 1_000
    ) -> (view: SequenceViewerView, clock: ManualPanRedrawClock) {
        let view = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let clock = ManualPanRedrawClock(startingAt: start)
        view.panRedrawClock = { clock.now }
        // Invalidate the trailing timer even when an assertion above has failed.
        addTeardownBlock { @MainActor in view.scrollRedrawTimer?.invalidate() }
        return (view, clock)
    }

    func testThrottledPanRedrawFiresImmediatelyWhenFrameIntervalHasElapsed() {
        let (view, clock) = makeViewWithManualClock()
        view.lastPanRedrawTime = 0 // a long time before the fake clock's start

        view.throttledPanRedraw()

        XCTAssertEqual(view.lastPanRedrawTime, clock.now, "an elapsed-frame redraw must fire immediately, not schedule a timer")
        XCTAssertNil(view.scrollRedrawTimer, "an immediate redraw must not leave a pending trailing timer")
    }

    func testThrottledPanRedrawCoalescesBurstIntoOneTrailingRedraw() {
        let (view, clock) = makeViewWithManualClock()

        // First call redraws immediately and stamps lastPanRedrawTime.
        view.throttledPanRedraw()
        let firstRedrawTime = view.lastPanRedrawTime
        XCTAssertEqual(firstRedrawTime, clock.now)
        XCTAssertNil(view.scrollRedrawTimer)

        // A burst of calls arriving well within the same frame must not each reset a fresh
        // timer (the old debounce bug). Exactly one trailing timer should exist afterward.
        clock.advance(by: frame / 10)
        view.throttledPanRedraw()
        let timerAfterFirstBurstEvent = view.scrollRedrawTimer
        XCTAssertNotNil(timerAfterFirstBurstEvent, "a call within the frame budget must schedule exactly one trailing redraw")

        clock.advance(by: frame / 10)
        view.throttledPanRedraw()
        clock.advance(by: frame / 10)
        view.throttledPanRedraw()
        XCTAssertTrue(
            view.scrollRedrawTimer === timerAfterFirstBurstEvent,
            "subsequent calls within the same frame must not cancel and reschedule the trailing timer (that was the debounce-starvation bug)"
        )
        XCTAssertEqual(view.lastPanRedrawTime, firstRedrawTime, "no redraw should have happened yet for the coalesced burst")
    }

    func testThrottledPanRedrawRedrawsImmediatelyWhenBurstRunsPastFrameAndClearsTrailingTimer() throws {
        let (view, clock) = makeViewWithManualClock()

        view.throttledPanRedraw()
        let firstRedrawTime = view.lastPanRedrawTime

        // A second call inside the frame leaves one trailing redraw pending.
        clock.advance(by: frame / 4)
        view.throttledPanRedraw()
        let pendingTimer = try XCTUnwrap(view.scrollRedrawTimer, "a call within the frame budget must schedule a trailing redraw")
        XCTAssertTrue(pendingTimer.isValid, "the trailing redraw stays pending until something supersedes it")
        XCTAssertEqual(view.lastPanRedrawTime, firstRedrawTime, "a call within the frame budget must not redraw yet")

        // The burst runs on past a full frame since the last redraw. That call redraws at once and
        // retires the pending timer, so the same frame is never redrawn a second time.
        clock.advance(by: frame * 2)
        view.throttledPanRedraw()
        XCTAssertEqual(view.lastPanRedrawTime, clock.now, "a call a full frame after the last redraw must redraw immediately")
        XCTAssertNil(view.scrollRedrawTimer, "an immediate redraw must clear the trailing timer reference")
        XCTAssertFalse(pendingTimer.isValid, "an immediate redraw must invalidate the pending trailing timer")

        // With the reference cleared, the next call inside the new frame arms a fresh trailing timer.
        clock.advance(by: frame / 4)
        view.throttledPanRedraw()
        let rearmedTimer = try XCTUnwrap(view.scrollRedrawTimer, "a call within the new frame budget must schedule a trailing redraw again")
        XCTAssertFalse(rearmedTimer === pendingTimer, "the new trailing redraw needs its own timer, not the retired one")
        XCTAssertTrue(rearmedTimer.isValid, "the new trailing redraw must be pending")
    }

    // MARK: - Per-frame maxReadSpan scan

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

/// A clock for `SequenceViewerView.panRedrawClock` that moves only when a test advances it.
@MainActor
private final class ManualPanRedrawClock {
    private(set) var now: CFTimeInterval

    init(startingAt now: CFTimeInterval) {
        self.now = now
    }

    func advance(by seconds: CFTimeInterval) {
        now += seconds
    }
}
