// AffectedResultsStripTests.swift - The viewer's strip above a result an earlier build made wrong
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishWorkflow
@testable import LungfishApp

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
        XCTAssertTrue(container.constraints.filter(\.isActive).isEmpty, "nothing refers to the removed surface")
    }

    func testMoreThanOneRowCountsTheOthersAndLeavesThemToTheInspector() throws {
        let rows = AffectedResults.rows(forAppVersion: "Lungfish 2026.10.29 (12045)", kind: .taxTriage)
        XCTAssertGreaterThan(rows.count, 2)
        let words = try XCTUnwrap(AffectedResultsStrip.words(for: rows))
        XCTAssertTrue(words.hasPrefix(rows[0].words))
        XCTAssertTrue(words.hasSuffix(" \(rows.count - 1) more notes are under Warnings in the Inspector."))
        XCTAssertEqual(AffectedResultsStrip.words(for: [rows[0]]), rows[0].words)
        XCTAssertNil(AffectedResultsStrip.words(for: []))
    }
}
