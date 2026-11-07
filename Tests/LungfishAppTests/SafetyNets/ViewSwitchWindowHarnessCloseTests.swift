// ViewSwitchWindowHarnessCloseTests.swift - The view-switch window lets go of its split controller as soon as it closes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Each surface route test that closes a `ViewSwitchWindowHarness` window waits up to 60 s for the window's split
// controller to go, then 60 s more for what its viewer kept. A window that animates its close is held by AppKit's close
// animation (`_NSWindowTransformAnimation`, whose `_animatingWindow` holds the window strongly from the animation's own
// thread) for as long as that animation runs. On an idle Mac that is about 0.3 s. With twenty test processes opening
// and closing windows at once, as on the parallel unit tier, the animation can stall for good, and the window, its
// split controller and the viewer's kept list then outlive both waits (CLOSEHOLD: the unit tier on 1c639936d,
// `FASTACollectionSurfaceRouteTests.testClosingTheWindowOverOneSequenceLetsGoOfTheKeptList`, and landing 31,
// `AssemblyResultSurfaceRouteTests.testClosingTheWindowLeavesNoAssemblyBehind`). The harness's window does not animate,
// so a test reads what Lungfish holds after the close and not what AppKit's animation holds.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp

@MainActor
final class ViewSwitchWindowHarnessCloseTests: XCTestCase {
    /// The polls of the release wait a closed window may take. A close with no animation lets go within one turn of the
    /// main run loop, read on the second poll. The close animation held the window for 25 to 35 polls on an idle Mac.
    private let pollsAfterTheClose = 5

    func testTheWindowLetsGoOfItsSplitControllerWithinAFewPollsOfTheClose() async throws {
        weak var weakSplit: MainSplitViewController?
        weak var weakWindow: NSWindow?
        do {
            let harness = try ViewSwitchWindowHarness()
            XCTAssertEqual(
                harness.window.animationBehavior, .none,
                "the harness window animates its close, and AppKit's close animation holds the window while it runs"
            )
            weakSplit = harness.split
            weakWindow = harness.window
            harness.controller.close()
            harness.split.invalidateDisplayRequest()
        }
        var polls = 0
        let gone = await waitUntil(budget: .lookup) {
            polls += 1
            return weakWindow == nil && weakSplit == nil
        }
        XCTAssertTrue(gone, "the closed window or its split controller outlived the wait")
        XCTAssertLessThanOrEqual(
            polls, pollsAfterTheClose,
            "the closed window held its split controller for \(polls) polls, so something went on holding it after the close"
        )
    }
}
