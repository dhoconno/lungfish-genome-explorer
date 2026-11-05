// ReferenceBundleSurfaceRouteTests+MenuAndRelease.swift - The View menu's drawer items on the reference route (Phase 3.2 lane REFMAP)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// These tests go through what a person reaches, the window controller's menu actions and validation, since a test that
// calls the viewer's own method passes while the menu item is greyed out.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow

extension ReferenceBundleSurfaceRouteTests {
    func testMakeDrawerTallerIsOfferedOnAReferenceAndAMappingResultOnly() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let reference = try makeReference("Offered")
        let mapping = try makeMapping("A", contig: "chrA", readsOnContig: 9)
        let fastq = try await buildRow(of: "FASTQ", under: root)

        harness.split.displayReferenceBundleViewportFromSidebar(at: reference)
        await assertShowsReference(reference, in: viewer)
        assertResizingIsOffered(true, on: "a reference", in: harness)

        harness.split.displayMappingAnalysisFromSidebar(at: mapping.result)
        try await assertShows(mapping, in: viewer)
        assertResizingIsOffered(true, on: "a mapping result", in: harness)

        harness.select(fastq)
        let left = await waitUntil(budget: .lookup) { viewer.contentMode == .fastq }
        XCTAssertTrue(left, "the FASTQ dashboard never replaced the viewport")
        assertResizingIsOffered(false, on: "a FASTQ dashboard", in: harness)
    }

    private func assertResizingIsOffered(
        _ offered: Bool, on name: String, in harness: ViewSwitchWindowHarness, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(harness.split.viewerController.offersResizableAnnotationDrawer, offered, "the viewer's answer on \(name)", file: file, line: line)
        for action in [#selector(MainWindowController.makeDrawerTaller(_:)), #selector(MainWindowController.makeDrawerShorter(_:))] {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            XCTAssertEqual(harness.controller.validateMenuItem(item), offered, "\(action) on \(name)", file: file, line: line)
        }
    }
}
