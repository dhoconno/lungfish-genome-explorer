// ViewSwitchViewStateTests.swift - Each kind keeps its view through a switch, a relaunch and a changed bundle (VS Q1)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Each case opens a kind's fixture in a real window, makes a person's change, switches to another kind and back, and
// reads the view's own controls, never the state a capture holds (QA 2). The relaunch case keeps the view, closes the
// window, and opens a new window on a new store over the same folder. The changed-bundle case changes the bundle on disk
// while another kind shows. Every window keeps its views in a store under the test's own folder (QA 6, VS A6).
//
// A family lane adds its drivers file and its row in `ViewStateDrivers.all`, removes its kinds from
// ViewStateDeclaredGaps and lowers the ceiling there in its own commit.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishKit
import LungfishTestSupport

/// What a kind's case needs: a person's change, a reading of the view's controls and a change to the bundle.
@MainActor
protocol ViewStateDriver {
    /// The kind's name in ViewSwitchKinds.
    var kind: String { get }
    /// Whether the window shows this kind's view now.
    func isShown(in harness: ViewSwitchWindowHarness) -> Bool
    /// Makes a person's change in the shown view through its own controls.
    func change(in harness: ViewSwitchWindowHarness) throws
    /// Reads the shown view from its own controls, one line a field.
    func read(in harness: ViewSwitchWindowHarness) throws -> [String]
    /// Changes the bundle of `fixture` on disk so its data key differs.
    func changeBundle(of fixture: ViewSwitchFixture) throws
    /// The reading after a changed bundle, given the reading as the person left it.
    func readingAfterChangedBundle(changed: [String]) -> [String]
    /// The reset line after a changed bundle, nil for none.
    var lineAfterChangedBundle: String? { get }
}

@MainActor
enum ViewStateDrivers {
    /// One driver a kind that keeps its view.
    static let all: [any ViewStateDriver] = [TwelveSViewStateDriver()]
}

extension ViewSwitchWindowHarness {
    /// Has the window keep its views in `store`. Call it before the first select.
    func keepViews(in store: ViewMemoryStore) {
        let viewer: ViewerViewController = split.viewerController
        let old = viewer.surfaceHost
        let host = ViewportHost(
            registry: old.registry, containerView: viewer.view, parentController: viewer, viewMemoryStore: store
        )
        host.activeViewportDidChange = old.activeViewportDidChange
        viewer.surfaceHost = host
    }

    /// The words of the reset line over the installed surface, nil when none shows.
    var resetLineWords: String? { split.viewerController.surfaceHost.resetLine?.words }
}

@MainActor
final class ViewSwitchViewStateTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var storeRoot: URL!

    override func setUp() async throws {
        root = try TestTempDirectory.make(prefix: "ViewSwitchViewState")
        project = try SafetyNetFiles.makeDirectory(root.appendingPathComponent("ViewState.lungfish", isDirectory: true))
        storeRoot = root.appendingPathComponent("view-memory", isDirectory: true)
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Coverage

    func testEveryKindHasADriverOrADeclaredGap() {
        let kinds = Set(ViewSwitchKinds.all.map(\.name))
        let driven = ViewStateDrivers.all.map(\.kind)
        let declared = ViewStateDeclaredGaps.all.map(\.kind)
        XCTAssertEqual(Set(driven).count, driven.count, "a kind has two drivers")
        XCTAssertEqual(Set(declared).count, declared.count, "a kind is declared twice")
        XCTAssertTrue(Set(driven).isDisjoint(with: declared), "a kind with a driver is still declared")
        XCTAssertEqual(Set(driven).union(declared), kinds, "every kind needs a driver or a declared gap")
        for gap in ViewStateDeclaredGaps.all {
            XCTAssertFalse(gap.reason.isEmpty, "\(gap.kind): a gap says why")
            XCTAssertFalse(gap.lane.isEmpty, "\(gap.kind): a gap names its lane")
        }
        XCTAssertLessThanOrEqual(
            ViewStateDeclaredGaps.all.count, ViewStateDeclaredGaps.ceiling,
            "The declared gaps only shrink. Lower the ceiling in the change that adopts a kind."
        )
        XCTAssertEqual(ViewStateDeclaredGaps.ceiling, 23, "the ceiling after VS-CORE, which each family lane lowers")
    }

    // MARK: - 12S

    func testTwelveSKeepsItsViewThroughASwitch() async throws {
        try await assertSwitchAwayAndBack(TwelveSViewStateDriver())
    }

    func testTwelveSKeepsItsViewThroughARelaunch() async throws {
        try await assertRelaunch(TwelveSViewStateDriver())
    }

    func testTwelveSOpensAChangedBundleWithItsFiltersDroppedAndOneLine() async throws {
        try await assertChangedBundle(TwelveSViewStateDriver())
    }

    // MARK: - The three cases

    private func assertSwitchAwayAndBack(_ driver: any ViewStateDriver) async throws {
        let (fixture, other) = try await fixtures(for: driver)
        let store = loadedStore()
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: store)
        try await show(fixture, in: harness, driver: driver)
        let start = try driver.read(in: harness)
        try driver.change(in: harness)
        let changed = try driver.read(in: harness)
        XCTAssertNotEqual(changed, start, "\(driver.kind): the change shows in the view's controls")

        try await leave(for: other, in: harness, driver: driver)
        try await show(fixture, in: harness, driver: driver)
        XCTAssertEqual(try driver.read(in: harness), changed, "\(driver.kind): the view as left")
        XCTAssertNil(harness.resetLineWords, "\(driver.kind): nothing was lost, so no line shows")
    }

    private func assertRelaunch(_ driver: any ViewStateDriver) async throws {
        let (fixture, _) = try await fixtures(for: driver)
        let changed: [String]
        do {
            let store = loadedStore()
            let harness = try ViewSwitchWindowHarness()
            harness.keepViews(in: store)
            try await show(fixture, in: harness, driver: driver)
            try driver.change(in: harness)
            changed = try driver.read(in: harness)
            // The quit keeps the installed view with no switch and writes it (VS S1).
            harness.split.viewerController.surfaceHost.captureActive()
            store.flushSynchronously()
            harness.close()
        }
        let relaunched = loadedStore()
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: relaunched)
        try await show(fixture, in: harness, driver: driver)
        XCTAssertEqual(try driver.read(in: harness), changed, "\(driver.kind): the view as left before the relaunch")
        XCTAssertNil(harness.resetLineWords, "\(driver.kind): nothing was lost, so no line shows")
    }

    private func assertChangedBundle(_ driver: any ViewStateDriver) async throws {
        let (fixture, other) = try await fixtures(for: driver)
        let store = loadedStore()
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        harness.keepViews(in: store)
        try await show(fixture, in: harness, driver: driver)
        try driver.change(in: harness)
        let changed = try driver.read(in: harness)

        try await leave(for: other, in: harness, driver: driver)
        try driver.changeBundle(of: fixture)
        try await show(fixture, in: harness, driver: driver)
        XCTAssertEqual(try driver.read(in: harness), driver.readingAfterChangedBundle(changed: changed), driver.kind)
        XCTAssertEqual(harness.resetLineWords, driver.lineAfterChangedBundle, "\(driver.kind): the one line")
    }

    // MARK: - Support

    /// The driver's kind and a kind to switch to, built in the project.
    private func fixtures(for driver: any ViewStateDriver) async throws -> (ViewSwitchFixture, ViewSwitchFixture) {
        let kind = try ViewSwitchFixtures.kind(named: driver.kind)
        let fixture = try await ViewSwitchFixtures.build(kind, in: project)
        let other = try await ViewSwitchFixtures.build(try ViewSwitchFixtures.kind(named: "Status only"), in: project)
        return (fixture, other)
    }

    /// A store over the test's folder with the project read, as a project open reads it (VS S1).
    private func loadedStore() -> ViewMemoryStore {
        let store = ViewMemoryStore(root: storeRoot)
        store.loadProject(at: project)
        store.loadLoose()
        return store
    }

    private func show(_ fixture: ViewSwitchFixture, in harness: ViewSwitchWindowHarness, driver: any ViewStateDriver) async throws {
        harness.select(fixture.item)
        let shown = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { driver.isShown(in: harness) }
        XCTAssertTrue(shown, "\(driver.kind) did not show")
    }

    private func leave(for other: ViewSwitchFixture, in harness: ViewSwitchWindowHarness, driver: any ViewStateDriver) async throws {
        harness.select(other.item)
        let left = await waitUntil(budget: .lookup, pollInterval: .milliseconds(25)) { !driver.isShown(in: harness) }
        XCTAssertTrue(left, "\(driver.kind) stayed after the switch to \(other.kind.name)")
    }
}
