// MSABottomPaneEmbeddedTabControlTests.swift - Fix lane F6: no nested tab control in the MSA bottom pane
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
import LungfishIO

@MainActor
final class MSABottomPaneEmbeddedTabControlTests: XCTestCase {
    private func embeddedDrawer() async throws -> AnnotationTableDrawerView {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("f6.fa")
        try ">A1\nACGTACGTAC\n>B2\nACGTTCGAAC\n".write(to: source, atomically: true, encoding: .utf8)
        let bundleURL = directory.appendingPathComponent("f6.lungfishmsa")
        _ = try MultipleSequenceAlignmentBundle.importAlignment(from: source, to: bundleURL)
        let controller = MultipleSequenceAlignmentViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 700)
        try await controller.displayBundle(at: bundleURL)
        controller.view.layoutSubtreeIfNeeded()
        return controller.bottomPane.annotationDrawer
    }

    func testEmbeddedDrawerHidesItsInnerTabControl() async throws {
        let drawer = try await embeddedDrawer()
        XCTAssertTrue(drawer.hidesTabControl)
        XCTAssertTrue(drawer.tabControl.isHidden, "the nested Annotations | Variants | Samples control is hidden")
    }

    func testGenomeDrawerKeepsItsTabControl() {
        let drawer = AnnotationTableDrawerView()
        XCTAssertFalse(drawer.hidesTabControl)
        XCTAssertFalse(drawer.tabControl.isHidden)
    }

    func testKeyRouteWalkSkipsTheHiddenControl() async throws {
        let drawer = try await embeddedDrawer()
        let chain = drawer.embeddedKeyViewChain
        XCTAssertFalse(chain.contains { $0 === drawer.tabControl })
        drawer.linkEmbeddedKeyViewChain()
        var walked: [NSView] = [chain[0]]
        while let next = walked.last?.nextKeyView, walked.count <= chain.count { walked.append(next) }
        XCTAssertFalse(walked.contains { $0 === drawer.tabControl }, "Tab never lands on the hidden control")
        XCTAssertTrue(walked.last === drawer.tableView)
    }

    func testRevealingTheControlRestoresItsPlaceOnTheRoute() {
        let drawer = AnnotationTableDrawerView()
        XCTAssertTrue(drawer.embeddedKeyViewChain.contains { $0 === drawer.tabControl })
        drawer.hidesTabControl = true
        XCTAssertFalse(drawer.embeddedKeyViewChain.contains { $0 === drawer.tabControl })
        drawer.hidesTabControl = false
        XCTAssertFalse(drawer.tabControl.isHidden)
    }
}
