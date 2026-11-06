// InspectorClearIdentityTests.swift - A clear keeps the row's identity (Phase 3.2 lane SIDEBAR, INSPECTOR-CLEAR-IDENTITY-UNSET)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `InspectorViewController.clearSelection()` sets the Inspector's content identity to nil. A display route that
// clears the Inspector and leaves it nil lets `shouldAcceptCurrentContentNotification` accept a late notification
// that names only the URL of the dataset just left, so that dataset's block could refill beside the new row.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishIO

@MainActor
final class InspectorClearIdentityTests: XCTestCase {
    private var root: URL!
    private var controller: MainSplitViewController!
    private var window: NSWindow!

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "inspector-clear-identity")
        let split = MainSplitViewController()
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        host.contentViewController = split
        host.layoutIfNeeded()
        controller = split
        window = host
    }

    override func tearDown() async throws {
        window.contentViewController = nil
        window = nil
        controller = nil
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    /// An analysis the app cannot open clears the Inspector, and a late FASTQ notification for the row before is
    /// refused because the Inspector still knows which row it shows.
    func testAnUnsupportedAnalysisRefusesALateNotificationForTheRowBefore() throws {
        let analysis = root.appendingPathComponent("Analyses/pbaa-2026-01-15T20-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)
        try AnalysesFolder.writeAnalysisMetadata(.init(tool: "pbaa", isBatch: false), to: analysis)
        let item = SidebarItem(title: analysis.lastPathComponent, type: .analysisResult, url: analysis)
        item.userInfo["analysisTool"] = "pbaa"

        controller.displayContent(for: item)

        let rowBefore = root.appendingPathComponent("Imports/reads.lungfishfastq", isDirectory: true)
        let late = Notification(name: .init("LateFASTQStatistics"), object: nil, userInfo: ["fastqSourceURL": rowBefore])
        XCTAssertEqual(
            controller.inspectorController.activeContentSelectionIdentity?.standardizedURLPath,
            analysis.standardizedFileURL.path,
            "the clear left the Inspector without the row it shows"
        )
        XCTAssertFalse(controller.inspectorController.shouldAcceptCurrentContentNotification(late))
    }

    /// A row the window no longer holds clears the Inspector and keeps that row's identity too.
    func testARowNoLongerAvailableKeepsItsIdentityThroughTheClear() {
        let item = SidebarItem(title: "Gone", type: .sequence)
        item.userInfo["documentID"] = UUID().uuidString
        controller.displayContent(for: item)
        XCTAssertNotNil(controller.inspectorController.activeContentSelectionIdentity)
        XCTAssertEqual(controller.inspectorController.activeContentSelectionIdentity, controller.activeContentSelectionIdentity)
    }
}
