// GenotypeViewMemoryLineBelowToolbarTests.swift - The genotype viewer's own lines show below the toolbar (VS-GENO-LINE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishGenotypeUI

/// A toolbar with one item, so that the window's content layout starts below a toolbar as in the main window.
@MainActor
private final class OneItemToolbar: NSObject, NSToolbarDelegate {
    static let item = NSToolbarItem.Identifier("genotype-view-memory-line-item")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.item] }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.item] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Item"
        item.view = NSButton(title: "Item", target: nil, action: nil)
        return item
    }
}

/// The 2026.11.17 walk (F5 C, build 14701) found the genotype matrix's line "The data changed since your last visit,
/// so the view was reset." in the AX tree at top y 34, inside the window's 52 pt title bar and toolbar band, and not on
/// the shot. The genotype viewer draws that line itself, outside the Kit host, and its surface keeps the default pin at
/// the container's edge, under the toolbar. These cases run in a window that draws its content under a toolbar, as the
/// main window does, and read where each line sits (UX-F1-R17 items 2 to 6).
@MainActor
final class GenotypeViewMemoryLineBelowToolbarTests: GenotypeResultViewportTestCase {
    private var window: NSWindow?
    private var toolbarDelegate: OneItemToolbar?
    private var controllers: [GenotypeResultViewController] = []
    private var roots: [URL] = []

    override func tearDown() async throws {
        for controller in controllers { controller.detachHostPresentationCallbacks() }
        controllers = []
        window?.contentView = nil
        window?.close()
        window = nil
        toolbarDelegate = nil
        for root in roots { TestTempDirectory.cleanup(root) }
        roots = []
        try await super.tearDown()
    }

    // MARK: - Word 2 or 3 at the top

    /// The walk's case: the kept view's folder changed, so the reset line shows. It starts right at the toolbar's
    /// bottom, covers nothing, and the viewer's first content sits as far below the line's bottom as it sits below the
    /// toolbar with no line, so no blank band and no doubled band are left.
    func testTheResetLineStartsAtTheToolbarsBottomAndTheContentStartsAtItsBottom() async throws {
        let fixture = try makeFixture()
        try await keepAView(fixture)
        try recreateTheFolder(fixture)
        let window = makeWindow(toolbar: true)
        let controller = try await open(fixture, in: window)
        let root = controller.view
        layOut(window, root)

        XCTAssertGreaterThan(root.safeAreaInsets.top - root.additionalSafeAreaInsets.top, 0,
                             "the viewer runs under the title bar and toolbar")
        let line = try XCTUnwrap(resetLine(in: controller), "the folder changed, so the reset line shows")
        XCTAssertEqual(line.words, ViewMemoryWords.viewReset, "the words do not change")
        XCTAssertFalse(line.isHiddenOrHasHiddenAncestor)
        let visible = window.contentLayoutRect
        let frame = inWindow(line)
        XCTAssertFalse(frame.isEmpty, "the line has a frame, found \(frame)")
        XCTAssertLessThanOrEqual(frame.maxY, visible.maxY + 0.5,
                                 "the line starts below the toolbar, found its top at \(frame.maxY) pt against the content layout's top at \(visible.maxY) pt")
        XCTAssertEqual(frame.maxY, visible.maxY, accuracy: 0.5, "the line starts at the toolbar's bottom, with no band above it")
        XCTAssertGreaterThanOrEqual(frame.minY, visible.minY - 0.5)
        let safeTop = inWindow(root).maxY - root.safeAreaInsets.top
        XCTAssertEqual(frame.minY, safeTop, accuracy: 0.5, "the viewer's safe area, which its content follows, starts at the line's bottom")
        XCTAssertEqual(root.additionalSafeAreaInsets.top, frame.height, accuracy: 0.5,
                       "the room the line takes is its own height, so no doubled band")
        assertCoversNothing(line, in: root)
        let withLine = try XCTUnwrap(firstContentTop(in: root), "the viewer shows content")
        let gapBelowLine = frame.minY - withLine
        XCTAssertGreaterThanOrEqual(gapBelowLine, -0.5, "the first content starts below the line")

        // No loop and no jump: the window's own layout pass puts the line where it stays, and a second pass moves
        // nothing.
        XCTAssertFalse(line.hasAmbiguousLayout, "the line's place is set by its constraints alone")
        root.needsLayout = true
        layOut(window, root)
        XCTAssertEqual(inWindow(line), frame, "a second layout pass moves the line nowhere")
        XCTAssertEqual(root.additionalSafeAreaInsets.top, frame.height, accuracy: 0.5)

        // Reset View takes the line and its room away. The first content then sits below the toolbar at the same
        // distance it sat below the line, so the line added its own height and nothing more.
        controller.resetViewMemory()
        layOut(window, root)
        XCTAssertNil(resetLine(in: controller), "Reset View takes the line away")
        XCTAssertEqual(root.additionalSafeAreaInsets.top, 0, "the line went, so its room goes")
        let withoutLine = try XCTUnwrap(firstContentTop(in: root))
        XCTAssertEqual(visible.maxY - withoutLine, gapBelowLine, accuracy: 0.5,
                       "the first content sits as far below the toolbar with no line as it sat below the line's bottom: no blank band")
        XCTAssertEqual(withoutLine - withLine, frame.height, accuracy: 0.5,
                       "the line moved the content down by its own height only")
    }

    /// A window with no toolbar has no band to clear, so the line stays at the viewer's top and the content starts at
    /// its bottom.
    func testInAWindowWithNoToolbarTheResetLineStaysAtTheTop() async throws {
        let fixture = try makeFixture()
        try await keepAView(fixture)
        try recreateTheFolder(fixture)
        let window = makeWindow(toolbar: false)
        let controller = try await open(fixture, in: window)
        let root = controller.view
        layOut(window, root)

        XCTAssertEqual(root.safeAreaInsets.top - root.additionalSafeAreaInsets.top, 0, accuracy: 0.5,
                       "a window with no toolbar gives the viewer no band")
        let line = try XCTUnwrap(resetLine(in: controller), "the folder changed, so the reset line shows")
        XCTAssertEqual(line.words, ViewMemoryWords.viewReset)
        let frame = inWindow(line)
        XCTAssertFalse(frame.isEmpty, "the line has a frame, found \(frame)")
        XCTAssertEqual(frame.maxY, inWindow(root).maxY, accuracy: 0.5, "the line starts at the viewer's top")
        XCTAssertEqual(frame.minY, inWindow(root).maxY - root.safeAreaInsets.top, accuracy: 0.5,
                       "the viewer's content follows the line's bottom")
        assertCoversNothing(line, in: root)
    }

    // MARK: - Word 5c at the foot

    /// The kept percent bases came back on the same data, so word 5c shows at the foot. Under a toolbar it stays inside
    /// the window's content layout, covers nothing, and the content's foot sits on its top.
    func testTheSettingsLineStaysInViewAndCoversNothingUnderAToolbar() async throws {
        let fixture = try makeFixture()
        try await keepAView(fixture)
        let window = makeWindow(toolbar: true)
        let controller = try await open(fixture, in: window)
        let root = controller.view
        layOut(window, root)

        XCTAssertNil(resetLine(in: controller), "the same data shows no reset line")
        let line = try XCTUnwrap(settingsLine(in: controller), "the kept percent bases came back, so word 5c shows")
        XCTAssertEqual(line.displayedText, ViewMemoryFilterLineForm.changesValues.text)
        let visible = window.contentLayoutRect
        let frame = inWindow(line)
        XCTAssertFalse(frame.isEmpty, "the line has a frame, found \(frame)")
        XCTAssertLessThanOrEqual(frame.maxY, visible.maxY + 0.5, "the line is below the toolbar")
        XCTAssertGreaterThanOrEqual(frame.minY, visible.minY - 0.5, "the line is above the window's foot")
        XCTAssertEqual(root.additionalSafeAreaInsets.bottom, frame.height, accuracy: 0.5,
                       "the room the line takes is its own height")
        assertCoversNothing(line, in: root)
        let foot = try XCTUnwrap(lowestContentBottom(in: root), "the viewer shows content")
        XCTAssertEqual(foot, frame.maxY, accuracy: 0.5, "the content's foot sits on the line's top")
    }

    // MARK: - Helpers

    private struct Fixture {
        let bundleURL: URL
        let result: ONTGenotypeResultBundleData
        let store: ViewMemoryStore
    }

    private func makeFixture() throws -> Fixture {
        let root = try TestTempDirectory.make(prefix: "GenotypeLineBelowToolbar")
        roots.append(root)
        let storeRoot = try TestTempDirectory.make(prefix: "GenotypeLineBelowToolbarStore")
        roots.append(storeRoot)
        let bundleURL = root.appendingPathComponent("walk-geno.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try installCallOverrideManifest(in: bundleURL)
        let result = makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [],
            haplotypeAnalysis: makeUsableHaplotypedMiSeqAnalysis()
        )
        return Fixture(
            bundleURL: bundleURL, result: result,
            store: ViewMemoryStore(root: storeRoot.appendingPathComponent("view-memory", isDirectory: true)))
    }

    /// Opens the result with no window, changes the pickers and both percent bases, and ends the visit, so the store
    /// keeps a view for the bundle.
    private func keepAView(_ fixture: Fixture) async throws {
        let controller = makeMatrixAnnotationGuardedController()
        controller.viewMemoryStore = fixture.store
        _ = controller.view
        controller.configure(result: fixture.result)
        let settled = await waitUntil(budget: .standard) { controller.viewMemoryIsSettled }
        XCTAssertTrue(settled, "the open's restore did not run")
        var state = controller.testingDisplayState
        state.cellColorMode = .none
        state.hideFilteredHighlights = false
        state.supportDenominator = .sampleRetained
        state.matrixPercentDenominator = .sampleRetained
        controller.applyDisplayState(state)
        controller.detachHostPresentationCallbacks()
    }

    /// Replaces the bundle's folder with a new one at the same path, as the walk's data swap did, so the kept view's
    /// folder changed.
    private func recreateTheFolder(_ fixture: Fixture) throws {
        let before = ViewMemoryFolderIdentity.read(at: fixture.bundleURL)
        try FileManager.default.removeItem(at: fixture.bundleURL)
        try FileManager.default.createDirectory(at: fixture.bundleURL, withIntermediateDirectories: true)
        try installCallOverrideManifest(in: fixture.bundleURL)
        XCTAssertNotEqual(ViewMemoryFolderIdentity.read(at: fixture.bundleURL), before, "the folder is a new one")
    }

    /// A window as the main window draws it, its content under the title bar and a toolbar, or a plain titled window.
    private func makeWindow(toolbar: Bool) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .resizable]
        if toolbar { style.insert(.fullSizeContentView) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700), styleMask: style,
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        if toolbar {
            let delegate = OneItemToolbar()
            let bar = NSToolbar(identifier: "genotype-view-memory-line-toolbar")
            bar.delegate = delegate
            window.toolbar = bar
            toolbarDelegate = delegate
        }
        self.window = window
        return window
    }

    /// Opens the result in the window, as the app shows it, and waits for the open's restore.
    private func open(_ fixture: Fixture, in window: NSWindow) async throws -> GenotypeResultViewController {
        let controller = makeMatrixAnnotationGuardedController()
        controller.viewMemoryStore = fixture.store
        window.contentView = controller.view
        controller.configure(result: fixture.result)
        controllers.append(controller)
        let settled = await waitUntil(budget: .standard) { controller.viewMemoryIsSettled }
        XCTAssertTrue(settled, "the open's restore did not run")
        return controller
    }

    private func layOut(_ window: NSWindow, _ root: NSView) {
        window.layoutIfNeeded()
        root.layoutSubtreeIfNeeded()
    }

    private func inWindow(_ view: NSView) -> NSRect {
        view.convert(view.bounds, to: nil)
    }

    private static func isMemoryLine(_ view: NSView) -> Bool {
        view is ViewMemoryResetLineView || view is ViewMemoryFilterLineView
    }

    private func resetLine(in controller: GenotypeResultViewController) -> ViewMemoryResetLineView? {
        controller.view.subviews.compactMap { $0 as? ViewMemoryResetLineView }.first
    }

    private func settingsLine(in controller: GenotypeResultViewController) -> ViewMemoryFilterLineView? {
        controller.view.subviews.compactMap { $0 as? ViewMemoryFilterLineView }.first { !$0.isHidden }
    }

    /// The parts of the viewer on show that are not a line, with a frame, in window coordinates.
    private func contentFrames(in root: NSView) -> [NSRect] {
        root.subviews.filter { !Self.isMemoryLine($0) && !$0.isHidden }.map(inWindow).filter { !$0.isEmpty }
    }

    private func firstContentTop(in root: NSView) -> CGFloat? {
        contentFrames(in: root).map(\.maxY).max()
    }

    private func lowestContentBottom(in root: NSView) -> CGFloat? {
        contentFrames(in: root).map(\.minY).min()
    }

    /// The line covers no point of another visible part of the viewer, and none covers it.
    private func assertCoversNothing(_ memoryLine: NSView, in root: NSView, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(memoryLine.frame.height, 0, file: file, line: line)
        for other in root.subviews where other !== memoryLine && !other.isHidden {
            let overlap = memoryLine.frame.intersection(other.frame)
            let covered = overlap.isNull || overlap.width == 0 ? 0 : overlap.height
            XCTAssertLessThan(covered, 0.5, "\(type(of: memoryLine)) and \(type(of: other)) cover \(covered) points of each other",
                              file: file, line: line)
        }
    }
}
