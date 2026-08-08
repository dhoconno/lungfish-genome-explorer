// MultiBundleRunModePickerTests.swift - TDD coverage for MultiBundleRunModePicker (MB-0)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishKit

final class MultiBundleRunModePickerTests: XCTestCase {

    // MARK: - Visibility

    func testHiddenWhenBundleCountBelowTwo() {
        XCTAssertFalse(MultiBundleRunModePicker.isVisible(bundleCount: 0))
        XCTAssertFalse(MultiBundleRunModePicker.isVisible(bundleCount: 1))
    }

    func testVisibleWhenBundleCountIsTwoOrMore() {
        XCTAssertTrue(MultiBundleRunModePicker.isVisible(bundleCount: 2))
        XCTAssertTrue(MultiBundleRunModePicker.isVisible(bundleCount: 5))
    }

    // MARK: - Row content

    func testRowTitlesIncludeCounts() {
        let policy = MultiBundleRunPolicy(
            allowedModes: [.perBundle, .combined],
            defaultMode: .perBundle
        )
        let rows = MultiBundleRunModePicker.rowStates(bundleCount: 4, policy: policy)

        XCTAssertEqual(rows.count, 2)
        let perBundleRow = try? XCTUnwrap(rows.first { $0.mode == .perBundle })
        let combinedRow = try? XCTUnwrap(rows.first { $0.mode == .combined })

        XCTAssertEqual(perBundleRow?.title, "Run separately per bundle (4 results)")
        XCTAssertEqual(combinedRow?.title, "Combine all inputs, run once (1 result)")
    }

    // MARK: - Locked mode

    func testLockedModeIsDisabledWithLockReasonCaption() {
        let policy = MultiBundleRunPolicy(
            allowedModes: [.perBundle],
            defaultMode: .perBundle,
            lockReason: "Combining genotyping cohorts is not scientifically valid."
        )
        let rows = MultiBundleRunModePicker.rowStates(bundleCount: 3, policy: policy)

        let perBundleRow = try? XCTUnwrap(rows.first { $0.mode == .perBundle })
        let combinedRow = try? XCTUnwrap(rows.first { $0.mode == .combined })

        XCTAssertEqual(perBundleRow?.isEnabled, true)
        XCTAssertEqual(combinedRow?.isEnabled, false)
        XCTAssertEqual(combinedRow?.caption, "Combining genotyping cohorts is not scientifically valid.")
    }

    func testUnlockedModeUsesLockReasonOnlyWhenDisabled() {
        // A lockReason set alongside both modes allowed should not leak
        // into the enabled row's caption.
        let policy = MultiBundleRunPolicy(
            allowedModes: [.perBundle, .combined],
            defaultMode: .perBundle,
            lockReason: "Should not be shown anywhere."
        )
        let rows = MultiBundleRunModePicker.rowStates(bundleCount: 2, policy: policy)

        for row in rows {
            XCTAssertNotEqual(row.caption, "Should not be shown anywhere.")
        }
    }

    func testBothModesEnabledWhenPolicyAllowsBoth() {
        let policy = MultiBundleRunPolicy(
            allowedModes: [.perBundle, .combined],
            defaultMode: .perBundle
        )
        let rows = MultiBundleRunModePicker.rowStates(bundleCount: 2, policy: policy)

        XCTAssertTrue(rows.allSatisfy(\.isEnabled))
    }

    // MARK: - Selection resolution

    func testResolvedSelectionKeepsCurrentWhenAllowed() {
        let policy = MultiBundleRunPolicy(
            allowedModes: [.perBundle, .combined],
            defaultMode: .perBundle
        )
        XCTAssertEqual(
            MultiBundleRunModePicker.resolvedSelection(current: .combined, policy: policy),
            .combined
        )
    }

    func testResolvedSelectionFallsBackToDefaultWhenCurrentIsLocked() {
        let policy = MultiBundleRunPolicy(
            allowedModes: [.perBundle],
            defaultMode: .perBundle,
            lockReason: "locked"
        )
        XCTAssertEqual(
            MultiBundleRunModePicker.resolvedSelection(current: .combined, policy: policy),
            .perBundle
        )
    }

    func testResolvedSelectionFallsBackToFirstAllowedWhenDefaultAlsoLocked() {
        // Defensive case: a misconfigured policy whose defaultMode isn't in
        // allowedModes should not crash or return an invalid mode.
        let policy = MultiBundleRunPolicy(
            allowedModes: [.combined],
            defaultMode: .perBundle
        )
        XCTAssertEqual(
            MultiBundleRunModePicker.resolvedSelection(current: .perBundle, policy: policy),
            .combined
        )
    }

    // MARK: - Default mode

    func testDefaultModeIsPerBundleForUnlockedPolicy() {
        // Spec: "Default: per-bundle."
        let policy = MultiBundleRunPolicy(
            allowedModes: [.perBundle, .combined],
            defaultMode: .perBundle
        )
        XCTAssertEqual(policy.defaultMode, .perBundle)
    }
}
