// LayoutSuiteSeams.swift - Points the keyed tables of a result view at a suite that the test owns
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishEsVirituUI
@testable import LungfishTaxTriageUI
@testable import LungfishNaoMgsUI
@testable import LungfishNvdUI

/// A test that opens a result in one of these views calls `isolateLayouts(_:)` first, so the tables of the view
/// keep their column layouts in a suite that the test removes when it ends and write nothing to
/// `UserDefaults.standard` (Phase 2.13 lane 13.69, review 13.52-SWIFT R1).
extension XCTestCase {
    @nonobjc @MainActor
    func isolateLayouts(_ view: TaxonomyViewController) {
        let suite = makeTestDefaultsSuite(prefix: "TaxonomyLayoutSeam")
        view.testTableView.metadataColumns.userDefaults = suite.defaults
        view.testBatchTableView.metadataColumns.userDefaults = suite.defaults
    }

    @nonobjc @MainActor
    func isolateLayouts(_ view: EsVirituResultViewController) {
        let suite = makeTestDefaultsSuite(prefix: "EsVirituLayoutSeam")
        view.testDetectionTableView.metadataColumns.userDefaults = suite.defaults
        view.testBatchTableView.metadataColumns.userDefaults = suite.defaults
    }

    @nonobjc @MainActor
    func isolateLayouts(_ view: TaxTriageResultViewController) {
        view.layoutDefaults = makeTestDefaultsSuite(prefix: "TaxTriageLayoutSeam").defaults
    }

    @nonobjc @MainActor
    func isolateLayouts(_ view: NaoMgsResultViewController) {
        view.metadataColumnController.userDefaults = makeTestDefaultsSuite(prefix: "NaoMgsLayoutSeam").defaults
    }

    @nonobjc @MainActor
    func isolateLayouts(_ view: NvdResultViewController) {
        view.metadataColumnController.userDefaults = makeTestDefaultsSuite(prefix: "NvdLayoutSeam").defaults
    }
}

/// The first divider of a two-pane result view is placed by a main-queue block that `viewDidLayout` schedules, so
/// after a forced layout one pane still holds the whole extent until that block has run. It ran 17 to 75 ms later
/// in the Phase 2.13 LAYOUT-LIVE probe and 9 s later for the first window of a loaded process, which a fixed 50 ms
/// spin cannot cover (review 13.69 Ruling 6, manager decision MD70).
extension XCTestCase {
    /// Spins the main run loop in 5 ms slices until both panes of `split` are larger than `minimumExtent` along the
    /// divider axis (the width for a vertical divider, the height for a horizontal one), and returns once they still
    /// are 50 ms later, the settle the fixed spin it replaced gave before the read. When `timeout` passes first, or
    /// the panes do not hold, it fails with the extents it observed. The assertions after the call keep their own
    /// thresholds. The 30 s ceiling covers the first window of a loaded process, which placed 9 s late in the probe,
    /// and a layout that is already placed returns after the 50 ms settle.
    @nonobjc @MainActor
    func waitForSplitPlacement(
        _ split: NSSplitView,
        minimumExtent: CGFloat,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        func extents() -> [CGFloat] {
            split.arrangedSubviews.map { split.isVertical ? $0.frame.width : $0.frame.height }
        }
        func placed() -> Bool {
            let sizes = extents()
            return sizes.count == 2 && sizes.allSatisfy { $0 > minimumExtent }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !placed(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        if placed() {
            // The fixed spin this replaced read the panes 50 ms after the layout. Keep that settle, so a pass that undoes the placement still fails.
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if !placed() {
            XCTFail(
                "Split view panes not placed, or not held for 50 ms after placement, within \(timeout) s: extents \(extents()) along the divider axis, each needs more than \(minimumExtent)",
                file: file,
                line: line
            )
        }
    }
}
