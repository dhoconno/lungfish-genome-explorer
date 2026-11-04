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

/// A real Quick Look view that counts the calls to `close`, so a test can tell that the app closed it. It still draws.
private final class CountingQuickLookView: QLPreviewView {
    var closeCalls = 0

    override func close() {
        closeCalls += 1
        super.close()
    }
}

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

    /// A view that leaves the window must also be closed, since that is what stops a movie or a sound. The views here are
    /// real and draw for real, and only count the calls to `close`. The header says `close` releases the current preview
    /// item, so a view that left holding no item let go of its file. The count shows that the app made the call, because
    /// this Mac's view also lets go of its item when it only leaves the window, so the item alone cannot tell the two
    /// apart. No movie fixture is needed for this, and hearing the sound stop is a walk row.
    func testTheRealQuickLookViewReleasesItsItemWhenItGoes() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        viewer.embeddedFilePreviewRenderer = { viewer, url in
            viewer.renderEmbeddedFilePreview(url: url, makeView: { CountingQuickLookView(frame: $0, style: .normal) })
        }
        let image = try RoutingSafetyNetFixtures.pngImage(named: "coverage.png", in: root)
        let page = root.appendingPathComponent("report.html")
        try "<html><body>report</body></html>\n".write(to: page, atomically: true, encoding: .utf8)
        let table = root.appendingPathComponent("table.csv")
        try "sample,reads\nHG002,1200\n".write(to: table, atomically: true, encoding: .utf8)

        var held: [CountingQuickLookView] = []
        for file in [image, page, table] {
            XCTAssertTrue(viewer.displayQuickLookPreview(url: file), "\(file.lastPathComponent) did not open")
            let view = try XCTUnwrap(
                viewer.quickLookPreviewController?.quickLookView as? CountingQuickLookView,
                "\(file.lastPathComponent) has no Quick Look view"
            )
            XCTAssertNotNil(view.previewItem, "the live view holds no item while it shows")
            XCTAssertTrue(view.shouldCloseWithWindow, "a window close would leave the view open")
            XCTAssertEqual(view.closeCalls, 0, "the view was closed as it opened")
            for gone in held {
                XCTAssertEqual(gone.closeCalls, 1, "the app never closed the view that left the window, after \(file.lastPathComponent)")
                XCTAssertNil(gone.previewItem, "the view left the window but was never closed, after \(file.lastPathComponent)")
            }
            held.append(view)
        }

        viewer.clearViewport()

        XCTAssertEqual(held.count, 3, "the live view was not drawn for every file")
        for gone in held {
            XCTAssertEqual(gone.closeCalls, 1, "the app never closed the view that left the window, after a clear")
            XCTAssertNil(gone.previewItem, "the view left the window but was never closed, after a clear")
        }
    }

    private struct QuickLookViewHandle {
        weak var view: NSView?
    }
}
