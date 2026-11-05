// FASTAListGCPassTests.swift - The FASTA list counts GC off the main thread and shows only values it has counted
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishCore
import LungfishKit
import LungfishTestSupport
@testable import LungfishApp

/// W-34 after SF1LIST: the list's view tree stays flat at any count, but `configure` counted every record's GC on the
/// main thread (12.4 s at 20,000 records in Debug), so the app held while a large list opened. The pass now runs off
/// the main thread. A cell and the bar read blank until a value is known, never 0.0, and a pass for an older list never
/// writes into a newer one.
@MainActor
final class FASTAListGCPassTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.close() }
        windows = []
        try await super.tearDown()
    }

    /// The open returns before the pass ends, the main thread runs other work while it counts, and nothing reads a GC
    /// value until the pass delivers one.
    func testOpenReturnsWithTheMainThreadFreeWhileThePassRuns() throws {
        let list = makeList()
        var records = try Self.records(count: 20_000, unit: "ACGTTGCAAC", prefix: "rec")
        records.append(try Self.record("long", String(repeating: "ACGTTGCAAC", count: 150_000)))

        list.configure(sequences: records, annotations: [], sourceNames: [:])
        XCTAssertEqual(Self.gcCell(list, row: 0), "", "A cell read a GC value before the pass counted it.")
        XCTAssertEqual(Self.barGC(list), "", "The bar read a GC value before the pass counted it.")

        let turn = MainTurn()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                turn.ran = true
                turn.barGC = Self.barGC(list)
            }
        }
        XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup) { turn.ran }, "The main thread ran nothing after the open.")
        XCTAssertEqual(turn.barGC, "", "The pass ended before the main thread ran its next turn, so it ran on the main thread.")

        XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup) { Self.barGC(list) != "" }, "The pass never delivered.")
        XCTAssertEqual(Self.barGC(list), "50.0%")
        XCTAssertEqual(Self.gcCell(list, row: 0), "50.0%")
        XCTAssertEqual(list.testTableView.numberOfRows, 20_001, "The list dropped records.")
    }

    /// A second open while the first list's pass runs keeps only the second list's values. The first list is small, so
    /// its pass ends first, and without a generation token its bar value would show over the second list.
    func testSecondOpenDiscardsTheFirstPassValues() throws {
        let list = makeList()
        let first = try Self.records(count: 5, unit: "GGGCCCCAAT", prefix: "old")
        var second = try Self.records(count: 20_000, unit: "ACGTTGCAAC", prefix: "new")
        second.append(try Self.record("long", String(repeating: "ACGTTGCAAC", count: 150_000)))

        list.configure(sequences: first, annotations: [], sourceNames: [:])
        list.configure(sequences: second, annotations: [], sourceNames: [:])
        XCTAssertEqual(Self.barGC(list), "", "The bar read a GC value before the second list's pass counted it.")

        var firstShown: String?
        XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup) {
            let value = Self.barGC(list)
            if firstShown == nil, !value.isEmpty { firstShown = value }
            return firstShown != nil
        }, "The pass never delivered.")
        XCTAssertEqual(firstShown, "50.0%", "The first list's pass wrote its GC into the second list.")
        XCTAssertEqual(Self.gcCell(list, row: 0), "50.0%")
    }

    /// A sort by GC asked for before the values are known puts every row in GC order once they are.
    func testSortByGCBeforeThePassEndsOrdersEveryRowOnceKnown() throws {
        let list = makeList()
        var records: [LungfishCore.Sequence] = []
        for index in 0..<600 {
            let strong = (index * 7) % 11
            let unit = String(repeating: "G", count: strong) + String(repeating: "A", count: 10 - strong)
            records.append(try Self.record("gc\(strong * 10)-\(index)", String(repeating: unit, count: 30)))
        }

        list.configure(sequences: records, annotations: [], sourceNames: [:])
        list.testSort(column: "gc", ascending: true)
        XCTAssertEqual(Self.gcCell(list, row: 0), "", "A cell read a GC value before the pass counted it.")

        XCTAssertTrue(waitUntilOnRunLoop(budget: .lookup) { Self.barGC(list) != "" }, "The pass never delivered.")
        let table = list.testTableView
        XCTAssertEqual(table.numberOfRows, 600)
        let order = (0..<table.numberOfRows).map { Self.nameGC(Self.cell(list, column: "name", row: $0)) }
        XCTAssertEqual(order, order.sorted(), "The rows are not in GC order once the values are known.")
        XCTAssertEqual(Self.gcCell(list, row: 0), "0.0%")
        XCTAssertEqual(Self.gcCell(list, row: 599), "100.0%")
    }

    // MARK: - Helpers

    @MainActor
    private final class MainTurn {
        var ran = false
        var barGC: String?
    }

    private func makeList() -> FASTACollectionViewController {
        _ = NSApplication.shared
        let list = FASTACollectionViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = list
        window.setContentSize(NSSize(width: 1000, height: 800))
        window.layoutIfNeeded()
        windows.append(window)
        return list
    }

    static func record(_ name: String, _ bases: String) throws -> LungfishCore.Sequence {
        try LungfishCore.Sequence(name: name, alphabet: .dna, bases: bases)
    }

    static func records(count: Int, unit: String, prefix: String) throws -> [LungfishCore.Sequence] {
        let bases = String(repeating: unit, count: 30)
        return try (0..<count).map { try record("\(prefix)\($0)", bases) }
    }

    static func cell(_ list: FASTACollectionViewController, column: String, row: Int) -> String {
        let table = list.testTableView
        guard let index = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == column }),
              let cell = table.view(atColumn: index, row: row, makeIfNecessary: true) as? NSTableCellView else {
            return "<no cell>"
        }
        return cell.textField?.stringValue ?? "<no text>"
    }

    static func gcCell(_ list: FASTACollectionViewController, row: Int) -> String {
        cell(list, column: "gc", row: row)
    }

    static func summaryBar(_ list: FASTACollectionViewController) -> FASTACollectionSummaryBar? {
        var stack = [list.view]
        while let view = stack.popLast() {
            if let bar = view as? FASTACollectionSummaryBar { return bar }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    static func barGC(_ list: FASTACollectionViewController) -> String {
        summaryBar(list)?.cards.first { $0.label == "GC Content" }?.value ?? "<no card>"
    }

    /// The GC level a test record's name carries, as in `gc70-12`.
    private static func nameGC(_ name: String) -> Int {
        Int(name.dropFirst(2).prefix { $0 != "-" }) ?? -1
    }
}
