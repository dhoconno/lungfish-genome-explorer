// AffectedResultsStripTests.swift - The viewer's strip above a result an earlier build made wrong
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishTaxonomyUI

@MainActor
final class AffectedResultsStripTests: XCTestCase {
    /// A container with a surface pinned to its edges, as `ViewportHost.commit` installs one.
    private func container() -> (container: NSView, surface: NSView, top: NSLayoutConstraint) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let surface = NSView()
        surface.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(surface)
        let top = surface.topAnchor.constraint(equalTo: container.topAnchor)
        NSLayoutConstraint.activate([
            top,
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return (container, surface, top)
    }

    private func words(build: String, kind: AffectedResultKind = .taxTriage) -> String? {
        AffectedResultsStrip.words(for: AffectedResults.rows(forAppVersion: build, kind: kind))
    }

    func testTheStripShowsForARecordOfAnAffectedBuild() throws {
        let (container, surface, top) = container()
        let words = try XCTUnwrap(words(build: "Lungfish 2026.10.29 (12045)"))
        AffectedResultsStrip.place(words: words, above: surface, in: container)

        let strip = try XCTUnwrap(AffectedResultsStrip.strip(in: container))
        XCTAssertEqual(strip.label.stringValue, words)
        XCTAssertTrue(words.hasPrefix(try XCTUnwrap(AffectedResults.rows.first { $0.backlogID == "BUILDDB-BAM-FIT" }).sentence),
                      "the first row of the table leads")
        XCTAssertFalse(top.isActive, "the surface starts below the strip, not at the container's edge")
        XCTAssertTrue(container.constraints.contains {
            $0.isActive && $0.firstItem === surface && $0.firstAttribute == .top
                && $0.secondItem === strip && $0.secondAttribute == .bottom
        })
        container.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(strip.frame.height, 0)
        XCTAssertEqual(strip.frame.width, 640, accuracy: 0.5)
    }

    func testTheStripIsTallForEveryLineOfTheLongestWords() throws {
        // A wrapping label reports its whole text on one line as its width unless it is told its width
        // (walk finding NAO-NOTE-WIDENS-WINDOW), so the strip must neither widen the window nor cut a line.
        let longest = try XCTUnwrap(AffectedResults.rows.map(\.words).max { $0.count < $1.count })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable],
            backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let (container, surface, _) = container()
        window.contentView = container
        AffectedResultsStrip.place(words: longest, above: surface, in: container)
        window.layoutIfNeeded()
        container.layoutSubtreeIfNeeded()

        let strip = try XCTUnwrap(AffectedResultsStrip.strip(in: container))
        let label = strip.label
        let cell = try XCTUnwrap(label.cell)
        let tall = CGFloat.greatestFiniteMagnitude
        let oneLine = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: CGFloat(100_000), height: tall)).height
        let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: tall)).height
        XCTAssertEqual(window.frame.width, 800, accuracy: 1, "the strip does not widen the window")
        XCTAssertEqual(strip.frame.width, 800, accuracy: 1, "the strip spans the viewer")
        XCTAssertLessThanOrEqual(label.frame.maxX, strip.bounds.width, "the words end inside the strip")
        XCTAssertGreaterThan(needed, oneLine * 1.5, "the words need more than one line at this width")
        XCTAssertGreaterThan(label.frame.height, oneLine * 1.5,
                             "the strip grows past one line, found \(label.frame.height) pt for a line of \(oneLine) pt")
        XCTAssertGreaterThanOrEqual(label.frame.height, needed - 1,
                                    "the strip is tall enough for every line, found \(label.frame.height) pt for \(needed) pt")
    }

    /// The rows of the walk's result, an EsViritu result made by build 11807, and the strip's words for them.
    private func walkRows() throws -> (rows: [AffectedResultRow], words: String) {
        let rows = AffectedResults.rows(forAppVersion: "Lungfish 2026.10.28 (11807)", kind: .esViritu)
        XCTAssertGreaterThan(rows.count, 1)
        return (rows, try XCTUnwrap(AffectedResultsStrip.words(for: rows)))
    }

    func testTheStripsWordsShowBelowTheTitleBarOfAWindowThatDrawsUnderIt() throws {
        // Walk finding AFFECTED-STRIP-NO-WORDS: the main window draws its content under the title bar and toolbar
        // (.fullSizeContentView), and the strip took the viewer's top edge, so the bar covered all of its words and
        // left a 1 to 2 pt line. A surface pinned to that edge keeps its own content below the bar, the strip did not.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let viewer = ViewerViewController()
        window.contentView = viewer.view
        _ = try viewer.showSurface(.analysis(.kraken2), input: TaxonomyViewController(), as: Kraken2Surface.self)
        let surfaceView = try XCTUnwrap(viewer.installedSurface?.viewController.view)
        let (rows, words) = try walkRows()

        viewer.showAffectedResultsStrip(rows: rows)
        window.layoutIfNeeded()
        viewer.view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(viewer.view.safeAreaInsets.top, 0, "the viewer runs under the title bar, as in the main window")
        let label = try XCTUnwrap(AffectedResultsStrip.strip(in: viewer.view)).label
        XCTAssertEqual(label.stringValue, words)
        let cell = try XCTUnwrap(label.cell)
        let oneLine = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 100_000, height: 10_000)).height
        XCTAssertGreaterThan(label.frame.height, oneLine * 1.5,
                             "the words take more than one line, found \(label.frame.height) pt for a line of \(oneLine) pt")
        let visible = window.contentLayoutRect
        let labelInWindow = label.convert(label.bounds, to: nil)
        XCTAssertLessThanOrEqual(labelInWindow.maxY, visible.maxY + 0.5,
                                 "the words start below the title bar, found \(labelInWindow.maxY) pt against \(visible.maxY) pt")
        XCTAssertGreaterThanOrEqual(labelInWindow.minY, visible.minY - 0.5)
        let surfaceInWindow = surfaceView.convert(surfaceView.bounds, to: nil)
        XCTAssertLessThanOrEqual(surfaceInWindow.maxY, labelInWindow.minY, "the result starts below the words")
    }

    func testANoticeThatComesBeforeTheNextSurfaceStillShowsItsStripAboveThatSurface() throws {
        // The Inspector's lookup can end before the viewer installs the result it is about. The strip then sits above
        // the old surface, and the host puts the new one on top of it, pinned to the same edge.
        let viewer = ViewerViewController()
        viewer.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        _ = try viewer.showSurface(.analysis(.kraken2), input: TaxonomyViewController(), as: Kraken2Surface.self)
        let (rows, words) = try walkRows()
        viewer.showAffectedResultsStrip(rows: rows)

        _ = try viewer.showSurface(.analysis(.kraken2), input: TaxonomyViewController(), as: Kraken2Surface.self)

        let surfaceView = try XCTUnwrap(viewer.installedSurface?.viewController.view)
        let strip = try XCTUnwrap(AffectedResultsStrip.strip(in: viewer.view))
        XCTAssertEqual(strip.label.stringValue, words)
        XCTAssertTrue(strip.surfaceView === surfaceView, "the strip sits above the surface that shows")
        let order = viewer.view.subviews
        XCTAssertGreaterThan(try XCTUnwrap(order.firstIndex(of: strip)), try XCTUnwrap(order.firstIndex(of: surfaceView)),
                             "the strip is in front of the new surface")
        XCTAssertTrue(viewer.view.constraints.contains {
            $0.isActive && $0.firstItem === surfaceView && $0.firstAttribute == .top
                && $0.secondItem === strip && $0.secondAttribute == .bottom
        }, "the new surface starts below the strip")

        viewer.clearSurface(ifShowing: .analysis(.kraken2))
        XCTAssertNil(AffectedResultsStrip.strip(in: viewer.view), "a viewer with no result shows no strip")
    }

    func testANoticeWithNoSurfaceInstalledShowsItsStripWhenTheSurfaceInstalls() throws {
        // The host removes the old surface as a show begins, so the Inspector's notice can find no surface at all.
        let viewer = ViewerViewController()
        viewer.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let (rows, words) = try walkRows()
        viewer.showAffectedResultsStrip(rows: rows)
        XCTAssertNil(AffectedResultsStrip.strip(in: viewer.view), "no surface, no strip yet")

        _ = try viewer.showSurface(.analysis(.kraken2), input: TaxonomyViewController(), as: Kraken2Surface.self)

        let strip = try XCTUnwrap(AffectedResultsStrip.strip(in: viewer.view), "the surface that installs gets the strip")
        XCTAssertEqual(strip.label.stringValue, words)
        XCTAssertTrue(strip.surfaceView === viewer.installedSurface?.viewController.view)
    }

    func testANoticeBeforeADisplayThatClearsFirstStillEndsWithTheStrip() throws {
        // Every display clears the viewer before it installs its own content (clearSurfaceForNewContent), and that
        // clear takes the strip, so the words must outlast it.
        let viewer = ViewerViewController()
        viewer.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        _ = try viewer.showSurface(.analysis(.kraken2), input: TaxonomyViewController(), as: Kraken2Surface.self)
        let (rows, words) = try walkRows()
        viewer.showAffectedResultsStrip(rows: rows)

        viewer.clearSurfaceForNewContent()
        XCTAssertNil(AffectedResultsStrip.strip(in: viewer.view), "a viewer with no result shows no strip")
        _ = try viewer.showSurface(.analysis(.kraken2), input: TaxonomyViewController(), as: Kraken2Surface.self)

        let surfaceView = try XCTUnwrap(viewer.installedSurface?.viewController.view)
        let strip = try XCTUnwrap(AffectedResultsStrip.strip(in: viewer.view))
        XCTAssertEqual(strip.label.stringValue, words)
        XCTAssertTrue(strip.surfaceView === surfaceView)
        XCTAssertTrue(viewer.view.constraints.contains {
            $0.isActive && $0.firstItem === surfaceView && $0.firstAttribute == .top
                && $0.secondItem === strip && $0.secondAttribute == .bottom
        }, "the result starts below the strip")
    }

    func testAnEmptyNoticeEndsTheWords() throws {
        let viewer = ViewerViewController()
        viewer.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        _ = try viewer.showSurface(.analysis(.kraken2), input: TaxonomyViewController(), as: Kraken2Surface.self)
        viewer.showAffectedResultsStrip(rows: try walkRows().rows)
        viewer.showAffectedResultsStrip(rows: [])
        XCTAssertNil(AffectedResultsStrip.strip(in: viewer.view))

        viewer.clearSurfaceForNewContent()
        _ = try viewer.showSurface(.analysis(.kraken2), input: TaxonomyViewController(), as: Kraken2Surface.self)

        XCTAssertNil(AffectedResultsStrip.strip(in: viewer.view), "the next result gets no strip of the item before")
    }

    func testTheStripIsAbsentForARecordOfAnUnaffectedOrDevBuild() {
        for build in ["Lungfish 2026.11.7 (12972)", "Lungfish 2026.11.7 (dev)"] {
            let (container, surface, top) = container()
            let words = words(build: build)
            XCTAssertNil(words, build)
            AffectedResultsStrip.place(words: words, above: surface, in: container)
            XCTAssertNil(AffectedResultsStrip.strip(in: container), build)
            XCTAssertTrue(top.isActive, "the surface keeps its place at the container's edge")
        }
    }

    func testTheStripGoesWhenTheResultIsMadeAgainByAnUnaffectedBuild() throws {
        let (container, surface, top) = container()
        AffectedResultsStrip.place(words: words(build: "Lungfish 2026.10.29 (12045)"), above: surface, in: container)
        XCTAssertNotNil(AffectedResultsStrip.strip(in: container))
        AffectedResultsStrip.place(words: words(build: "Lungfish 2026.11.7 (12972)"), above: surface, in: container)
        XCTAssertNil(AffectedResultsStrip.strip(in: container))
        XCTAssertTrue(top.isActive, "the host's own constraint is back")
    }

    func testPlacingTwiceLeavesOneStripWithTheNewWords() throws {
        let (container, surface, _) = container()
        AffectedResultsStrip.place(words: words(build: "Lungfish 2026.10.29 (12045)"), above: surface, in: container)
        AffectedResultsStrip.place(words: words(build: "Lungfish 2026.10.28 (11807)", kind: .naoMgs), above: surface, in: container)
        XCTAssertEqual(container.subviews.compactMap { $0 as? AffectedResultsStripView }.count, 1)
        let strip = try XCTUnwrap(AffectedResultsStrip.strip(in: container))
        XCTAssertEqual(strip.label.stringValue, words(build: "Lungfish 2026.10.28 (11807)", kind: .naoMgs))
    }

    func testAnotherSurfaceInPlaceOfTheOneTheStripSitsAboveGetsNoStaleConstraint() throws {
        let (container, surface, _) = container()
        AffectedResultsStrip.place(words: words(build: "Lungfish 2026.10.29 (12045)"), above: surface, in: container)
        surface.removeFromSuperview()
        AffectedResultsStrip.place(words: nil, above: nil, in: container)
        XCTAssertNil(AffectedResultsStrip.strip(in: container))
        // The container keeps the constraints of its own safe-area guide, which the strip's top is pinned to.
        XCTAssertFalse(container.constraints.contains { constraint in
            constraint.isActive && [constraint.firstItem, constraint.secondItem].contains {
                $0 === surface || $0 is AffectedResultsStripView
            }
        }, "nothing refers to the removed surface or to a strip")
    }

    /// The rows the Inspector tells the viewer after a lookup of `item` found `envelope`.
    private func postedRows(for item: ProvenanceInspectableItem, record envelope: ProvenanceEnvelope) -> [AffectedResultRow] {
        let model = ProvenanceInspectorViewModel()
        model.resolvedEnvelope = envelope
        var posted: [AffectedResultRow] = []
        let token = NotificationCenter.default.addObserver(
            forName: .affectedResultsDidChange, object: model, queue: nil
        ) { note in
            posted = note.userInfo?[ProvenanceInspectorViewModel.affectedResultsRowsKey] as? [AffectedResultRow] ?? []
        }
        defer { NotificationCenter.default.removeObserver(token) }
        model.applyAffectedResults(kind: ProvenanceInspectorViewModel.affectedResultKind(for: item, envelope: envelope))
        return posted
    }

    func testTheStripShowsTheTrimSentenceAboveATrimmedFASTQBundle() throws {
        // A FASTQ bundle that `lungfish fastq trim` made with Stable 2026.11.7 (AFFECTED-KINDS-NOT-MAPPED).
        var trim = ProvenanceEnvelope.fixture()
        trim.workflowName = "lungfish fastq trim"
        trim.runtimeIdentity = ProvenanceRuntimeIdentity(appVersion: "Lungfish 2026.11.7 (12972)")
        let bundle = ProvenanceInspectableItem(
            url: URL(fileURLWithPath: "/tmp/affected-results-test/reads.lungfishfastq"), sidebarType: .fastqBundle,
            contentMode: .fastq, displayName: "reads"
        )
        let (container, surface, _) = container()
        AffectedResultsStrip.place(
            words: AffectedResultsStrip.words(for: postedRows(for: bundle, record: trim)), above: surface, in: container
        )

        let words = try XCTUnwrap(AffectedResultsStrip.strip(in: container), "a trimmed bundle of 2026.11.7 gets the strip")
            .label.stringValue
        XCTAssertTrue(words.hasPrefix("The version that made these trimmed reads gave fastp the read pairs in the order "
                                      + "the import stored them, so fastp could choose the wrong adapter"), words)
        XCTAssertTrue(words.hasSuffix(" 1 more note is under Warnings on the Inspector's Provenance tab."),
                      "the single-read row is under Warnings, found \(words)")
    }

    func testMoreThanOneRowCountsTheOthersAndLeavesThemToTheInspector() throws {
        let rows = AffectedResults.rows(forAppVersion: "Lungfish 2026.10.29 (12045)", kind: .taxTriage)
        XCTAssertGreaterThan(rows.count, 2)
        let words = try XCTUnwrap(AffectedResultsStrip.words(for: rows))
        XCTAssertTrue(words.hasPrefix(rows[0].words))
        XCTAssertTrue(words.hasSuffix(" \(rows.count - 1) more notes are under Warnings on the Inspector's Provenance tab."),
                      "the Warnings are on the Provenance tab only")
        XCTAssertEqual(AffectedResultsStrip.words(for: [rows[0]]), rows[0].words)
        XCTAssertNil(AffectedResultsStrip.words(for: []))
    }
}
