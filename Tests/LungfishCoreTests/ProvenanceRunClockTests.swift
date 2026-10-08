// ProvenanceRunClockTests.swift - Run times survive wall-clock steps
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
@testable import LungfishCore

final class ProvenanceRunClockTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_791_331_200)

    /// The 2026-10-07 stress run stepped the wall clock back 63 ms in the
    /// middle of a delete, and the run's end came out before its start.
    func testBackwardWallClockStepCannotMoveTheEndBeforeTheStart() {
        let time = SteppedTimeSource(startingAt: start)
        let clock = ProvenanceRunClock(source: time.source)

        time.advance(by: 0.010)
        time.stepWallClock(by: -0.063)

        XCTAssertEqual(clock.startedAt, start)
        XCTAssertEqual(clock.elapsed, 0.010, accuracy: 1e-9)
        XCTAssertEqual(clock.now.timeIntervalSince(start), 0.010, accuracy: 1e-6)
    }

    func testForwardWallClockStepDoesNotLengthenTheRun() {
        let time = SteppedTimeSource(startingAt: start)
        let clock = ProvenanceRunClock(source: time.source)

        time.advance(by: 2)
        time.stepWallClock(by: 3_600)

        XCTAssertEqual(clock.elapsed, 2, accuracy: 1e-9)
        XCTAssertEqual(clock.now.timeIntervalSince(start), 2, accuracy: 1e-6)
    }

    func testStartIsTheWallClockWhenTheRunBegins() {
        let time = SteppedTimeSource(startingAt: start)
        time.advance(by: 5)
        time.stepWallClock(by: -0.063)
        let clock = ProvenanceRunClock(source: time.source)

        XCTAssertEqual(clock.startedAt, start.addingTimeInterval(5 - 0.063))
        XCTAssertEqual(clock.elapsed, 0)
    }

    /// A service that injects its wall clock still measures the run on the
    /// monotonic clock, from the moment the clock starts.
    func testInjectedStartTimeIsKeptAndTheRunIsMeasuredMonotonically() {
        let time = SteppedTimeSource(startingAt: start)
        let injected = Date(timeIntervalSince1970: 1_000)
        let clock = ProvenanceTimeSource.$override.withValue(time.source) {
            ProvenanceRunClock(startedAt: injected)
        }

        time.advance(by: 1.5)
        time.stepWallClock(by: -0.063)

        XCTAssertEqual(clock.startedAt, injected)
        XCTAssertEqual(clock.elapsed, 1.5, accuracy: 1e-9)
        XCTAssertEqual(clock.now, Date(timeIntervalSince1970: 1_001.5))
    }

    /// Requests that carry a clock stay Equatable: a clock equals its copies
    /// and no clock started at another moment.
    func testAClockEqualsItsCopiesAndNotAClockStartedLater() {
        let time = SteppedTimeSource(startingAt: start)
        let clock = ProvenanceRunClock(source: time.source)
        let copy = clock
        time.advance(by: 0.5)
        let later = ProvenanceRunClock(source: time.source)

        XCTAssertEqual(clock, copy)
        XCTAssertNotEqual(clock, later)
    }

    /// The override reaches clocks started after a suspension point in the task.
    func testANewClockReadsTheTaskOverride() async {
        let time = SteppedTimeSource(startingAt: start)
        let startedAt = await time.override {
            await Task.yield()
            return ProvenanceRunClock().startedAt
        }

        XCTAssertEqual(startedAt, start)
        XCTAssertNotEqual(ProvenanceRunClock().startedAt, start)
    }
}
