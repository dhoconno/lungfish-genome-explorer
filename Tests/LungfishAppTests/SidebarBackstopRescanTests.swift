// SidebarBackstopRescanTests.swift - NEW-02 activation backstop rescan
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class SidebarBackstopRescanTests: XCTestCase {

    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarBackstop-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("Backstop.lungfish", isDirectory: true)
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        try ">s\nACGT\n".write(
            to: imports.appendingPathComponent("a.fasta"), atomically: true, encoding: .utf8
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return project
    }

    /// A sidebar hosted in a window, with a manual clock for the throttle.
    private func openedSidebar(
        at projectURL: URL,
        clock: ManualClock
    ) -> (SidebarViewController, NSWindow) {
        let sidebar = SidebarViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = sidebar
        sidebar.backstopRescanClock = { clock.now }
        sidebar.openProject(at: projectURL)
        // Simulate FSEvents missing every change (NEW-02).
        sidebar.detachFilesystemWatcherForTesting()
        addTeardownBlock { @MainActor in
            sidebar.closeProject()
            window.contentViewController = nil
        }
        return (sidebar, window)
    }

    private func titles(_ items: [SidebarItem]) -> [String] {
        items.flatMap { [$0.title] + titles($0.children) }
    }

    // MARK: - Throttle

    func testThrottleAllowsOneFirePerIntervalAndNoneWhileInFlight() {
        var throttle = SidebarBackstopRescanThrottle(minimumInterval: .seconds(2))
        let t0 = ContinuousClock.now
        XCTAssertTrue(throttle.shouldFire(at: t0))
        XCTAssertFalse(throttle.shouldFire(at: t0 + .seconds(5)), "in flight")
        throttle.finish()
        XCTAssertFalse(throttle.shouldFire(at: t0 + .seconds(1)), "inside interval")
        XCTAssertTrue(throttle.shouldFire(at: t0 + .seconds(2)))
    }

    // MARK: - Activation

    func testActivationNotificationsTriggerExactlyOneCoalescedRescan() async throws {
        let projectURL = try makeProject()
        let clock = ManualClock()
        let (sidebar, window) = openedSidebar(at: projectURL, clock: clock)

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertEqual(sidebar.backstopRescanStartCount, 1)

        // Another window becoming key must not rescan this sidebar.
        let other = NSWindow(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true
        )
        other.isReleasedWhenClosed = false
        clock.advance(by: .seconds(10))
        await drainBackstop(sidebar)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: other)
        XCTAssertEqual(sidebar.backstopRescanStartCount, 1)

        // After the interval, the next activation rescans again.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertEqual(sidebar.backstopRescanStartCount, 2)
    }

    func testExternalFileAddedWhileInactiveAppearsAfterActivation() async throws {
        let projectURL = try makeProject()
        let clock = ManualClock()
        let (sidebar, _) = openedSidebar(at: projectURL, clock: clock)
        XCTAssertFalse(titles(sidebar.rootItems).contains("b.fasta"))

        try ">t\nGGCC\n".write(
            to: projectURL.appendingPathComponent("Imports/b.fasta"),
            atomically: true,
            encoding: .utf8
        )

        let task = try XCTUnwrap(sidebar.requestBackstopRescan(reason: "test activation"))
        let applied = await task.value
        XCTAssertTrue(applied, "The backstop, not the watcher, must apply the change")
        XCTAssertTrue(
            titles(sidebar.rootItems).contains("b.fasta"),
            "The backstop rescan must surface a file the watcher missed"
        )
    }

    func testUnchangedTreeIsNotReloaded() async throws {
        let projectURL = try makeProject()
        let clock = ManualClock()
        let (sidebar, _) = openedSidebar(at: projectURL, clock: clock)
        let before = sidebar.rootItems
        XCTAssertFalse(before.isEmpty)

        let task = try XCTUnwrap(sidebar.requestBackstopRescan(reason: "test activation"))
        let applied = await task.value

        XCTAssertFalse(applied, "An unchanged project must not be reloaded")
        XCTAssertEqual(sidebar.rootItems.count, before.count)
        for (lhs, rhs) in zip(sidebar.rootItems, before) {
            XCTAssertTrue(lhs === rhs, "Rows must be the same objects when nothing changed")
        }
    }

    func testTreeComparisonDetectsChanges() throws {
        let node = SidebarScanNode(
            title: "Imports", type: .folder, badge: .symbol("folder"),
            url: URL(fileURLWithPath: "/p/Imports"),
            children: [SidebarScanNode(title: "a.fasta", type: .sequence, url: URL(fileURLWithPath: "/p/Imports/a.fasta"))]
        )
        let item = SidebarItem(
            title: "Imports", type: .folder, icon: "folder",
            children: [SidebarItem(title: "a.fasta", type: .sequence, url: URL(fileURLWithPath: "/p/Imports/a.fasta"))],
            url: URL(fileURLWithPath: "/p/Imports")
        )
        XCTAssertTrue(SidebarViewController.sidebarItems([item], match: [node]))

        var renamed = node
        renamed.children[0].title = "b.fasta"
        XCTAssertFalse(SidebarViewController.sidebarItems([item], match: [renamed]))

        var added = node
        added.children.append(SidebarScanNode(title: "c.fasta", type: .sequence))
        XCTAssertFalse(SidebarViewController.sidebarItems([item], match: [added]))
    }

    private func drainBackstop(_ sidebar: SidebarViewController) async {
        for _ in 0..<200 where sidebar.backstopRescanThrottle.isInFlight {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A clock the test advances by hand.
@MainActor
private final class ManualClock {
    private(set) var now = ContinuousClock.now
    func advance(by duration: Duration) { now += duration }
}
