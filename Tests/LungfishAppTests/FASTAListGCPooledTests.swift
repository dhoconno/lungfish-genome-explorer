// FASTAListGCPooledTests.swift - The FASTA list's GC counts whole records and its bar pools the bases
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishApp

/// W-8 (S1, BIO): a record over 10,000 bases read a sample of 100 windows of 100 bases, and the bar's GC Content was
/// the plain mean of the records' values. On a real MEGAHIT assembly the bar read 49.39 against a true 46.01. The list
/// now counts every base of every record and keeps (G+C, A+C+G+T), and the bar is the sum of G+C over the sum of
/// A+C+G+T.
@MainActor
final class FASTAListGCPooledTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.close() }
        windows = []
        try await super.tearDown()
    }

    /// 10,000 bases at 30% and 100 at 70% pool to (3,000 + 70) / 10,100 = 30.4%. The old bar averaged them to 50.0.
    func testFASTAListGCBarIsPooled() throws {
        let list = try open([
            FASTAListGCPassTests.record("low", String(repeating: "GCCAAAAATT", count: 1_000)),
            FASTAListGCPassTests.record("high", String(repeating: "GGGCCCCAAT", count: 10)),
        ])
        XCTAssertEqual(FASTAListGCPassTests.barGC(list), "30.4%")
        XCTAssertEqual(FASTAListGCPassTests.gcCell(list, row: 0), "30.0%")
        XCTAssertEqual(FASTAListGCPassTests.gcCell(list, row: 1), "70.0%")
    }

    /// A record over 10,000 bases counts every base. The first half of each 200 bases is G and C and the second half A
    /// and T, so the old 100 windows of 100 bases each fell on G and C only and read 100.0 against a true 50.0.
    func testFASTAListGCCountsWholeLongRecord() throws {
        let block = String(repeating: "GC", count: 50) + String(repeating: "AT", count: 50)
        let list = try open([FASTAListGCPassTests.record("striped", String(repeating: block, count: 100))])
        XCTAssertEqual(FASTAListGCPassTests.gcCell(list, row: 0), "50.0%")
        XCTAssertEqual(FASTAListGCPassTests.barGC(list), "50.0%")
    }

    /// A record of only N has no A, C, G or T, so it reads a dash and adds nothing to the bar. The old code gave it 0.0
    /// and averaged that in, so 1,000 bases at 40% beside 1,000 N read 20.0.
    func testFASTAListAllNRecordDoesNotLowerBar() throws {
        let list = try open([
            FASTAListGCPassTests.record("forty", String(repeating: "GGCCAAAATT", count: 100)),
            FASTAListGCPassTests.record("unknown", String(repeating: "N", count: 1_000)),
        ])
        XCTAssertEqual(FASTAListGCPassTests.barGC(list), "40.0%")
        XCTAssertEqual(FASTAListGCPassTests.gcCell(list, row: 0), "40.0%")
        XCTAssertEqual(FASTAListGCPassTests.gcCell(list, row: 1), "\u{2014}")
    }

    // MARK: - Helpers

    /// Opens the records in a list in an offscreen window and waits for the GC pass to deliver.
    private func open(_ records: [LungfishCore.Sequence]) throws -> FASTACollectionViewController {
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
        list.configure(sequences: records, annotations: [], sourceNames: [:])
        XCTAssertTrue(
            waitUntilOnRunLoop(budget: .lookup) { FASTAListGCPassTests.barGC(list) != "" },
            "The GC pass never delivered."
        )
        return list
    }
}
