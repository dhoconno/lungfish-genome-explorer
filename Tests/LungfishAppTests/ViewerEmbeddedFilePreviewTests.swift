// ViewerEmbeddedFilePreviewTests.swift - The viewer's PDFKit and Quick Look preview route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import CoreGraphics
import XCTest
@testable import LungfishApp
import LungfishTestSupport

@MainActor
final class ViewerEmbeddedFilePreviewTests: XCTestCase {
    private var root: URL!
    private var viewer: ViewerViewController!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = try TestTempDirectory.make(prefix: "ViewerEmbeddedFilePreview")
        viewer = ViewerViewController()
        viewer.loadViewIfNeeded()
        viewer.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    }

    override func tearDownWithError() throws {
        viewer.clearViewport()
        viewer = nil
        TestTempDirectory.cleanup(root)
        try super.tearDownWithError()
    }

    func testFileQuickLookCanPreviewIsHandedToTheRenderer() throws {
        let recorder = RecordingFilePreviewRenderer.install(on: viewer)
        let table = root.appendingPathComponent("read-counts.csv")
        try "sample,reads\nHG002,1200\n".write(to: table, atomically: true, encoding: .utf8)

        viewer.displayQuickLookPreview(url: table)

        XCTAssertEqual(recorder.renderedURLs, [table])
        XCTAssertEqual(viewer.testQuickLookURL, table)
        XCTAssertNil(viewer.testPlainTextPreviewString)
        XCTAssertFalse(viewer.testHasQuickLookView)
    }

    func testWorkflowFileShowsAsTextWithoutReachingTheRenderer() throws {
        let recorder = RecordingFilePreviewRenderer.install(on: viewer)
        let workflow = root.appendingPathComponent("main.nf")
        let body = "process FASTP {\n  script: 'fastp --version'\n}\n"
        try body.write(to: workflow, atomically: true, encoding: .utf8)

        viewer.displayQuickLookPreview(url: workflow)

        XCTAssertEqual(recorder.renderedURLs, [])
        XCTAssertEqual(viewer.testPlainTextPreviewString, body)
        XCTAssertEqual(viewer.testPreviewStatusText, "Previewing: main.nf")
    }

    /// The production renderer draws PDFs with PDFKit, which runs in process,
    /// so a test can drive it with no stand-in.
    func testDefaultRendererShowsAPDFWithPDFKit() throws {
        let figure = root.appendingPathComponent("coverage-figure.pdf")
        try writeOnePagePDF(to: figure)

        viewer.displayQuickLookPreview(url: figure)

        XCTAssertEqual(viewer.testQuickLookURL, figure)
        XCTAssertEqual(viewer.testPreviewStatusText, "coverage-figure.pdf (1 page)")
        XCTAssertFalse(viewer.testHasQuickLookView)
    }

    private func writeOnePagePDF(to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.4, alpha: 1))
        context.fill(CGRect(x: 40, y: 40, width: 120, height: 120))
        context.endPDFPage()
        context.closePDF()
    }
}
