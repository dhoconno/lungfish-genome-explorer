// TwoWindowScopedEventTests.swift - Two project windows and the window-scope rule (R9)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKit

/// Two real project windows side by side. A window event reaches only the
/// window whose scope it carries, an unscoped window event reaches neither,
/// and an application event reaches both.
@MainActor
final class TwoWindowScopedEventTests: XCTestCase {
    private var first: MainWindowController!
    private var second: MainWindowController!

    override func setUp() async throws {
        try await super.setUp()
        first = MainWindowController(projectSession: ProjectSession())
        second = MainWindowController(projectSession: ProjectSession())
        for window in [first, second] {
            _ = window?.mainSplitViewController.viewerController.view
            _ = window?.mainSplitViewController.inspectorController.view
            window?.mainSplitViewController.inspectorController.viewModel.selectedTab = .bundle
        }
    }

    override func tearDown() async throws {
        first.close()
        second.close()
        first = nil
        second = nil
        try await super.tearDown()
    }

    private func inspectorTab(of window: MainWindowController) -> InspectorTab {
        window.mainSplitViewController.inspectorController.viewModel.selectedTab
    }

    func testTheTwoWindowsHaveDifferentScopes() {
        XCTAssertNotEqual(first.windowStateScope, second.windowStateScope)
        XCTAssertEqual(first.mainSplitViewController.windowStateScope, first.windowStateScope)
        XCTAssertEqual(first.mainSplitViewController.inspectorController.windowStateScope, first.windowStateScope)
        XCTAssertEqual(first.mainSplitViewController.viewerController.windowStateScope, first.windowStateScope)
    }

    func testUnscopedWindowEventIsDroppedWhileAnApplicationEventReachesBothWindows() {
        // A window event without a scope switches no window's Inspector tab.
        NotificationCenter.default.post(
            name: .showInspectorRequested,
            object: nil,
            userInfo: [NotificationUserInfoKey.inspectorTab: InspectorTab.provenance.rawValue]
        )

        XCTAssertEqual(inspectorTab(of: first), .bundle)
        XCTAssertEqual(inspectorTab(of: second), .bundle)

        // An application event arrives in both windows. With no bundle shown,
        // each viewer drops its scroll direction override.
        let firstViewer = first.mainSplitViewController.viewerController!
        let secondViewer = second.mainSplitViewController.viewerController!
        firstViewer.viewerView.horizontalScrollDirectionOverride = .natural
        secondViewer.viewerView.horizontalScrollDirectionOverride = .natural

        NotificationCenter.default.post(name: .referenceBundleScrollDirectionChanged, object: nil)

        XCTAssertNil(firstViewer.viewerView.horizontalScrollDirectionOverride)
        XCTAssertNil(secondViewer.viewerView.horizontalScrollDirectionOverride)
    }

    func testAWindowEventReachesOnlyTheWindowWhoseScopeItCarries() {
        NotificationCenter.default.post(
            name: .showInspectorRequested,
            object: nil,
            userInfo: [
                NotificationUserInfoKey.inspectorTab: InspectorTab.provenance.rawValue,
                NotificationUserInfoKey.windowStateScope: first.windowStateScope,
            ]
        )

        XCTAssertEqual(inspectorTab(of: first), .provenance)
        XCTAssertEqual(inspectorTab(of: second), .bundle)
    }

    func testAViewerPostReachesOnlyItsOwnWindowsInspector() {
        let annotation = SequenceAnnotation(type: .gene, name: "env", chromosome: "chr1", start: 10, end: 90)

        first.mainSplitViewController.viewerController.viewerView.postAnnotationSelectedNotification(
            annotation,
            postVariantSelection: false
        )

        XCTAssertEqual(first.mainSplitViewController.inspectorController.viewModel.selectedAnnotation?.name, "env")
        XCTAssertNil(second.mainSplitViewController.inspectorController.viewModel.selectedAnnotation)
    }

    /// A container such as the reference bundle viewport embeds a viewer and
    /// never hands it a scope. The embedded viewer posts and filters with the
    /// scope of the window that shows it.
    private func embedViewer(in window: MainWindowController) -> ViewerViewController {
        let host = window.mainSplitViewController.viewerController!
        let embedded = ViewerViewController()
        embedded.publishesGlobalViewportNotifications = false
        host.addChild(embedded)
        host.view.addSubview(embedded.view)
        XCTAssertNil(embedded.windowStateScope)
        return embedded
    }

    func testAnEmbeddedViewerPostReachesOnlyItsOwnWindowsInspector() {
        let embedded = embedViewer(in: first)
        let annotation = SequenceAnnotation(type: .gene, name: "pol", chromosome: "chr1", start: 10, end: 90)

        embedded.viewerView.postAnnotationSelectedNotification(annotation, postVariantSelection: false)

        XCTAssertEqual(first.mainSplitViewController.inspectorController.viewModel.selectedAnnotation?.name, "pol")
        XCTAssertNil(second.mainSplitViewController.inspectorController.viewModel.selectedAnnotation)
    }

    func testAnEmbeddedViewerTakesOnlyItsOwnWindowsInspectorSettings() {
        let firstEmbedded = embedViewer(in: first)
        let secondEmbedded = embedViewer(in: second)

        NotificationCenter.default.post(
            name: .readDisplaySettingsChanged,
            object: nil,
            userInfo: [
                NotificationUserInfoKey.coverageScaleMode: CoverageScaleMode.log10.rawValue,
                NotificationUserInfoKey.windowStateScope: first.windowStateScope,
            ]
        )

        XCTAssertEqual(firstEmbedded.viewerView.coverageScaleModeSetting, .log10)
        XCTAssertEqual(secondEmbedded.viewerView.coverageScaleModeSetting, .linear)
    }
}
