// MainSplitSidebarDropRoutingTests.swift - Tests for sidebar drop notification ownership
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class MainSplitSidebarDropRoutingTests: XCTestCase {

    func testSidebarDropNotificationsAreHandledOnlyByOwningSplitController() {
        let sourceSidebar = SidebarViewController()
        let destinationSidebar = SidebarViewController()

        XCTAssertFalse(
            MainSplitViewController.shouldHandleSidebarFileDropNotification(
                from: destinationSidebar,
                owningSidebar: sourceSidebar,
                owningViewer: nil
            ),
            "A source project window must not process a drop posted by a different sidebar."
        )
        XCTAssertTrue(
            MainSplitViewController.shouldHandleSidebarFileDropNotification(
                from: destinationSidebar,
                owningSidebar: destinationSidebar,
                owningViewer: nil
            ),
            "The destination project window should process drops posted by its own sidebar."
        )
        XCTAssertTrue(
            MainSplitViewController.shouldHandleSidebarFileDropNotification(
                from: nil,
                owningSidebar: sourceSidebar,
                owningViewer: nil
            ),
            "Legacy/global import notifications should continue to route through the existing handler."
        )
    }

    func testImportedCSVAutoDisplayUsesSidebarPreviewPath() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MainSplitImportedCSV-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let csvURL = projectURL.appendingPathComponent("report.csv")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "sample,reads\nDW472,20\n".write(to: csvURL, atomically: true, encoding: .utf8)

        let controller = MainSplitViewController()
        _ = controller.view
        controller.sidebarController.openProject(at: projectURL)

        defer {
            controller.sidebarController.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        controller.testingDisplayImportedProjectFile(csvURL)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(
            controller.sidebarController.selectedFileURL?.standardizedFileURL,
            csvURL.standardizedFileURL
        )
        XCTAssertEqual(
            controller.viewerController.testQuickLookURL?.standardizedFileURL,
            csvURL.standardizedFileURL
        )
        XCTAssertFalse(
            controller.viewerController.testHasQuickLookView,
            "Unit tests should verify routing without instantiating embedded QuickLook views."
        )
    }
}
