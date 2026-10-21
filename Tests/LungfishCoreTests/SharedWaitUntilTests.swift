// SharedWaitUntilTests.swift - The shared async wait of LungfishTestSupport returns on time
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishTestSupport
import XCTest

/// Pins `waitUntil` of `XCTestAsyncAssertions.swift`, the wait that the polling
/// tests of the unit tier share.
///
/// Every wait here lasts a fraction of a second. The checks that a wait ended in
/// time count condition calls, and the checks of the deadline compare against the
/// lower bound only, since a loaded Mac can only make a wait longer.
final class SharedWaitUntilTests: XCTestCase {
    private struct ConditionFailure: Error {}

    func testReturnsTrueAsSoonAsTheConditionHolds() async {
        let clock = ContinuousClock()
        let start = clock.now
        var checks = 0
        let held = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(5)) {
            checks += 1
            return checks == 3
        }
        let elapsed = start.duration(to: clock.now)
        XCTAssertTrue(held)
        XCTAssertEqual(checks, 3, "The poll must stop at the first check that holds.")
        XCTAssertLessThan(elapsed, .seconds(30), "A condition that holds must not wait out its budget.")
    }

    func testReturnsFalseAtTheDeadlineWithoutFailingTheTest() async {
        let clock = ContinuousClock()
        let start = clock.now
        var checks = 0
        let held = await waitUntil(timeout: .milliseconds(150), pollInterval: .milliseconds(10)) {
            checks += 1
            return false
        }
        let elapsed = start.duration(to: clock.now)
        XCTAssertFalse(held, "The wait reports a missed deadline as false and leaves the assertion to its caller.")
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(150), "The wait must use its whole budget before it gives up.")
        XCTAssertLessThan(elapsed, .seconds(5), "The wait must end near its deadline and not hang.")
        XCTAssertGreaterThan(checks, 1, "The wait must poll more than once inside its budget.")
    }

    func testChecksTheConditionOnceWhenTheBudgetIsZero() async {
        var checks = 0
        let missed = await waitUntil(timeout: .zero) {
            checks += 1
            return false
        }
        XCTAssertFalse(missed)
        XCTAssertEqual(checks, 1, "A wait with no budget still looks once.")

        let held = await waitUntil(timeout: .zero) { true }
        XCTAssertTrue(held, "A condition that already holds needs no budget.")
    }

    func testRethrowsAnErrorOfTheCondition() async {
        await XCTAssertThrowsErrorAsync(
            try await waitUntil(timeout: .seconds(30)) { throw ConditionFailure() }
        ) { error in
            XCTAssertTrue(error is ConditionFailure, "\(error)")
        }
    }

    // MARK: - Named budgets

    func testTheStandardBudgetIsFiveSecondsAndTheLookupBudgetSixty() {
        XCTAssertEqual(WaitBudget.standard.name, "standard")
        XCTAssertEqual(WaitBudget.standard.duration, .seconds(5))
        XCTAssertEqual(WaitBudget.standard.seconds, 5)
        XCTAssertEqual(WaitBudget.standard.nanoseconds, 5_000_000_000)
        XCTAssertEqual(WaitBudget.lookup.name, "lookup")
        XCTAssertEqual(WaitBudget.lookup.duration, .seconds(60))
        XCTAssertEqual(WaitBudget.lookup.seconds, 60)
        XCTAssertEqual(WaitBudget.lookup.nanoseconds, 60_000_000_000)
    }

    func testANamedRaiseKeepsTheNameAndNeverShortensABudget() {
        let raised = WaitBudget.standard.raised(to: .seconds(20))
        XCTAssertEqual(raised.name, WaitBudget.standard.name)
        XCTAssertEqual(raised.duration, .seconds(20))

        let kept = WaitBudget.lookup.raised(to: .seconds(20))
        XCTAssertEqual(kept, WaitBudget.lookup, "A raise to a shorter duration changes nothing.")
    }

    /// The short budget allows 5 checks at most, since each check is followed by a
    /// sleep of at least 10 ms, so it cannot reach the tenth check on any machine.
    /// The raised budget reaches it with a wide margin.
    func testANamedRaiseLengthensTheDeadline() async {
        let short = WaitBudget(name: "pin-short", duration: .milliseconds(40))
        let raised = short.raised(to: .milliseconds(800))
        XCTAssertEqual(raised.name, short.name)

        var checks = 0
        let missed = await waitUntil(budget: short, pollInterval: .milliseconds(10)) {
            checks += 1
            return checks == 10
        }
        XCTAssertFalse(missed, "The short budget ends before the tenth check.")
        XCTAssertLessThan(checks, 10)

        checks = 0
        let held = await waitUntil(budget: raised, pollInterval: .milliseconds(10)) {
            checks += 1
            return checks == 10
        }
        XCTAssertTrue(held, "The raised budget reaches the tenth check.")
        XCTAssertEqual(checks, 10)
    }
}
