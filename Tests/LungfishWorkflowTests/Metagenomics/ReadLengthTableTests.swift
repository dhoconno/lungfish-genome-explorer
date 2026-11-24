// ReadLengthTableTests.swift - The table of fragments gives the verdicts the dictionary of arrays gave
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

final class ReadLengthTableTests: XCTestCase {
    private func r(_ mate: Int?, _ length: Int) -> KrakenReadLength { KrakenReadLength(mate: mate, length: length) }

    func testEveryShapeOfNamedFragmentGetsTheVerdictOfTheArrays() {
        let one = r(nil, 150)
        let pair = [r(1, 150), r(2, 148)]
        let three = [r(1, 150), r(2, 150), r(nil, 150)]
        var shapes: [(name: String, lines: [[KrakenReadLength]], found: [KrakenReadLength])] = []
        func shape(_ name: String, _ lines: [[KrakenReadLength]], _ found: [KrakenReadLength]) { shapes.append((name, lines, found)) }
        shape("single found", [[one]], [one])
        shape("single missing", [[one]], [])
        shape("single of another length", [[one]], [r(nil, 149)])
        shape("pair found", [pair], pair)
        shape("pair on two lines", [[pair[0]], [pair[1]]], pair)
        shape("pair with one mate", [pair], [pair[0]])
        shape("pair, mate 2 of another length", [pair], [pair[0], r(2, 147)])
        shape("three lengths found", [three], three)
        shape("three lengths, one missing", [three], Array(three.prefix(2)))
        shape("four lines", [[r(1, 150)], [r(2, 150)], [r(nil, 151)], [r(nil, 152)]], [r(1, 150), r(2, 150), r(nil, 151), r(nil, 152)])
        shape("mate 3", [[r(3, 150)]], [r(3, 150)])
        shape("length over 4 GB", [[r(nil, 5_000_000_000)]], [r(nil, 5_000_000_000)])
        shape("found twice", [[one]], [one, one])
        shape("found three times", [pair], pair + [pair[0]])
        shape("column not readable, found", [[]], [one])
        shape("column not readable, missing", [[]], [])
        for (name, lines, found) in shapes {
            let table = ReadLengthTable()
            for line in lines { table.record("id", expected: line) }
            for read in found { table.markFound("id", read) }
            let got = table.tally()
            var arrays = KrakenReadCheck()
            arrays.add(expected: lines.flatMap { $0 }, found: found)
            XCTAssertEqual([got.named, got.missing, got.otherLength], [arrays.named, arrays.missing, arrays.otherLength], name)
        }
    }

    func testAnIDWithNoLengthColumnIsExtractedButNotCountedAndAnUnknownIDIsNeverMarked() {
        let table = ReadLengthTable()
        table.record("no-column", expected: nil)
        table.markFound("no-column", r(nil, 150))
        table.markFound("unknown", r(nil, 150))
        XCTAssertTrue(table.contains("no-column"))
        XCTAssertFalse(table.contains("unknown"))
        XCTAssertFalse(table.isNamed("no-column"))
        let got = table.tally()
        XCTAssertEqual([got.named, got.missing, got.otherLength], [0, 0, 0])
        table.record("no-column", expected: [r(nil, 150)])
        XCTAssertTrue(table.isNamed("no-column"))
        XCTAssertEqual(table.count, 1)
    }

    func testTheIDFileHoldsEveryIDOnceAcrossTheChunkEdgeForASetAndForTheTable() throws {
        let root = try TestTempDirectory.make(prefix: "read-id-file")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        // 150,000 IDs of 37 characters and a line break are 5.7 MB, past the 4 MB chunk.
        let ids = Set((0..<150_000).map { id($0) })
        let table = ReadLengthTable()
        for name in ids { table.record(name, expected: [r(nil, 150)]) }
        let setFile = root.appendingPathComponent("set.txt")
        let tableFile = root.appendingPathComponent("table.txt")
        try ReadExtractionService.writeReadIDFile(ids, to: setFile)
        try ReadExtractionService.writeReadIDFile(table, to: tableFile)
        for file in [setFile, tableFile] {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.hasSuffix("\n"), "\(file.lastPathComponent): no line break after the last ID")
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(lines.count, ids.count, "\(file.lastPathComponent): one line an ID")
            XCTAssertEqual(Set(lines), ids, "\(file.lastPathComponent): every ID once, none cut or joined")
        }
    }

    private func id(_ index: Int) -> String {
        let tile = String(index % 10_000)
        return "A00123:45:H7KLMDSX5:1:1101:\(10_000 + index / 10_000):" + String(repeating: "0", count: 4 - tile.count) + tile
    }
}
