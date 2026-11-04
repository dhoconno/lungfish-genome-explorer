// QuickLookPreviewViewConformanceTests.swift - The real Quick Look view in a real window (Phase 3.2 lane QL)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The unit tier records what Quick Look would draw, since the view starts a helper outside the test process. This class
// draws the real view, with LUNGFISH_REQUIRE_TOOLS=1, and takes it away the way a person does.

import AppKit
import LungfishTestSupport
import Quartz
import XCTest
@testable import LungfishApp

@MainActor
final class QuickLookPreviewViewConformanceTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LUNGFISH_REQUIRE_TOOLS"] == "1", "needs LUNGFISH_REQUIRE_TOOLS=1")
        root = try TestTempDirectory.make(prefix: "QuickLookConformance")
    }

    override func tearDown() async throws {
        if let root { TestTempDirectory.cleanup(root) }
        try await super.tearDown()
    }

    /// An image, a web page and a table, each in the real view, each gone with the next file and with a clear.
    func testTheRealQuickLookViewDrawsAndGoes() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        viewer.embeddedFilePreviewRenderer = { viewer, url in viewer.renderEmbeddedFilePreview(url: url) }
        let image = try RoutingSafetyNetFixtures.pngImage(named: "coverage.png", in: root)
        let page = root.appendingPathComponent("report.html")
        try "<html><body>report</body></html>\n".write(to: page, atomically: true, encoding: .utf8)
        let table = root.appendingPathComponent("table.csv")
        try "sample,reads\nHG002,1200\n".write(to: table, atomically: true, encoding: .utf8)

        var before: QuickLookViewHandle?
        for file in [image, page, table] {
            XCTAssertTrue(viewer.displayQuickLookPreview(url: file), "\(file.lastPathComponent) did not open")
            XCTAssertTrue(viewer.testHasQuickLookView, "\(file.lastPathComponent) has no Quick Look view")
            XCTAssertEqual(viewer.testPreviewStatusText, "Previewing: \(file.lastPathComponent)")
            if let before {
                let gone = await waitUntil(budget: .lookup) { before.view == nil || before.view?.superview == nil }
                XCTAssertTrue(gone, "the view before \(file.lastPathComponent) stayed in the window")
            }
            before = QuickLookViewHandle(view: viewer.testPreviewContentView)
        }

        viewer.clearViewport()

        XCTAssertFalse(viewer.testHasQuickLookView)
        XCTAssertNil(before?.view?.superview, "a clear left the view in the window")
    }

    /// A view that leaves the window must also be closed, since that is what stops a movie or a sound. The header says
    /// `close` releases the current preview item, so a view that left with no item was closed and a view that still holds
    /// its item was only taken out. The test keeps each view alive to read it. No movie fixture is needed for this, and
    /// hearing the sound stop is a walk row.
    func testTheRealQuickLookViewReleasesItsItemWhenItGoes() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        viewer.embeddedFilePreviewRenderer = { viewer, url in viewer.renderEmbeddedFilePreview(url: url) }
        let image = try RoutingSafetyNetFixtures.pngImage(named: "coverage.png", in: root)
        let page = root.appendingPathComponent("report.html")
        try "<html><body>report</body></html>\n".write(to: page, atomically: true, encoding: .utf8)
        let table = root.appendingPathComponent("table.csv")
        try "sample,reads\nHG002,1200\n".write(to: table, atomically: true, encoding: .utf8)

        var held: [QLPreviewView] = []
        for file in [image, page, table] {
            XCTAssertTrue(viewer.displayQuickLookPreview(url: file), "\(file.lastPathComponent) did not open")
            let view = try XCTUnwrap(viewer.quickLookPreviewController?.quickLookView, "\(file.lastPathComponent) has no Quick Look view")
            XCTAssertNotNil(view.previewItem, "the live view holds no item while it shows")
            XCTAssertTrue(view.shouldCloseWithWindow, "a window close would leave the view open")
            for gone in held {
                XCTAssertNil(gone.previewItem, "the view left the window but was never closed, after \(file.lastPathComponent)")
            }
            held.append(view)
        }

        viewer.clearViewport()

        XCTAssertEqual(held.count, 3, "the live view was not drawn for every file")
        for gone in held {
            XCTAssertNil(gone.previewItem, "the view left the window but was never closed, after a clear")
        }
    }

    private struct QuickLookViewHandle {
        weak var view: NSView?
    }
}
