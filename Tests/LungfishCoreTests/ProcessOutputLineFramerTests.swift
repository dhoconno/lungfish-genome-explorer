// ProcessOutputLineFramerTests.swift - Byte-level line framing of process output
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore

final class ProcessOutputLineFramerTests: XCTestCase {
    func testFramerHandlesEveryByteBoundaryAndPreservesEmptyLines() {
        let bytes = Data("α\r\nβ\n\nγ\rdelta\r\n最後".utf8)
        for chunkSize in 1...bytes.count {
            var framer = ProcessOutputLineFramer()
            var lines: [String] = []
            for start in stride(from: 0, to: bytes.count, by: chunkSize) {
                lines += framer.append(bytes.subdata(in: start..<min(start + chunkSize, bytes.count)))
            }
            lines += framer.finish()
            XCTAssertEqual(lines, ["α", "β", "", "γ", "delta", "最後"], "Chunk size \(chunkSize)")
            XCTAssertTrue(framer.finish().isEmpty)
        }
    }

    func testLinesAtTheCapFrameWholeAndLongerLinesArriveInCappedPieces() {
        var framer = ProcessOutputLineFramer(maxLineBytes: 8)
        XCTAssertEqual(framer.append(Data("12345678\n".utf8)), ["12345678"])
        XCTAssertEqual(framer.append(Data("123456789\n".utf8)), ["12345678", "9"])
        XCTAssertEqual(framer.append(Data("abcdefghijklmnopq".utf8)), ["abcdefgh", "ijklmnop"])
        XCTAssertEqual(framer.finish(), ["q"])
    }

    func testCappedPiecesNeverSplitAUTF8Scalar() {
        // Each "β" is two bytes, so a cut at byte 9 would land inside one.
        var framer = ProcessOutputLineFramer(maxLineBytes: 9)
        let lines = framer.append(Data(String(repeating: "β", count: 10).utf8)) + framer.finish()
        XCTAssertEqual(lines.joined(), String(repeating: "β", count: 10))
        XCTAssertTrue(lines.allSatisfy { $0.utf8.count <= 9 && !$0.contains("\u{FFFD}") })
    }

    func testOutputWithoutLineBreaksStaysBoundedAcrossChunks() {
        var framer = ProcessOutputLineFramer()
        var delivered = 0
        let chunk = Data(repeating: 0x61, count: 10_000)
        for _ in 0..<100 {
            for line in framer.append(chunk) {
                XCTAssertLessThanOrEqual(line.utf8.count, ProcessOutputLineFramer.defaultMaxLineBytes)
                delivered += line.utf8.count
            }
        }
        delivered += framer.finish().reduce(0) { $0 + $1.utf8.count }
        XCTAssertEqual(delivered, 1_000_000)
    }

    func testCRAtTheEndOfAChunkSwallowsTheLFThatStartsTheNext() {
        var framer = ProcessOutputLineFramer()
        XCTAssertEqual(framer.append(Data("a\r".utf8)), ["a"])
        XCTAssertEqual(framer.append(Data()), [])
        XCTAssertEqual(framer.append(Data("\nb\r\r\nc".utf8)), ["b", ""])
        XCTAssertEqual(framer.finish(), ["c"])
    }
}
