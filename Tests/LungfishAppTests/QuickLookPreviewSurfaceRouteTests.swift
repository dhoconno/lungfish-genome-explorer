// QuickLookPreviewSurfaceRouteTests.swift - Previews on the surface host, their words and what they leave (Phase 3.2 lane QL)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A file the viewer has no result for is previewed in one of three ways: as text, with PDFKit, or with Quick Look. Text
// and PDF are drawn for real here. A Quick Look view starts a helper outside the test process, so the recorder stands
// in for it and QuickLookPreviewViewConformanceTests draws the real one. A preview reads the person's file, so a refusal
// here is the file's own, and every test reads what a person reads: the status bar under the preview.

import AppKit
import CoreGraphics
import LungfishTestSupport
import PDFKit
import Quartz
import XCTest
@testable import LungfishApp
@testable import LungfishKit

/// What a file that does not read says. A real load throws this kind of error, not a `SurfaceError`.
private struct UnreadablePreviewFile: LocalizedError {
    var errorDescription: String? { "notes.md could not be read" }
}

/// A surface whose load fails on the file, so the preview's show never installs.
@MainActor
private final class RefusingPreviewSurface: ResultViewport {
    let controller = NSViewController()
    var viewController: NSViewController { controller }
    var surfaceKind: SurfaceKind { .view(.quickLook) }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        throw UnreadablePreviewFile()
    }
}

/// A Quick Look view that starts no helper and says when it is closed, which is what stops a movie or a sound.
private final class ClosingQuickLookView: QLPreviewView {
    var onClose: (() -> Void)?

    override var previewItem: (any QLPreviewItem)! {
        get { nil }
        set {}
    }

    override func refreshPreviewItem() {}

    override func close() {
        onClose?()
    }
}

/// A genotype result that does not open, so its route falls back to the workbook.
@MainActor
private final class RefusingGenotypeSurface: ResultViewport {
    let controller = NSViewController()
    var viewController: NSViewController { controller }
    var surfaceKind: SurfaceKind { .bundle(.genotypeResult) }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        throw UnreadablePreviewFile()
    }
}

@MainActor
final class QuickLookPreviewSurfaceRouteTests: XCTestCase {
    private var root: URL!
    private var hostDefaults: HostDefaultsRestorer!

    override func setUpWithError() throws {
        isolateAlignmentPaneDefaults()
    }

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "QuickLookSurfaceRoute")
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
    }

    override func tearDown() async throws {
        hostDefaults.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - Each preview shows its file

    /// PDF, text, image, Markdown, a table and a file of unknown type, in a fresh window. The image, the Markdown, the
    /// table and the unknown file are recorded, since Quick Look draws them.
    func testEachPreviewKindOpensThroughTheSurfaceHostInAFreshWindow() async throws {
        let files = try makePreviewFiles()
        for file in files {
            let harness = try ViewSwitchWindowHarness()
            defer { harness.close() }
            let viewer = harness.split.viewerController!

            viewer.displayQuickLookPreview(url: file.url)

            assertShows(file, in: viewer)
            XCTAssertEqual(viewer.installedSurface?.surfaceKind, .view(.quickLook), "\(file.url.lastPathComponent) is not on the surface host")
        }
    }

    /// The same files after a result and after a document, in one window.
    func testEachPreviewKindOpensAfterAnotherKind() async throws {
        let files = try makePreviewFiles()
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let assembly = try await buildRow(of: "Assembly")
        let document = try await buildRow(of: "FASTA document")

        for before in [(assembly, "Assembly"), (document, "FASTA document")] {
            for file in files {
                harness.select(before.0)
                let opened = await settle(harness, on: before.1)
                XCTAssertTrue(opened, "\(before.1) never opened before \(file.url.lastPathComponent)")

                viewer.displayQuickLookPreview(url: file.url)

                assertShows(file, in: viewer, "after \(before.1)")
                XCTAssertEqual(viewer.installedSurface?.surfaceKind, .view(.quickLook), "\(file.url.lastPathComponent) after \(before.1) is not on the surface host")
            }
        }
    }

    func testALargeTextFileShowsItsStartAndSaysItIsCut() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let large = root.appendingPathComponent("large.nf")
        let line = "// a line of a long workflow\n"
        let body = String(repeating: line, count: (3 * 1024 * 1024) / line.utf8.count)
        try body.write(to: large, atomically: true, encoding: .utf8)

        viewer.displayQuickLookPreview(url: large)

        XCTAssertEqual(viewer.testPreviewStatusText, "Previewing: large.nf")
        XCTAssertTrue(viewer.testPreviewSelectionText.hasPrefix("Truncated: showing the first "), viewer.testPreviewSelectionText)
        let shown = try XCTUnwrap(viewer.testPlainTextPreviewString)
        XCTAssertLessThanOrEqual(shown.utf8.count, PlainTextPreview.maxPreviewBytes)
        XCTAssertTrue(shown.hasPrefix(line))
    }

    func testAManyPagePDFShowsItsPageCount() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let report = root.appendingPathComponent("report.pdf")
        try writePDF(to: report, pages: 40)

        viewer.displayQuickLookPreview(url: report)

        XCTAssertEqual(viewer.testPreviewStatusText, "report.pdf (40 pages)")
        XCTAssertTrue(viewer.testHasPDFPreview)
    }

    /// Step 8 of the recipe and decision 2 of the lane. The preview starts below the toolbar and ends at the status bar,
    /// which stays on screen with the words.
    func testQuickLookContentStartsBelowTheToolbar() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let figure = root.appendingPathComponent("figure.pdf")
        try writePDF(to: figure, pages: 1)

        viewer.displayQuickLookPreview(url: figure)
        harness.window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(viewer.view.safeAreaInsets.top, 0, "the window has no toolbar inset, so this test cannot tell the two pins apart")
        let content = try XCTUnwrap(viewer.testPreviewContentView, "nothing draws the file")
        let frame = content.convert(content.bounds, to: nil)
        let safeTop = viewer.view.convert(viewer.view.safeAreaRect, to: nil).maxY
        XCTAssertLessThanOrEqual(frame.maxY, safeTop + 0.5, "the preview starts \(frame.maxY - safeTop) points above the safe area")
        XCTAssertFalse(viewer.statusBar.isHidden, "the preview hid the status bar with its words")
        let barTop = viewer.statusBar.convert(viewer.statusBar.bounds, to: nil).maxY
        XCTAssertEqual(frame.minY, barTop, accuracy: 0.5, "the preview does not end at the status bar")
        XCTAssertFalse(viewer.isViewerAreaShowingChrome, "the genomics viewer shows under the preview")
    }

    // MARK: - A file that does not read

    func testAFileThatIsGoneSaysWhatHappenedAndWhatToTry() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let gone = root.appendingPathComponent("gone.csv")

        viewer.displayQuickLookPreview(url: gone)

        try assertRefusal(in: viewer, naming: "gone.csv")
    }

    func testAFileThatCannotBeReadSaysWhatHappenedAndWhatToTry() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let locked = root.appendingPathComponent("locked.csv")
        try "sample,reads\n".write(to: locked, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path) }

        viewer.displayQuickLookPreview(url: locked)

        try assertRefusal(in: viewer, naming: "locked.csv")
    }

    func testADamagedPDFSaysWhatHappenedAndWhatToTry() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let damaged = root.appendingPathComponent("damaged.pdf")
        try "this is not a PDF\n".write(to: damaged, atomically: true, encoding: .utf8)

        viewer.displayQuickLookPreview(url: damaged)

        try assertRefusal(in: viewer, naming: "damaged.pdf")
        XCTAssertFalse(viewer.testHasPDFPreview, "a damaged PDF left a view")
    }

    /// The host cannot open the preview. The test's surface throws what a file that does not read throws.
    func testAQuickLookPreviewThatDoesNotOpenSaysWhatToTry() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        viewer.surfaceHost.registry.register(.view(.quickLook)) { RefusingPreviewSurface() }
        let notes = root.appendingPathComponent("notes.md")
        try "# Notes\n".write(to: notes, atomically: true, encoding: .utf8)

        viewer.displayQuickLookPreview(url: notes)

        try assertRefusal(in: viewer, naming: "notes.md")
    }

    /// A refused preview takes the kind before it away and shows no words of that kind.
    func testARefusedPreviewLeavesNoPreviewOfTheFileBefore() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let first = root.appendingPathComponent("main.nf")
        try "workflow { }\n".write(to: first, atomically: true, encoding: .utf8)
        viewer.displayQuickLookPreview(url: first)
        XCTAssertEqual(viewer.testPreviewStatusText, "Previewing: main.nf")

        viewer.displayQuickLookPreview(url: root.appendingPathComponent("gone.csv"))

        try assertRefusal(in: viewer, naming: "gone.csv")
        XCTAssertNil(viewer.testPlainTextPreviewString, "the file before stayed on screen")
    }

    /// A workbook that does not read must not leave the words "Showing its workbook instead" over nothing.
    func testAWorkbookThatDoesNotReadDoesNotClaimToShowIt() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let row = try await buildRow(of: "Genotype")
        let bundle = try XCTUnwrap(row.url)
        let workbook = try XCTUnwrap(MainSplitViewController.genotypeResultWorkbookURL(forBundle: bundle))
        // The native result does not open, so the route falls back to its workbook, which does not read either.
        viewer.surfaceHost.registry.register(.bundle(.genotypeResult)) { RefusingGenotypeSurface() }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: workbook.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: workbook.path) }

        harness.select(row)

        let spoke = await waitUntil(budget: .lookup) { viewer.testPreviewStatusText.hasPrefix("Unable to open") }
        XCTAssertTrue(spoke, "the route never said the workbook did not open: \(viewer.testPreviewStatusText)")
        XCTAssertFalse(viewer.testPreviewStatusText.contains("Showing its workbook instead"), viewer.testPreviewStatusText)
        XCTAssertNil(viewer.testQuickLookURL)
    }

    // MARK: - What a preview leaves

    /// Each kind of the matrix takes a PDF, a text preview and a Quick Look view away, with no view, no child and no
    /// open file left, and closes the Quick Look view, which is what stops a movie or a sound.
    func testEveryKindOfTheMatrixTakesThePreviewAway() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let files = try makePreviewFiles().filter { !$0.recorded || $0.url.pathExtension == "csv" }
        let rest = try await buildRow(of: "Status only")
        var opened = 0
        var closed = 0
        viewer.embeddedFilePreviewRenderer = { viewer, _ in
            try? viewer.quickLookPreviewController?.showQuickLookView { frame in
                opened += 1
                let view = ClosingQuickLookView(frame: frame, style: .normal)
                view?.onClose = { closed += 1 }
                return view
            }
        }

        for kind in ViewSwitchKinds.all where kind.name != "Status only" && !kind.outcome.hasPrefix("Quick Look") && !kind.outcome.hasPrefix("PDF") {
            let row = try await buildRow(of: kind.name)
            for file in files {
                harness.select(rest)
                let rested = await settle(harness, on: "Status only")
                XCTAssertTrue(rested, "the status row never opened before \(kind.name)")
                weak var content: NSView?
                viewer.displayQuickLookPreview(url: file.url)
                content = viewer.testPreviewContentView
                XCTAssertNotNil(content, "\(file.url.lastPathComponent) drew nothing before \(kind.name)")

                harness.select(row)

                let left = await waitUntil(budget: .lookup) { viewer.testQuickLookURL == nil }
                XCTAssertTrue(left, "\(kind.name) left \(file.url.lastPathComponent) on screen")
                let after = await settle(harness, on: kind.name)
                XCTAssertTrue(after, "\(kind.name) never opened after \(file.url.lastPathComponent)")
                let gone = await waitUntil(budget: .lookup) { content == nil }
                XCTAssertTrue(gone, "\(kind.name) left the view of \(file.url.lastPathComponent) alive")
                XCTAssertNil(viewer.testPreviewContentView, "\(kind.name) left a preview view")
                XCTAssertEqual(closed, opened, "\(kind.name) left a Quick Look view open, so a movie would keep playing")
                XCTAssertEqual(openDescriptors(of: file.url), 0, "\(kind.name) left \(file.url.lastPathComponent) open")
            }
        }
    }

    /// A recorded preview draws no view, and the next kind takes it away all the same.
    func testARecordedPreviewGoesWithTheNextKind() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let table = root.appendingPathComponent("table.csv")
        try "sample,reads\n".write(to: table, atomically: true, encoding: .utf8)
        viewer.displayQuickLookPreview(url: table)
        XCTAssertEqual(viewer.testQuickLookURL, table)

        let document = try await buildRow(of: "FASTA document")
        harness.select(document)

        let left = await waitUntil(budget: .lookup) { viewer.testQuickLookURL == nil }
        XCTAssertTrue(left, "the next kind left the recorded preview's file behind")
    }

    /// One preview replaces another, and a word of the first does not stay.
    func testASecondPreviewReplacesTheFirstAndItsWords() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let large = root.appendingPathComponent("large.nf")
        try String(repeating: "// line\n", count: 400_000).write(to: large, atomically: true, encoding: .utf8)
        let figure = root.appendingPathComponent("figure.pdf")
        try writePDF(to: figure, pages: 2)

        viewer.displayQuickLookPreview(url: large)
        XCTAssertTrue(viewer.testPreviewSelectionText.hasPrefix("Truncated:"), viewer.testPreviewSelectionText)
        weak var first = viewer.testPreviewContentView

        viewer.displayQuickLookPreview(url: figure)

        let gone = await waitUntil(budget: .lookup) { first == nil }
        XCTAssertTrue(gone, "the first preview's view stayed alive")
        XCTAssertNil(viewer.testPlainTextPreviewString, "the first preview's text stayed")
        XCTAssertEqual(viewer.testPreviewStatusText, "figure.pdf (2 pages)")
        XCTAssertEqual(viewer.testPreviewSelectionText, "", "the first preview's words stayed")
        XCTAssertEqual(viewer.testQuickLookURL, figure)
    }

    /// A second Quick Look view closes the first, and a clear closes the second.
    func testAQuickLookViewIsClosedOnEveryRemoval() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        var closed = 0
        viewer.embeddedFilePreviewRenderer = { viewer, _ in
            try? viewer.quickLookPreviewController?.showQuickLookView { frame in
                let view = ClosingQuickLookView(frame: frame, style: .normal)
                view?.onClose = { closed += 1 }
                return view
            }
        }
        let table = root.appendingPathComponent("table.csv")
        try "sample,reads\n".write(to: table, atomically: true, encoding: .utf8)

        viewer.displayQuickLookPreview(url: table)
        XCTAssertTrue(viewer.testHasQuickLookView)
        XCTAssertEqual(closed, 0, "the view closed as it opened")

        viewer.displayQuickLookPreview(url: table)
        XCTAssertEqual(closed, 1, "a second preview left the first view open")
        XCTAssertTrue(viewer.testHasQuickLookView)

        viewer.clearViewport()
        XCTAssertEqual(closed, 2, "a clear left the view open")
        XCTAssertFalse(viewer.testHasQuickLookView)
    }

    /// Quick Look gives no view, and the person reads that, with no preview left.
    func testAQuickLookViewThatCannotDrawSaysWhatToTry() async throws {
        let viewer = ViewerViewController()
        viewer.loadViewIfNeeded()
        viewer.embeddedFilePreviewRenderer = { viewer, url in viewer.renderEmbeddedFilePreview(url: url, makeView: { _ in nil }) }
        let table = root.appendingPathComponent("table.csv")
        try "sample,reads\n".write(to: table, atomically: true, encoding: .utf8)

        let opened = viewer.displayQuickLookPreview(url: table)

        XCTAssertFalse(opened)
        try assertRefusal(in: viewer, naming: "table.csv")
    }

    func testAProjectSwitchTakesThePreviewAway() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let figure = root.appendingPathComponent("figure.pdf")
        try writePDF(to: figure, pages: 1)
        viewer.displayQuickLookPreview(url: figure)
        XCTAssertNotNil(viewer.testPreviewContentView)

        harness.split.resetWindowForProjectChange()

        XCTAssertNil(viewer.testPreviewContentView, "a project switch left the preview on screen")
        XCTAssertNil(viewer.testQuickLookURL)
        XCTAssertFalse(viewer.statusBar.isHidden, "a project switch hid the status bar")
    }

    func testClosingTheWindowLeavesNoPreviewBehind() async throws {
        let figure = root.appendingPathComponent("figure.pdf")
        try writePDF(to: figure, pages: 1)
        weak var weakSplit: MainSplitViewController?
        weak var weakContent: NSView?
        do {
            let harness = try ViewSwitchWindowHarness()
            harness.split.viewerController.displayQuickLookPreview(url: figure)
            weakSplit = harness.split
            weakContent = harness.split.viewerController.testPreviewContentView
            XCTAssertNotNil(weakContent)
            // Not `harness.close()`: it clears the viewport through the host, which would remove the preview even if
            // the window's own close left it behind.
            harness.controller.close()
            harness.split.invalidateDisplayRequest()
        }
        let gone = await waitUntil(budget: .lookup) { weakSplit == nil }
        XCTAssertTrue(gone, "the window's split controller outlived the close")
        let released = await waitUntil(budget: .lookup) { weakContent == nil }
        XCTAssertTrue(released, "the preview's view outlived the window")
        XCTAssertEqual(openDescriptors(of: figure), 0, "the window's close left the PDF open")
    }

    /// The descriptor check above must be able to see an open file, or the 0 it reads proves nothing.
    func testTheDescriptorCheckSeesAnOpenFile() throws {
        let figure = root.appendingPathComponent("figure.pdf")
        try writePDF(to: figure, pages: 1)
        XCTAssertEqual(openDescriptors(of: figure), 0, "the check reads an open file where nobody has one")

        let handle = try FileHandle(forReadingFrom: figure)
        XCTAssertEqual(openDescriptors(of: figure), 1, "the check cannot see an open file")

        try handle.close()
        XCTAssertEqual(openDescriptors(of: figure), 0, "the check still reads a file that was closed as open")
    }

    /// A replaced PDF preview lets go of its document, whatever PDFKit does with descriptors. This is the check that
    /// the preview does not keep the person's file.
    func testAReplacedPDFPreviewReleasesItsDocument() async throws {
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let viewer = harness.split.viewerController!
        let figure = root.appendingPathComponent("figure.pdf")
        try writePDF(to: figure, pages: 1)

        viewer.displayQuickLookPreview(url: figure)
        weak var document = viewer.quickLookPreviewController?.pdfView?.document
        XCTAssertNotNil(document, "the PDF preview holds no document while it shows")

        viewer.clearViewport()

        let released = await waitUntil(budget: .lookup) { document == nil }
        XCTAssertTrue(released, "the PDFDocument outlived its preview")
    }

    // MARK: - Support

    private struct PreviewFile {
        let url: URL
        let status: String
        let recorded: Bool
    }

    private func makePreviewFiles() throws -> [PreviewFile] {
        let folder = root.appendingPathComponent("files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let figure = folder.appendingPathComponent("figure.pdf")
        try writePDF(to: figure, pages: 1)
        let script = folder.appendingPathComponent("main.nf")
        try "workflow { }\n".write(to: script, atomically: true, encoding: .utf8)
        let image = try RoutingSafetyNetFixtures.pngImage(named: "coverage.png", in: folder)
        let notes = folder.appendingPathComponent("notes.md")
        try "# Notes\n".write(to: notes, atomically: true, encoding: .utf8)
        let table = folder.appendingPathComponent("table.csv")
        try "sample,reads\n".write(to: table, atomically: true, encoding: .utf8)
        let log = folder.appendingPathComponent("spades.log")
        try "spades finished\n".write(to: log, atomically: true, encoding: .utf8)
        return [
            PreviewFile(url: figure, status: "figure.pdf (1 page)", recorded: false),
            PreviewFile(url: script, status: "Previewing: main.nf", recorded: false),
            PreviewFile(url: image, status: "Previewing: coverage.png", recorded: true),
            PreviewFile(url: notes, status: "Previewing: notes.md", recorded: true),
            PreviewFile(url: table, status: "Previewing: table.csv", recorded: true),
            PreviewFile(url: log, status: "Previewing: spades.log", recorded: true),
        ]
    }

    private func assertShows(_ file: PreviewFile, in viewer: ViewerViewController, _ note: String = "in a fresh window", line: UInt = #line) {
        let name = file.url.lastPathComponent
        XCTAssertEqual(viewer.testQuickLookURL, file.url, "\(name) \(note)", line: line)
        XCTAssertEqual(viewer.testPreviewStatusText, file.status, "\(name) \(note)", line: line)
        XCTAssertFalse(viewer.statusBar.isHidden, "\(name) \(note): the words are hidden", line: line)
        if !file.recorded {
            XCTAssertNotNil(viewer.testPreviewContentView, "\(name) \(note): nothing draws the file", line: line)
        }
    }

    private func assertRefusal(in viewer: ViewerViewController, naming name: String, line: UInt = #line) throws {
        let words = viewer.testPreviewStatusText
        XCTAssertTrue(words.hasPrefix("Unable to open the preview."), "the status line never said the preview did not open: \(words)", line: line)
        XCTAssertTrue(words.contains(name), "the status line left out the file: \(words)", line: line)
        XCTAssertTrue(words.hasSuffix("."), "the status line ends with no full stop: \(words)", line: line)
        XCTAssertFalse(words.contains(".."), "the status line has a doubled full stop: \(words)", line: line)
        XCTAssertFalse(words.contains("view:"), "the words name an internal kind id: \(words)", line: line)
        XCTAssertFalse(viewer.statusBar.isHidden, "the words are hidden", line: line)
        XCTAssertNil(viewer.testPreviewContentView, "a preview that did not open drew something", line: line)
        XCTAssertNil(viewer.testQuickLookURL, "a preview that did not open keeps its file", line: line)
    }

    private func writePDF(to url: URL, pages: Int) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.fill(CGRect(x: 40, y: 40, width: 120, height: 120))
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// How many of this process's file descriptors name `url`.
    private func openDescriptors(of url: URL) -> Int {
        let wanted = url.resolvingSymlinksInPath().path
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var count = 0
        for descriptor in 0..<getdtablesize() where fcntl(descriptor, F_GETPATH, &buffer) == 0 {
            let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            if URL(fileURLWithPath: path).resolvingSymlinksInPath().path == wanted { count += 1 }
        }
        return count
    }

    private func buildRow(of name: String) async throws -> SidebarItem {
        let kind = try XCTUnwrap(ViewSwitchKinds.all.first { $0.name == name })
        let row = try XCTUnwrap(ViewSwitchKinds.row(of: kind))
        let folder = root.appendingPathComponent("\(kind.folder)-\(UUID().uuidString)", isDirectory: true)
        let kindRoot = try SafetyNetFiles.makeDirectory(folder)
        return try await row.build(RoutingRowContext(root: kindRoot, paths: SafetyNetPathRenderer(root: kindRoot))).item
    }

    /// Waits until the window shows `name`'s kind: what is installed, whatever mode it sits in.
    private func settle(_ harness: ViewSwitchWindowHarness, on name: String) async -> Bool {
        guard let kind = ViewSwitchKinds.all.first(where: { $0.name == name }),
              let shown = kind.outcome.components(separatedBy: " in ").first else { return false }
        let paths = SafetyNetPathRenderer(root: root)
        return await waitUntil(budget: .lookup) {
            ViewSwitchKinds.outcome(of: RoutingObserver.observe(harness.split, paths: paths, loaded: [])).hasPrefix(shown + " in ")
        }
    }
}

private extension ViewerViewController {
    /// Whether any of the genomics viewer's own views shows.
    var isViewerAreaShowingChrome: Bool {
        !viewerView.isHidden || !headerView.isHidden || !enhancedRulerView.isHidden
    }
}
