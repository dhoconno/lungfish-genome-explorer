// ReferenceBundleReadFilterSameRowTests.swift - A read filter stays when the same reference row is selected again (Phase 3.2 lane REFMAP)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A person's filter lives in the Inspector's read style block, the only production writer of the viewport's filter
// (`MainSplitViewController+ContentDisplay.swift`, the two `applySettings` closures). A second selection of the row pushes
// that block's value again (`InspectorViewController+MetadataImport.swift`, the end of `updateReferenceBundleTrackSections`),
// so this test goes through the block and the sidebar. A value written on the viewport alone does not survive that push, at
// the lane's base as at its head. This file holds no helper of the lane, so the same file reads at both.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow

@MainActor
final class ReferenceBundleReadFilterSameRowTests: XCTestCase {
    private var root: URL!
    private var hostDefaults: HostDefaultsRestorer!

    override func setUpWithError() throws {
        isolateAlignmentPaneDefaults()
    }

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "ReferenceFilterSameRow")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
    }

    override func tearDown() async throws {
        hostDefaults?.restore()
        if let root { TestTempDirectory.cleanup(root) }
        try await super.tearDown()
    }

    /// What a person does: select the row, set the filter in the Inspector, enter focus and select the row again.
    func testAFilterSetInTheInspectorStaysWhenTheSameRowIsSelectedAgain() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let kind = try XCTUnwrap(ViewSwitchKinds.all.first { $0.name == "Reference" })
        let row = try XCTUnwrap(ViewSwitchKinds.row(of: kind))
        let kindRoot = try SafetyNetFiles.makeDirectory(root.appendingPathComponent(kind.folder, isDirectory: true))
        let built = try await row.build(RoutingRowContext(root: kindRoot, paths: SafetyNetPathRenderer(root: kindRoot)))
        let readStyle = harness.split.inspectorController.viewModel.readStyleSectionViewModel

        harness.select(built.item)
        let opened = await waitUntil(budget: .lookup) {
            viewer.referenceBundleViewportController?.testEmbeddedViewerController.currentReferenceBundle != nil
                && readStyle.onSettingsChanged != nil
        }
        XCTAssertTrue(opened, "the reference never opened and wired its read filter")
        let viewport = try XCTUnwrap(viewer.referenceBundleViewportController)

        readStyle.selectedReadGroups = ["S1-rg"]
        readStyle.onSettingsChanged?()
        XCTAssertEqual(viewport.testSelectedReadGroups, ["S1-rg"], "the Inspector's filter never reached the viewport")
        viewport.testEnterFocusedDetailMode()
        XCTAssertEqual(viewport.testSelectedReadGroups, ["S1-rg"], "focus mode took the filter away")

        harness.select(built.item)
        await harness.split.bundleOpenTask?.value

        XCTAssertTrue(viewer.referenceBundleViewportController === viewport, "the same input rebuilt the viewport")
        XCTAssertEqual(viewport.testSelectedReadGroups, ["S1-rg"], "the same row took the filter away")
        XCTAssertEqual(readStyle.selectedReadGroups, ["S1-rg"], "the Inspector no longer shows the filter the reads are under")
    }
}
