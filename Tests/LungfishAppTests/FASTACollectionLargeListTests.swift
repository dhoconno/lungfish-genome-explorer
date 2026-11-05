// FASTACollectionLargeListTests.swift - A large FASTA list builds row views only for the rows on screen
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishApp

/// The 2026-11-04 walk (W-34) selected a loose FASTA of 20,000 records plus one of 1.5 Mbp. "Loading..." never ended,
/// and the app grew past 150 GB while Auto Layout solved a view tree that held a row view and five cells for every
/// record. Since the list joined the ViewportHost its `configure` ran before its view loaded, so the table took its
/// first rows while it sat in no scroll view and treated its whole height as visible.
///
/// Each test opens 500 records first and stops there if that list already holds more row views than the rows on
/// screen, so the base fails at a size this Mac can hold. Then it opens the walk's size in a real offscreen window.
@MainActor
final class FASTACollectionLargeListTests: XCTestCase {
    /// Row views a table may keep beyond the rows on screen, for its scroll overdraw.
    private static let rowBuffer = 60

    private var scratch: URL?

    override func tearDown() async throws {
        if let scratch { TestTempDirectory.cleanup(scratch) }
        scratch = nil
        try await super.tearDown()
    }

    /// The loose-file route, `ViewerViewController.displayDocument`, which the sidebar takes for one FASTA file.
    func testTwentyThousandRecordsAddNoViewPerRecord() throws {
        let small = try open(recordCount: 500, longRecord: false) { viewer, sequences in
            viewer.displayDocument(try self.document(sequences))
        }
        defer { small.window.close() }
        XCTAssertEqual(small.numberOfRows, 500)
        XCTAssertLessThanOrEqual(small.rowViews, small.visibleRows + Self.rowBuffer,
                                 "500 records built \(small.rowViews) row views for \(small.visibleRows) rows on screen.")
        guard small.rowViews <= small.visibleRows + Self.rowBuffer else { return }

        let large = try open(recordCount: 20_000, longRecord: true) { viewer, sequences in
            viewer.displayDocument(try self.document(sequences))
        }
        defer { large.window.close() }
        XCTAssertEqual(large.numberOfRows, 20_001)
        XCTAssertLessThanOrEqual(large.rowViews, large.visibleRows + Self.rowBuffer)
        XCTAssertLessThanOrEqual(abs(large.views - small.views), 50, "Views grew with the record count.")
        XCTAssertLessThanOrEqual(abs(large.constraints - small.constraints), 50, "Constraints grew with the record count.")
        XCTAssertLessThan(large.elapsed, WaitBudget.lookup.duration)
    }

    /// The sidebar's multi-select route (`MainSplitViewController+MultiDocument.swift:355`), with a Source column.
    func testMultiSelectListAddsNoViewPerRecord() throws {
        let display: (ViewerViewController, [LungfishCore.Sequence]) throws -> Void = { viewer, sequences in
            var names: [UUID: String] = [:]
            for (index, sequence) in sequences.enumerated() { names[sequence.id] = index % 2 == 0 ? "a.fasta" : "b.fasta" }
            viewer.displayFASTACollection(sequences: sequences, annotations: [], sourceNames: names)
        }
        let small = try open(recordCount: 500, longRecord: false, display: display)
        defer { small.window.close() }
        XCTAssertLessThanOrEqual(small.rowViews, small.visibleRows + Self.rowBuffer)
        guard small.rowViews <= small.visibleRows + Self.rowBuffer else { return }

        let large = try open(recordCount: 20_000, longRecord: true, display: display)
        defer { large.window.close() }
        XCTAssertEqual(large.numberOfRows, 20_001)
        XCTAssertLessThanOrEqual(large.rowViews, large.visibleRows + Self.rowBuffer)
        XCTAssertLessThan(large.elapsed, WaitBudget.lookup.duration)
    }

    /// Select All on an open list of the walk's size keeps the row views bounded and returns inside the budget.
    func testSelectAllOnALargeListKeepsRowViewsBounded() throws {
        let small = try open(recordCount: 500, longRecord: false) { viewer, sequences in
            viewer.displayDocument(try self.document(sequences))
        }
        defer { small.window.close() }
        guard small.rowViews <= small.visibleRows + Self.rowBuffer else {
            return XCTFail("500 records built \(small.rowViews) row views for \(small.visibleRows) rows on screen.")
        }

        let large = try open(recordCount: 20_000, longRecord: true) { viewer, sequences in
            viewer.displayDocument(try self.document(sequences))
        }
        defer { large.window.close() }
        let clock = ContinuousClock()
        let start = clock.now
        large.list.testTableView.selectAll(nil)
        large.window.layoutIfNeeded()
        large.window.displayIfNeeded()
        let elapsed = clock.now - start
        XCTAssertEqual(large.list.testTableView.numberOfSelectedRows, 20_001)
        XCTAssertLessThanOrEqual(Self.rowViews(in: large.list.testTableView), large.visibleRows + Self.rowBuffer)
        XCTAssertLessThan(elapsed, WaitBudget.lookup.duration)
    }

    // MARK: - Helpers

    private struct Opened {
        let window: NSWindow
        let list: FASTACollectionViewController
        let numberOfRows: Int
        let rowViews: Int
        let visibleRows: Int
        let views: Int
        let constraints: Int
        let elapsed: Duration
    }

    private func open(
        recordCount: Int,
        longRecord: Bool,
        display: (ViewerViewController, [LungfishCore.Sequence]) throws -> Void
    ) throws -> Opened {
        _ = NSApplication.shared
        let sequences = try Self.records(count: recordCount, longRecord: longRecord)
        let viewer = ViewerViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = viewer
        window.setContentSize(NSSize(width: 1000, height: 800))
        window.layoutIfNeeded()

        let clock = ContinuousClock()
        let start = clock.now
        try display(viewer, sequences)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let elapsed = clock.now - start

        let list = try XCTUnwrap(viewer.children.compactMap { $0 as? FASTACollectionViewController }.first)
        let table = list.testTableView
        let (views, constraints) = Self.tally(window)
        return Opened(
            window: window, list: list, numberOfRows: table.numberOfRows, rowViews: Self.rowViews(in: table),
            visibleRows: table.rows(in: table.visibleRect).length, views: views, constraints: constraints, elapsed: elapsed
        )
    }

    private func document(_ sequences: [LungfishCore.Sequence]) throws -> LoadedDocument {
        let folder = try scratch ?? TestTempDirectory.make(prefix: "fasta-large-list")
        scratch = folder
        let url = folder.appendingPathComponent("many-records.fasta")
        if !FileManager.default.fileExists(atPath: url.path) {
            try ">placeholder\nACGT\n".write(to: url, atomically: true, encoding: .utf8)
        }
        let document = LoadedDocument(url: url, type: .fasta)
        document.sequences = sequences
        return document
    }

    private static func rowViews(in table: NSTableView) -> Int {
        table.subviews.filter { $0 is NSTableRowView }.count
    }

    private static func tally(_ window: NSWindow) -> (views: Int, constraints: Int) {
        guard let root = window.contentView?.superview ?? window.contentView else { return (0, 0) }
        var views = 0
        var constraints = 0
        var stack = [root]
        while let view = stack.popLast() {
            views += 1
            constraints += view.constraints.count
            stack.append(contentsOf: view.subviews)
        }
        return (views, constraints)
    }

    /// Short records, as the count is the stressor here, plus the walk's one record of 1.5 Mbp.
    private static func records(count: Int, longRecord: Bool) throws -> [LungfishCore.Sequence] {
        let unit = "ACGTTGCAAC"
        let short = String(repeating: unit, count: 30)
        var records = try (0..<count).map { try LungfishCore.Sequence(name: "rec\($0)", alphabet: .dna, bases: short) }
        if longRecord {
            records.append(try LungfishCore.Sequence(name: "long", alphabet: .dna, bases: String(repeating: unit, count: 150_000)))
        }
        return records
    }
}
