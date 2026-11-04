// MultipleSequenceAlignmentSurfaceLoadTests.swift - The alignment's load suspends, so a newer request can overtake it (Phase 3.2 lane MSA)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The alignment viewer's load is the one that suspends. These tests hold the real surface's load at its start with a
// subclass, start something newer, then release it, and read that the later request won: the first viewer installs
// nothing, has no callback to fire, leaves the chrome and the status line alone, and says nothing if it fails.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit

/// The real alignment surface, with its load held until the test releases it.
@MainActor
private final class HeldAlignmentSurface: MultipleSequenceAlignmentSurface {
    private var release: CheckedContinuation<Void, Never>?
    private(set) var isHolding = false
    private(set) var hasEnded = false
    private(set) var heldController: MultipleSequenceAlignmentViewController?
    /// What the load throws once released, in place of the real read.
    var failure: (any Error)?

    override func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        defer { hasEnded = true }
        heldController = (input as? Input)?.controller
        await withCheckedContinuation { continuation in
            release = continuation
            isHolding = true
        }
        if let failure { throw failure }
        try await super.load(input: input, token: token)
    }

    func releaseLoad() {
        isHolding = false
        release?.resume()
        release = nil
    }
}

/// Answers the next show with the held surface and every later one with the real surface.
@MainActor
private final class NextLoadHold {
    var held: HeldAlignmentSurface?

    func makeSurface() -> any ResultViewport {
        defer { held = nil }
        return held ?? MultipleSequenceAlignmentSurface()
    }
}

/// A display guard a test can move, as a newer selection moves the split's display generation.
@MainActor
private final class DisplayGuard {
    var isCurrent = true
}

@MainActor
final class MultipleSequenceAlignmentSurfaceLoadTests: XCTestCase {
    private var root: URL!
    private var hostDefaults: HostDefaultsRestorer!

    private let allShown = AlignmentChrome(ruler: false, viewer: false, header: false, status: false)
    private let allHidden = AlignmentChrome(ruler: true, viewer: true, header: true, status: true)

    override func setUpWithError() throws {
        isolateAlignmentPaneDefaults()
    }

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "MSASurfaceLoad")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
    }

    override func tearDown() async throws {
        hostDefaults.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - In a real window

    /// While the load is held the chrome is hidden and the slot is empty. On release the viewer installs and is wired.
    func testTheChromeHidesBeforeTheLoadAndTheViewerInstallsWhenItEnds() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let held = holdNextLoad(in: viewer)
        defer { held.releaseLoad() }

        harness.select(try await buildAlignmentRow(root))

        let holding = await waitUntil(budget: .lookup) { held.isHolding }
        XCTAssertTrue(holding, "the load never started")
        XCTAssertEqual(AlignmentChrome(viewer), allHidden, "the chrome did not hide before the load")
        XCTAssertNil(viewer.multipleSequenceAlignmentViewController, "the slot answered before the load ended")
        XCTAssertFalse(viewer.isActiveDrawerOpen, "a pane reads open before the viewer is installed")
        XCTAssertNil(documentBlock(harness), "the Inspector describes an alignment that has not opened")

        held.releaseLoad()

        let shown = await waitUntil(budget: .lookup) { alignmentIsShownAndWired(harness) }
        XCTAssertTrue(shown, "the alignment never opened after the release")
        XCTAssertTrue(viewer.multipleSequenceAlignmentViewController === held.heldController)
        XCTAssertEqual(AlignmentChrome(viewer), allHidden, "the chrome came back under the viewer")
        XCTAssertNotNil(viewer.multipleSequenceAlignmentViewController?.onBottomPaneStateChanged, "the display never wired the drawer's sync")
    }

    /// Two alignments opened quickly: the later one wins, whichever load ends first.
    func testTwoAlignmentsOpenedQuicklyTheLaterOneWins() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let first = try await buildAlignmentRow(root)
        let second = try await buildAlignmentRow(root)
        let held = holdNextLoad(in: viewer)
        defer { held.releaseLoad() }
        harness.select(first)
        let holding = await waitUntil(budget: .lookup) { held.isHolding }
        XCTAssertTrue(holding, "the first load never started")

        harness.select(second)

        let won = await waitUntil(budget: .lookup) {
            viewer.multipleSequenceAlignmentViewController?.bundleURL == second.url && alignmentIsShownAndWired(harness)
        }
        XCTAssertTrue(won, "the second alignment never opened")
        let winner = viewer.multipleSequenceAlignmentViewController

        held.releaseLoad()

        await waitUntilTheHeldLoadHasEnded(held)
        XCTAssertTrue(viewer.multipleSequenceAlignmentViewController === winner, "the first load replaced the second alignment")
        XCTAssertEqual(viewer.children.filter { $0 is MultipleSequenceAlignmentViewController }.count, 1)
        XCTAssertEqual(uncutCallbacks(held.heldController), [], "the superseded viewer has callbacks to fire")
        XCTAssertNil(held.heldController?.bundleURL, "the superseded load changed its viewer's state")
        XCTAssertNil(held.controller, "the superseded surface kept a viewer")
        XCTAssertEqual(AlignmentChrome(viewer), allHidden, "the superseded load brought the chrome back over the second alignment")
        XCTAssertEqual(
            harness.split.inspectorController.viewModel.documentSectionViewModel.msaDiscriminatingSites?.bundleURL,
            second.url,
            "the Inspector describes the first alignment"
        )
    }

    /// An alignment then each other kind while the first still loads. Half the kinds release the load at once, while
    /// the newer route may not yet have reached the host, so only `canCommit` stops it. The other half release after
    /// the newer route has moved the host, so the token stops it.
    func testEachOtherKindOpenedWhileAnAlignmentLoadsWins() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let alignment = try await buildAlignmentRow(root)
        let msaKind = SurfaceKind.bundle(.multipleSequenceAlignment)
        for (index, kind) in ViewSwitchKinds.all.filter({ $0.name != "MSA" }).enumerated() {
            let next = try await buildRow(of: kind.name, under: root)
            let held = holdNextLoad(in: viewer)
            defer { held.releaseLoad() }
            harness.select(alignment)
            let holding = await waitUntil(budget: .lookup) { held.isHolding }
            XCTAssertTrue(holding, "the load never started before \(kind.name)")
            let releaseAtOnce = index.isMultiple(of: 2)

            harness.select(next)

            if releaseAtOnce { held.releaseLoad() }
            let moved = await waitUntil(budget: .lookup) { viewer.surfaceHost.requestedKind != msaKind }
            XCTAssertTrue(moved, "\(kind.name) never took the slot from the alignment's load")
            held.releaseLoad()
            await waitUntilTheHeldLoadHasEnded(held)

            XCTAssertNil(viewer.multipleSequenceAlignmentViewController, "the alignment installed over \(kind.name)")
            XCTAssertFalse(viewer.children.contains { $0 is MultipleSequenceAlignmentViewController }, "the alignment is a child under \(kind.name)")
            XCTAssertEqual(uncutCallbacks(held.heldController), [], "the alignment has callbacks to fire on \(kind.name)")
            XCTAssertNil(held.heldController?.bundleURL, "the superseded load changed its viewer's state before \(kind.name)")
            XCTAssertNil(documentBlock(harness), "the Inspector describes the alignment under \(kind.name)")
            XCTAssertFalse(viewer.statusBar.positionLabel.stringValue.contains("alignment"), "the status line speaks of the alignment under \(kind.name)")
            if ["FASTA document", "Status only"].contains(kind.name) {
                let shown = await waitUntil(budget: .lookup) { AlignmentChrome(viewer) == self.allShown }
                XCTAssertTrue(shown, "\(kind.name) needs the chrome, and the alignment's load left it hidden: \(AlignmentChrome(viewer))")
            }
        }
    }

    /// A load that fails after a newer one has started says nothing over it, and brings back no chrome.
    func testALoadThatFailsAfterANewerOneStartedSaysNothingOverIt() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let first = try await buildAlignmentRow(root)
        let second = try await buildAlignmentRow(root)
        let held = holdNextLoad(in: viewer)
        defer { held.releaseLoad() }
        held.failure = DamagedAlignmentFile()
        harness.select(first)
        let holding = await waitUntil(budget: .lookup) { held.isHolding }
        XCTAssertTrue(holding, "the first load never started")
        harness.select(second)
        let won = await waitUntil(budget: .lookup) {
            viewer.multipleSequenceAlignmentViewController?.bundleURL == second.url && alignmentIsShownAndWired(harness)
        }
        XCTAssertTrue(won, "the second alignment never opened")
        let wordsBefore = viewer.statusBar.positionLabel.stringValue

        held.releaseLoad()

        await waitUntilTheHeldLoadHasEnded(held)
        XCTAssertEqual(viewer.statusBar.positionLabel.stringValue, wordsBefore, "the first load's failure wrote over the second alignment")
        XCTAssertEqual(AlignmentChrome(viewer), allHidden, "the first load's failure brought the chrome back over the second alignment")
        XCTAssertNotNil(viewer.multipleSequenceAlignmentViewController, "the first load's failure took the second alignment away")
        XCTAssertNotNil(documentBlock(harness), "the first load's failure cleared the second alignment's Inspector")
    }

    // MARK: - The awaited show, driven directly

    /// A failure with `canCommit` false, while the host still holds the request, returns nil and throws nothing.
    func testAFailureWithTheGuardMovedThrowsNothingAndLeavesTheChrome() async throws {
        let viewer = ViewerViewController()
        viewer.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)
        let held = holdNextLoad(in: viewer)
        defer { held.releaseLoad() }
        held.failure = DamagedAlignmentFile()
        let displayGuard = DisplayGuard()
        let display = Task { @MainActor in
            try await viewer.displayMultipleSequenceAlignmentBundle(at: self.root, canCommit: { displayGuard.isCurrent })
        }
        let holding = await waitUntil(budget: .lookup) { held.isHolding }
        XCTAssertTrue(holding, "the load never started")

        displayGuard.isCurrent = false
        held.releaseLoad()

        let shown = try await display.value
        XCTAssertNil(shown, "a superseded load returned a viewer")
        XCTAssertEqual(AlignmentChrome(viewer), allHidden, "a superseded failure brought the chrome back")
    }

    /// A failure while the request is current throws the file's own error and brings the chrome back.
    func testAFailureWhileCurrentThrowsTheFilesErrorAndRestoresTheChrome() async throws {
        let viewer = ViewerViewController()
        viewer.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)
        let held = holdNextLoad(in: viewer)
        defer { held.releaseLoad() }
        held.failure = DamagedAlignmentFile()
        let display = Task { @MainActor in
            try await viewer.displayMultipleSequenceAlignmentBundle(at: self.root)
        }
        let holding = await waitUntil(budget: .lookup) { held.isHolding }
        XCTAssertTrue(holding, "the load never started")

        held.releaseLoad()

        do {
            _ = try await display.value
            XCTFail("a current failure threw nothing")
        } catch {
            XCTAssertTrue(error is DamagedAlignmentFile, "the show changed the file's error: \(error)")
        }
        XCTAssertEqual(AlignmentChrome(viewer), allShown, "a current failure left chrome hidden")
        XCTAssertNil(viewer.surfaceHost.requestedKind, "a current failure left the request in the host")
    }

    /// Two displays that share one guard, as two calls of one request do. Only the host's token tells them apart.
    func testTwoDisplaysThatShareOneGuardTheLaterOneWins() async throws {
        let viewer = ViewerViewController()
        viewer.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)
        let firstRow = try await buildAlignmentRow(root)
        let secondRow = try await buildAlignmentRow(root)
        let firstURL = try XCTUnwrap(firstRow.url)
        let secondURL = try XCTUnwrap(secondRow.url)
        let held = holdNextLoad(in: viewer)
        defer { held.releaseLoad() }
        let firstDisplay = Task { @MainActor in try await viewer.displayMultipleSequenceAlignmentBundle(at: firstURL) }
        let holding = await waitUntil(budget: .lookup) { held.isHolding }
        XCTAssertTrue(holding, "the first load never started")
        let secondDisplay = Task { @MainActor in try await viewer.displayMultipleSequenceAlignmentBundle(at: secondURL) }
        let installed = await waitUntil(budget: .lookup) { viewer.multipleSequenceAlignmentViewController?.bundleURL == secondURL }
        XCTAssertTrue(installed, "the second alignment never installed")

        held.releaseLoad()

        let first = try await firstDisplay.value
        let second = try await secondDisplay.value
        XCTAssertNil(first, "the first display returned a viewer after the second took the host")
        XCTAssertNotNil(second)
        XCTAssertTrue(second === viewer.multipleSequenceAlignmentViewController, "the second display did not return the installed viewer")
        XCTAssertEqual(uncutCallbacks(held.heldController), [], "the superseded viewer has callbacks to fire")
        XCTAssertNil(held.heldController?.bundleURL, "the superseded load changed its viewer's state")
    }

    // MARK: - The surface alone

    func testALoadOfAnotherInputSaysSo() async {
        let surface = MultipleSequenceAlignmentSurface()
        do {
            try await surface.load(input: "not an alignment", token: token())
            XCTFail("the load accepted another input")
        } catch {
            XCTAssertTrue(error is SurfaceError, "expected a SurfaceError, got \(error)")
        }
        XCTAssertNil(surface.controller)
    }

    func testALoadThatTheGuardStopsChangesNothing() async throws {
        let row = try await buildAlignmentRow(root)
        let surface = MultipleSequenceAlignmentSurface()
        let alignment = makeIsolatedAlignmentController()
        let input = MultipleSequenceAlignmentSurface.Input(controller: alignment, url: try XCTUnwrap(row.url), canCommit: { false })
        do {
            try await surface.load(input: input, token: token())
            XCTFail("the load committed past the guard")
        } catch {
            XCTAssertTrue(error is CancellationError, "expected a cancellation, got \(error)")
        }
        XCTAssertNil(surface.controller, "the surface kept a viewer the guard stopped")
        XCTAssertNil(alignment.bundleURL, "the viewer's state changed past the guard")
    }

    /// The drawer answers through the surface, and each removal, its own kind included, cuts the callbacks and runs the hook.
    func testTheDrawerAnswersAndEveryRemovalCutsTheCallbacksAndRunsTheHook() async throws {
        let row = try await buildAlignmentRow(root)
        let nextKinds: [SurfaceKind?] = [.bundle(.multipleSequenceAlignment), .bundle(.phylogeneticTree), nil]
        for next in nextKinds {
            let surface = MultipleSequenceAlignmentSurface()
            let alignment = makeIsolatedAlignmentController()
            let input = MultipleSequenceAlignmentSurface.Input(controller: alignment, url: try XCTUnwrap(row.url), canCommit: { true })
            try await surface.load(input: input, token: token())
            XCTAssertTrue(surface.viewController === alignment)

            let opened = surface.isDrawerOpen
            XCTAssertEqual(opened, alignment.isBottomPaneOpen)
            surface.toggleDrawer()
            XCTAssertEqual(surface.isDrawerOpen, !opened, "the toggle never reached the pane")

            alignment.onSelectionStateChanged = { _ in }
            alignment.onBottomPaneStateChanged = {}
            alignment.onInferTreeRequested = { _ in }
            let hook = DisplayGuard()
            surface.onWillDeactivate = { hook.isCurrent = false }

            surface.willDeactivate(replacedBy: next)

            XCTAssertEqual(uncutCallbacks(alignment), [], "a removal by \(String(describing: next)) left callbacks")
            XCTAssertFalse(hook.isCurrent, "a removal by \(String(describing: next)) never ran the hook")
        }
    }

    // MARK: - Support

    private func token() -> AsyncRequestToken<SurfaceRequest> {
        var gate = AsyncRequestGate<SurfaceRequest>()
        return gate.begin(identity: SurfaceRequest(kind: .bundle(.multipleSequenceAlignment)))
    }

    private func holdNextLoad(in viewer: ViewerViewController) -> HeldAlignmentSurface {
        let held = HeldAlignmentSurface()
        let hold = NextLoadHold()
        hold.held = held
        viewer.surfaceHost.registry.register(.bundle(.multipleSequenceAlignment)) { hold.makeSurface() }
        return held
    }

    /// Waits for the load to end, then gives the show awaiting it and the route behind that their turns on the main
    /// actor, which the load's end has already queued.
    private func waitUntilTheHeldLoadHasEnded(
        _ held: HeldAlignmentSurface,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let ended = await waitUntil(budget: .lookup) { held.hasEnded }
        XCTAssertTrue(ended, "the held load never ended", file: file, line: line)
        await Task.yield()
        await Task.yield()
    }
}
