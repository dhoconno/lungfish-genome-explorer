// ViewSwitchMatrixTests.swift - Every viewport kind in a real window, and every switch between two kinds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The 3.1 quality net (architecture program, Phase 3 task 3a). One fixture of
// every kind of ViewSwitchKinds is built once under one scratch root. The first
// test selects each kind alone in a fresh window on screen. The second walks
// every ordered pair of two kinds in one window, an Euler circuit of n(n-1)
// switches, and after each switch reads the viewer's installed children, the
// Inspector's blocks, tab and documents, the drawer, the toolbar and the window
// frame. A switch must leave exactly what its target kind shows alone: one
// installed result viewer, only that kind's Inspector blocks and a frame inside
// the screen. A switch that differs today is declared with its lines in
// ViewSwitchDeclaredLeaks, so a changed or fixed leak fails here until the
// table says so.
//
// A switch settles as soon as its reading matches, so an idle machine walks
// the matrix in a few minutes. The old-token refusal of the acceptance row is
// held by ViewportHostTests in Tests/LungfishKitTests.

import AppKit
import XCTest
@testable import LungfishApp
import LungfishTestSupport

@MainActor
final class ViewSwitchMatrixTests: XCTestCase {
    /// How long one switch may take to settle. The NAO-MGS and NVD kinds open
    /// a SQLite database on the main actor, which a loaded unit tier stalls for
    /// tens of seconds (RoutingTableSafetyNetTests.settleCeiling).
    private static let settleBudget = WaitBudget.lookup

    /// What a switch may wait once an earlier switch of the same test ran out
    /// of time. A stall ends for every switch at once, so a later switch either
    /// settles in moments or differs, and a changed leak costs one full budget.
    private static let settleAfterTimeout = WaitBudget(name: "view switch after a timeout", duration: .seconds(10))

    /// The wait between two looks. Each look reads the whole window.
    private static let settlePoll: Duration = .milliseconds(25)

    private var settleBudget = ViewSwitchMatrixTests.settleBudget

    /// The machine's saved MSA pane flag, written closed for each test. A
    /// switch to an alignment must read the pane open whatever a machine holds
    /// (MSAPaneFlagFixture).
    private var paneFlag: MSAPaneFlagFixture?

    override func setUpWithError() throws {
        try super.setUpWithError()
        // The alignments this test displays keep their pane state in a suite the test owns and sweeps.
        isolateAlignmentPaneDefaults()
        paneFlag = MSAPaneFlagFixture(machineFlag: false)
    }

    override func tearDownWithError() throws {
        paneFlag?.restore()
        paneFlag = nil
        try super.tearDownWithError()
    }

    private typealias Fixture = ViewSwitchFixture

    // MARK: - The kind list

    func testEveryKindNamesOneRowOfTheRoutingTable() {
        let kinds = ViewSwitchKinds.all
        XCTAssertGreaterThan(kinds.count, 1)
        for kind in kinds {
            XCTAssertNotNil(ViewSwitchKinds.row(of: kind), "\(kind.name) names no routing row \(kind.row)")
        }
        XCTAssertEqual(Set(kinds.map(\.name)).count, kinds.count, "kind names must be unique")
        XCTAssertEqual(Set(kinds.map(\.outcome)).count, kinds.count, "kind outcomes must be unique")
        XCTAssertEqual(Set(kinds.map(\.folder)).count, kinds.count, "kind folders must be unique")
        XCTAssertFalse(kinds.contains { $0.name == DeclaredViewSwitchLeak.freshWindow })
    }

    func testTheWalkTakesEveryOrderedPairOnce() {
        for count in [2, 3, 7, ViewSwitchKinds.all.count] {
            let walk = ViewSwitchKinds.eulerCircuit(count: count)
            XCTAssertEqual(walk.first, 0)
            XCTAssertEqual(walk.count, count * (count - 1) + 1, "\(count) kinds")
            let pairs = zip(walk, walk.dropFirst()).map { "\($0)>\($1)" }
            XCTAssertEqual(Set(pairs).count, pairs.count, "\(count) kinds: a pair is walked twice")
            XCTAssertFalse(zip(walk, walk.dropFirst()).contains { $0 == $1 }, "\(count) kinds: a kind follows itself")
        }
    }

    /// A new kind appends its pairs, so the declared lines of the walk before it stay on their pairs.
    func testALaterKindLeavesTheWalkBeforeItAlone() {
        let first = ViewSwitchKinds.eulerCircuit(count: 19)
        XCTAssertEqual(Array(ViewSwitchKinds.eulerCircuit(count: 21).prefix(first.count)), first)
    }

    func testDeclaredLeaksNameKindsOfTheMatrixAndEachPairOnce() {
        let names = Set(ViewSwitchKinds.all.map(\.name))
        var pairs = Set<String>()
        for leak in ViewSwitchDeclaredLeaks.all {
            XCTAssertFalse(leak.to.isEmpty, "\(leak.from): a leak names the kinds it is seen on")
            for target in leak.to {
                let pair = "\(leak.from) -> \(target)"
                XCTAssertTrue(names.contains(leak.from) || leak.from == DeclaredViewSwitchLeak.freshWindow, "\(pair): no such kind")
                XCTAssertTrue(names.contains(target), "\(pair): no such kind")
                XCTAssertNotEqual(leak.from, target, "\(pair): a kind is never switched to itself")
                XCTAssertFalse(leak.faults.isEmpty, "\(pair): a leak names what differs")
                XCTAssertFalse(leak.backlog.isEmpty, "\(pair): a leak names its backlog row")
                XCTAssertTrue(pairs.insert(pair).inserted, "\(pair) is declared twice")
            }
        }
        XCTAssertLessThanOrEqual(
            ViewSwitchDeclaredLeaks.all.count, 94,
            "The declared leaks only shrink, and a new kind adds the pairs it brings. Lower this number in the change that fixes a leak."
        )
        XCTAssertLessThanOrEqual(
            ViewSwitchDeclaredLeaks.all.flatMap(\.to).count, 123,
            "The declared leaks only shrink, and a new kind adds the pairs it brings. Lower this number in the change that fixes a leak."
        )
    }

    // MARK: - In a real window

    func testEveryKindSelectedAloneInARealWindow() async throws {
        let root = try TestTempDirectory.make(prefix: "ViewSwitchAlone")
        defer { TestTempDirectory.cleanup(root) }
        // The window harness keeps every table's column layouts in its own suite (QA 6). The restorer puts back any
        // other key a view writes under a kind's folder, when the test ends, after the windows close and before the
        // folder goes.
        let hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
        defer { hostDefaults.restore() }
        let fixtures = try await buildFixtures(in: root)
        var differing: [String] = []
        var written: [String] = []
        let started = ContinuousClock.now
        for fixture in fixtures {
            let harness = try ViewSwitchWindowHarness()
            harness.select(fixture.item)
            let declared = ViewSwitchDeclaredLeaks.faults(from: DeclaredViewSwitchLeak.freshWindow, to: fixture.kind.name)
            let result = await settle(harness, on: fixture, root: root, declared: declared)
            if !result.settled {
                differing.append(Self.literal(from: DeclaredViewSwitchLeak.freshWindow, to: fixture.kind.name, faults: result.faults))
            }
            // Read while the kind shows, not only at the end (QA 6).
            written += MetadataLayoutDefaults.hostKeys(naming: root.lastPathComponent).map { "\(fixture.kind.name): \($0)" }
            harness.close()
        }
        print("ViewSwitchMatrixTests: \(fixtures.count) kinds alone in \(ContinuousClock.now - started)")
        XCTAssertEqual(written, [], "a table wrote its column layout to the runner's defaults while its kind showed")
        XCTAssertTrue(
            differing.isEmpty,
            "A kind selected alone in a fresh window differs from its declared reading. Declare or fix:\n" + differing.joined(separator: "\n")
        )
    }

    func testSwitchMatrixOverEveryOrderedPairInOneWindow() async throws {
        let root = try TestTempDirectory.make(prefix: "ViewSwitchMatrix")
        defer { TestTempDirectory.cleanup(root) }
        // The window harness keeps every table's column layouts in its own suite (QA 6). The restorer, for any other
        // key, is declared before the harness, so its `defer` runs after the harness closes the window.
        let hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
        defer { hostDefaults.restore() }
        let fixtures = try await buildFixtures(in: root)
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }

        let walk = ViewSwitchKinds.eulerCircuit(count: fixtures.count)
        var previous = DeclaredViewSwitchLeak.freshWindow
        var walked = Set<String>()
        var differing: [String] = []
        var slowest = (pair: "none", time: Duration.zero)
        var firstWrite: String?
        let started = ContinuousClock.now
        for index in walk {
            let fixture = fixtures[index]
            let pair = "\(previous) -> \(fixture.kind.name)"
            harness.select(fixture.item)
            let declared = ViewSwitchDeclaredLeaks.faults(from: previous, to: fixture.kind.name)
            let result = await settle(harness, on: fixture, root: root, declared: declared)
            if !result.settled {
                differing.append(Self.literal(from: previous, to: fixture.kind.name, faults: result.faults))
            }
            if result.elapsed > slowest.time { slowest = (pair, result.elapsed) }
            if previous != DeclaredViewSwitchLeak.freshWindow { walked.insert(pair) }
            previous = fixture.kind.name
            // Read after each switch, not only at the end (QA 6). The first switch that finds a key names it.
            let keys = MetadataLayoutDefaults.hostKeys(naming: root.lastPathComponent)
            if firstWrite == nil, !keys.isEmpty { firstWrite = "\(pair): \(keys)" }
        }
        XCTAssertNil(firstWrite, "a table wrote its column layout to the runner's defaults")
        print(
            "ViewSwitchMatrixTests: \(walked.count) switches between \(fixtures.count) kinds in \(ContinuousClock.now - started), "
                + "slowest \(slowest.pair) in \(slowest.time)"
        )
        XCTAssertEqual(walked.count, fixtures.count * (fixtures.count - 1), "the walk missed an ordered pair")
        XCTAssertTrue(
            differing.isEmpty,
            "A switch differs from its target kind alone and from its declared leak. Declare or fix:\n" + differing.joined(separator: "\n")
        )
    }

    // MARK: - Support

    /// Builds the representative row of every kind under its own folder (ViewSwitchFixtures).
    private func buildFixtures(in root: URL) async throws -> [Fixture] {
        try await ViewSwitchFixtures.build(in: root)
    }

    /// Waits until the window reads as `fixture`'s kind alone with the
    /// `declared` faults, and returns the last faults read.
    private func settle(
        _ harness: ViewSwitchWindowHarness,
        on fixture: Fixture,
        root: URL,
        declared: [String]
    ) async -> (settled: Bool, faults: [String], elapsed: Duration) {
        var faults: [String] = []
        let started = ContinuousClock.now
        let settled = await waitUntil(budget: settleBudget, pollInterval: Self.settlePoll) {
            faults = harness.read(kindRoot: fixture.root, matrixRoot: root).faults(against: fixture.alone)
            return faults == declared
        }
        if !settled { settleBudget = Self.settleAfterTimeout }
        return (settled, faults, ContinuousClock.now - started)
    }

    /// A declared-leak entry for the observed faults, ready to paste.
    private static func literal(from: String, to: String, faults: [String]) -> String {
        let lines = faults.map { "            \(String(reflecting: $0))," }.joined(separator: "\n")
        return "        leak(\(String(reflecting: from)), to: [\(String(reflecting: to))], \"BACKLOG\", [\n\(lines)\n        ]),"
    }
}
