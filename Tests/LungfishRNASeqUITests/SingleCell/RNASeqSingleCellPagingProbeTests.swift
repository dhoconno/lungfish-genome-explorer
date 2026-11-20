// RNASeqSingleCellPagingProbeTests.swift - Probe of the cells table's paging on the main actor (lane CM-PAGES-PROBE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Opt-in and in no tier (`SCR/inv/SWIFT.md`, SC-PAGES-PROBE). With LUNGFISH_PERF_BENCH=1 unset every test here skips.
// With it set, this probe times what the single-cell view does on the main actor, as the shipped code runs it
// (`RNASeqSingleCellViewController.show` opens `RNASeqSingleCellPages`, and each new screen of the table asks it for a page),
// at two sizes. One is the 500,000-cell X5 result, whose folder LUNGFISH_RS_SC_VIEW_X5_RESULT names, as in
// `RNASeqSingleCellScaleEvidenceTests`. The other is a 1,000,000-cell `cells.sqlite` that this probe writes through
// `RNASeqCellsDatabaseWriter` with two not-host extras, because the X5 result holds no not-host data. A page is
// `cells(offset:limit:)` together with the `notHostColumns` subquery, which opens a second handle. Each case runs five
// times on a fresh `RNASeqSingleCellPages`, so no run reads a kept page. The first run is the cold one for the handle,
// and the file is still warm in the kernel's cache, since `purge` needs root. The probe asserts no bar. It measures, and
// it fails only when the X5 folder is missing or when it leaves a file behind.

import Darwin
import Foundation
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishRNASeqUI

final class RNASeqSingleCellPagingProbeTests: XCTestCase {
    static let benchVariable = "LUNGFISH_PERF_BENCH"
    static let resultVariable = "LUNGFISH_RS_SC_VIEW_X5_RESULT"
    /// The runs of each case, the first being the cold one.
    static let runs = 5
    static let syntheticCells = 1_000_000
    static let seed: UInt64 = 20_261_119

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment[Self.benchVariable] == "1", "Set LUNGFISH_PERF_BENCH=1 to run the paging probe.")
    }

    // MARK: - The two sizes

    @MainActor
    func testPagesOfTheX5Result() async throws {
        let path = ProcessInfo.processInfo.environment[Self.resultVariable] ?? ""
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            XCTFail("Set \(Self.resultVariable) to the .lungfishrnaseq folder that the CLI imported from the 410-tile X5 matrix. It is \(path.isEmpty ? "unset" : "missing at " + path).")
            return
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let before = Self.listing(of: url)
        let result = try RNASeqResultBundle.load(from: url)
        let cellsURL = try XCTUnwrap(try RNASeqSingleCellSummary.cellsURL(of: result, bundleURL: url))
        let startLoad = Self.loadAverage()
        let measured = try Self.probe(cellsURL: cellsURL)
        let endLoad = Self.loadAverage()
        print("CM-PAGES-PROBE X5 result=\(path) bytes=\(Self.size(of: cellsURL)) load_at_start=\(startLoad) load_at_end=\(endLoad)")
        Self.report("X5 result, no not-host data", cells: measured.cells, timings: measured.timings)
        XCTAssertGreaterThan(measured.cells, 0)
        XCTAssertEqual(Self.listing(of: url), before, "reading left a file in the result")
    }

    @MainActor
    func testPagesOfAMillionCellFile() async throws {
        let folder = try TestTempDirectory.make(prefix: "lungfish-paging-probe")
        // Teardown blocks run last in, first out, so the folder goes before the check that it is gone.
        addTeardownBlock { XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "the probe left its folder behind") }
        addTeardownBlock { TestTempDirectory.cleanup(folder) }
        let wrote = try Self.seconds { _ = try Self.writeSyntheticFile(cells: Self.syntheticCells, in: folder) }
        let cellsURL = folder.appendingPathComponent(RNASeqCellsDatabase.filename)
        let startLoad = Self.loadAverage()
        let measured = try Self.probe(cellsURL: cellsURL)
        let endLoad = Self.loadAverage()
        print("CM-PAGES-PROBE synthetic seed=\(Self.seed) write_s=\(String(format: "%.1f", wrote)) bytes=\(Self.size(of: cellsURL)) load_at_start=\(startLoad) load_at_end=\(endLoad)")
        Self.report("synthetic, two not-host extras with a count and a call for every cell", cells: measured.cells, timings: measured.timings)
        XCTAssertEqual(measured.cells, Self.syntheticCells)
        XCTAssertEqual(Self.listing(of: folder), [RNASeqCellsDatabase.filename], "reading left a file beside cells.sqlite")
    }

    // MARK: - The measure

    /// One time in seconds for each run of each case, the first run first.
    struct Timings {
        var order: [String] = []
        var runs: [String: [Double]] = [:]

        mutating func add(_ name: String, _ seconds: Double) {
            if runs[name] == nil { order.append(name) }
            runs[name, default: []].append(seconds)
        }
    }

    /// Runs each case `runs` times on the main actor. Every run opens a new `RNASeqSingleCellPages`, as `show` does, then
    /// reads the page of row 0, of row N/2 and of the last row. The two halves of each page follow it, each timed alone
    /// on a handle that the page has already warmed, so they show which half costs the time.
    @MainActor
    static func probe(cellsURL: URL) throws -> (cells: Int, timings: Timings) {
        var timings = Timings()
        var count = 0
        for _ in 0..<runs {
            var opened: RNASeqSingleCellPages?
            let showSeconds = try seconds { opened = try RNASeqSingleCellPages(cellsURL: cellsURL) }
            timings.add("show (open and SELECT count(*))", showSeconds)
            guard let pages = opened else { throw RNASeqResultError.unreadableFile(path: RNASeqCellsDatabase.filename, reason: "the probe could not open it") }
            count = pages.count
            let rows = [("row 0", 0), ("row N/2", count / 2), ("the last row", count - 1)]
            for (name, row) in rows {
                let index = row / RNASeqSingleCellPages.pageSize
                let pageSeconds = try seconds { _ = try pages.page(index) }
                timings.add("page at \(name)", pageSeconds)
            }
            pages.close()
            let database = try RNASeqCellsDatabase(url: cellsURL)
            for (name, row) in rows {
                let offset = (row / RNASeqSingleCellPages.pageSize) * RNASeqSingleCellPages.pageSize
                let cellsSeconds = try seconds { _ = try database.cells(offset: offset, limit: RNASeqSingleCellPages.pageSize) }
                timings.add("  half of the page at \(name), cells(offset:limit:)", cellsSeconds)
                let notHostSeconds = try seconds {
                    _ = try RNASeqCellsDatabase.notHostColumns(offset: offset, limit: RNASeqSingleCellPages.pageSize, inFileAt: cellsURL)
                }
                timings.add("  half of the page at \(name), notHostColumns", notHostSeconds)
            }
        }
        return (count, timings)
    }

    static func seconds(_ body: () throws -> Void) rethrows -> Double {
        let clock = ContinuousClock()
        let began = clock.now
        try body()
        let span = clock.now - began
        return Double(span.components.seconds) + Double(span.components.attoseconds) / 1e18
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    static func milliseconds(_ seconds: Double) -> String { String(format: "%.2f", seconds * 1000) }

    static func report(_ label: String, cells: Int, timings: Timings) {
        print("CM-PAGES-PROBE \(label), cells=\(cells), page size \(RNASeqSingleCellPages.pageSize), \(runs) runs")
        print("| case | first run (ms) | median of \(runs) (ms) | all runs (ms) |")
        print("|---|---|---|---|")
        for name in timings.order {
            let values = timings.runs[name] ?? []
            print("| \(name) | \(milliseconds(values.first ?? 0)) | \(milliseconds(median(values))) | \(values.map(milliseconds).joined(separator: ", ")) |")
        }
    }

    static func loadAverage() -> String {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return "unknown" }
        return loads.map { String(format: "%.2f", $0) }.joined(separator: "/")
    }

    static func size(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    }

    static func listing(of folder: URL) -> [String] {
        ((FileManager.default.enumerator(atPath: folder.path)?.allObjects as? [String]) ?? []).sorted()
    }

    // MARK: - The synthetic file

    /// A SplitMix64 stream, so the same seed writes the same file.
    struct SeededRandom: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }
    }

    /// A 16-base barcode and the `-1` suffix, in the order of `index`, so every barcode is unique and ascending.
    static func barcode(_ index: Int) -> String {
        var value = index
        var bases = [UInt8](repeating: 65, count: 16)
        for position in stride(from: 15, through: 0, by: -1) {
            bases[position] = [65, 67, 71, 84][value & 3]
            value >>= 2
        }
        return String(decoding: bases, as: UTF8.self) + "-1"
    }

    /// Writes `cells.sqlite` in `folder` with `total` cells of one sample and two not-host extras, each cell holding a
    /// count and a call for each extra (the dearest case for the page's joins). The writer takes the rows in chunks of
    /// 50,000 cells, inside its one transaction.
    @discardableResult
    static func writeSyntheticFile(cells total: Int, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(RNASeqCellsDatabase.filename)
        let writer = try RNASeqCellsDatabaseWriter(url: url)
        var random = SeededRandom(state: seed)
        let extras = [
            RNASeqCellsDatabase.NotHostExtra(extra: 1, name: "Spike-in", kind: "spike-in", mask: nil, maskWords: RNASeqSingleCellWords.noMask),
            RNASeqCellsDatabase.NotHostExtra(extra: 2, name: "Virus", kind: "virus", mask: nil, maskWords: RNASeqSingleCellWords.noMask),
        ]
        let records = [
            RNASeqCellsDatabase.NotHostRecord(record: 1, extra: 1, name: "spike-1", length: 1_000),
            RNASeqCellsDatabase.NotHostRecord(record: 2, extra: 2, name: "virus-1", length: 9_000),
        ]
        try writer.addNotHostExtras(extras, records: records)
        let flags = ["above the ambient pool", "in the ambient pool", "too few UMIs to call"]
        var first = 1
        while first <= total {
            let size = min(50_000, total - first + 1)
            let barcodes = (0..<size).map { barcode(first - 1 + $0) }
            let umis = (0..<size).map { _ in UInt64.random(in: 500...30_000, using: &random) }
            let genes = (0..<size).map { _ in UInt32.random(in: 200...6_000, using: &random) }
            try writer.addCells(sample: 1, firstCell: first, barcodes: barcodes, umis: umis, genes: genes)
            var rows: [RNASeqCellsDatabase.NotHostBarcode] = []
            var counts: [RNASeqCellsDatabase.NotHostCount] = []
            var calls: [RNASeqCellsDatabase.NotHostCall] = []
            for index in 0..<size {
                let cell = first + index
                rows.append(RNASeqCellsDatabase.NotHostBarcode(sample: 1, barcode: barcodes[index], cell: cell, rawUMIs: Int(umis[index]), inPool: false))
                for extra in extras.map(\.extra) {
                    let hits = Int.random(in: 0...400, using: &random)
                    counts.append(RNASeqCellsDatabase.NotHostCount(sample: 1, barcode: barcodes[index], extra: extra, record: 0, umis: hits,
                                                                   maskedUMIs: hits / 10, umisNM01: hits / 2, maskedUMIsNM01: hits / 20))
                    calls.append(RNASeqCellsDatabase.NotHostCall(sample: 1, extra: extra, cell: cell, p: Double.random(in: 0...1, using: &random),
                                                                 q: Double.random(in: 0...1, using: &random), flag: flags[Int.random(in: 0..<flags.count, using: &random)]))
                }
            }
            try writer.addNotHostBarcodes(rows, counts: counts, calls: calls)
            first += size
        }
        try writer.finish()
        return url
    }
}
