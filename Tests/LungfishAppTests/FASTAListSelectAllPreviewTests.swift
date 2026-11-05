// FASTAListSelectAllPreviewTests.swift - Select All on a large FASTA list shows a count and a bounded preview
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishApp

/// W-34, Select All: the detail under the list formatted every selected record into one string on the main thread,
/// 19 s and 1.7 GB more at 20,000 records and past 6 GB at 100,000. It now shows a line naming how many records are
/// selected and a bounded preview, while every action from the selection still acts on all of them.
@MainActor
final class FASTAListSelectAllPreviewTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.close() }
        windows = []
        try await super.tearDown()
    }

    func testSelectAllOnTwentyThousandRecordsShowsACountAndABoundedPreview() throws {
        let list = makeList()
        var records = try FASTAListGCPassTests.records(count: 20_000, unit: "ACGTTGCAAC", prefix: "rec")
        records.append(try FASTAListGCPassTests.record("long", String(repeating: "ACGTTGCAAC", count: 150_000)))
        list.configure(sequences: records, annotations: [], sourceNames: [:])

        list.testTableView.selectAll(nil)

        let detail = try XCTUnwrap(Self.detailView(in: list))
        let shownRecords = detail.text.components(separatedBy: "\n").filter { $0.hasPrefix(">") }.count
        XCTAssertGreaterThan(shownRecords, 0, "The preview shows no record.")
        XCTAssertLessThanOrEqual(shownRecords, 100, "The preview formatted \(shownRecords) records.")
        XCTAssertLessThanOrEqual(detail.text.utf8.count, 1_100_000, "The preview is not bounded.")
        let lines = Self.labels(in: detail)
        XCTAssertTrue(lines.contains { $0.contains("20,001 records selected") }, "No line names the selection: \(lines)")
        XCTAssertEqual(list.selectedSequences().count, 20_001, "An action from the selection would not act on all of it.")
    }

    /// One record past the base bound shows its first bases and says so. A small pick shows whole, as before.
    func testOneLongRecordShowsItsFirstBasesAndASmallPickShowsWhole() throws {
        let list = makeList()
        list.configure(sequences: [
            try FASTAListGCPassTests.record("long", String(repeating: "ACGTTGCAAC", count: 150_000)),
            try FASTAListGCPassTests.record("short", "AACCGGTT"),
        ], annotations: [], sourceNames: [:])

        list.testSelectRows([0])
        let detail = try XCTUnwrap(Self.detailView(in: list))
        XCTAssertLessThanOrEqual(detail.text.utf8.count, 1_100_000, "One long record is not bounded.")
        XCTAssertTrue(Self.labels(in: detail).contains { $0.contains("1,500,000") }, "No line says the record is cut.")

        list.testSelectRows([1])
        XCTAssertEqual(detail.text, ">short\nAACCGGTT\n")
        XCTAssertFalse(Self.labels(in: detail).contains { !$0.isEmpty }, "A whole single record shows a note.")
    }

    /// UX SF1: the longest line of the note (one record past the base bound) wraps inside a narrow pane. It does not run
    /// past the pane's edge, and it takes more than one line.
    func testTheNoteWrapsAtANarrowWidth() throws {
        _ = NSApplication.shared
        let detail = FASTASelectionDetailView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = detail
        windows.append(window)
        detail.setSequences([try FASTAListGCPassTests.record("long", String(repeating: "ACGTTGCAAC", count: 150_000))])

        detail.layoutSubtreeIfNeeded()

        let label = try XCTUnwrap(detail.subviews.first { $0.accessibilityIdentifier() == "fasta-selection-note" })
        XCTAssertLessThanOrEqual(label.frame.maxX, detail.bounds.width, "The note runs past the pane: \(label.frame).")
        XCTAssertGreaterThan(label.frame.height, 2 * NSFont.smallSystemFontSize, "The note sits on one line: \(label.frame).")
    }

    // MARK: - Helpers

    private func makeList() -> FASTACollectionViewController {
        _ = NSApplication.shared
        let list = FASTACollectionViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = list
        window.layoutIfNeeded()
        windows.append(window)
        return list
    }

    private static func detailView(in list: FASTACollectionViewController) -> FASTASelectionDetailView? {
        var stack = [list.view]
        while let view = stack.popLast() {
            if let detail = view as? FASTASelectionDetailView { return detail }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// The visible labels in the detail, outside its text view.
    private static func labels(in detail: FASTASelectionDetailView) -> [String] {
        var found: [String] = []
        var stack: [NSView] = [detail]
        while let view = stack.popLast() {
            if let field = view as? NSTextField, !field.isHidden { found.append(field.stringValue) }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }
}
