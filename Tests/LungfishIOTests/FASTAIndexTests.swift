// FASTAIndexTests.swift - The byte parser of FASTAIndex against the string parser it replaced
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

/// The body `FASTAIndex.init(url:)` had before the byte parser, kept as the oracle.
private func stringParserEntries(url: URL) throws -> [FASTAIndex.Entry] {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw FASTAError.indexNotFound(url)
    }

    let content = try String(contentsOf: url, encoding: .utf8)
    var entries: [FASTAIndex.Entry] = []

    for (lineNum, line) in content.split(separator: "\n").enumerated() {
        let parts = line.split(separator: "\t")
        guard parts.count >= 5 else {
            throw FASTAError.invalidIndex("Line \(lineNum + 1): expected 5 tab-separated fields")
        }

        guard let length = Int(parts[1]),
              let offset = Int(parts[2]),
              let lineBases = Int(parts[3]),
              let lineWidth = Int(parts[4]) else {
            throw FASTAError.invalidIndex("Line \(lineNum + 1): invalid numeric values")
        }

        entries.append(FASTAIndex.Entry(
            name: String(parts[0]),
            length: length,
            offset: offset,
            lineBases: lineBases,
            lineWidth: lineWidth
        ))
    }
    return entries
}

final class FASTAIndexTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTAIndexTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    /// `.fai` files that reach each branch of the parse, with a label for the failure message.
    private static let fixtures: [(label: String, bytes: [UInt8])] = [
        ("two records", Array("chr1\t1000\t6\t50\t51\nchr2\t500\t1100\t50\t51\n".utf8)),
        ("no final line feed", Array("chr1\t1000\t6\t50\t51\nchr2\t500\t1100\t50\t51".utf8)),
        ("extra fields", Array("chr1\t1000\t6\t50\t51\textra\tmore\nchr2\t500\t1100\t50\t51\t\n".utf8)),
        ("blank lines", Array("\n\nchr1\t1000\t6\t50\t51\n\n\nchr2\t500\t1100\t50\t51\n\n".utf8)),
        ("empty fields", Array("chr1\t\t1000\t6\t\t50\t51\n\tchr2\t500\t1100\t50\t51\n".utf8)),
        ("signed numbers", Array("chr1\t+1000\t-6\t+50\t-0\n".utf8)),
        ("Int.min and Int.max", Array("chr1\t-9223372036854775808\t9223372036854775807\t1\t2\n".utf8)),
        ("overflow", Array("chr1\t9223372036854775808\t6\t50\t51\n".utf8)),
        ("sign without digits", Array("chr1\t+\t6\t50\t51\n".utf8)),
        ("letter in a number", Array("chr1\t1000\t6\t5O\t51\n".utf8)),
        ("space in a number", Array("chr1\t1000\t 6\t50\t51\n".utf8)),
        ("four fields", Array("chr1\t1000\t6\t50\n".utf8)),
        ("bad line after a blank line", Array("chr1\t1000\t6\t50\t51\n\nchr2\t500\t1100\n".utf8)),
        ("tabs only", Array("\t\t\t\t\n".utf8)),
        ("duplicate names", Array("chr1\t1000\t6\t50\t51\nchr2\t500\t1100\t50\t51\nchr1\t2000\t1700\t60\t61\n".utf8)),
        ("CRLF with five fields", Array("chr1\t1000\t6\t50\t51\r\nchr2\t500\t1100\t50\t51\r\n".utf8)),
        ("CRLF with six fields", Array("chr1\t1000\t6\t50\t51\t0\r\nchr2\t500\t1100\t50\t51\t0\r\n".utf8)),
        ("CR LF after a line feed", Array("chr1\t1000\t6\t50\t51\n\r\nchr2\t500\t1100\t50\t51\n".utf8)),
        ("lone CR", Array("chr1\t1000\t6\t50\t51\rchr2\t500\t1100\t50\t51\n".utf8)),
        ("spaces in a name", Array("chr1 some words\t1000\t6\t50\t51\n chr2 \t500\t1100\t50\t51\n".utf8)),
        ("trailing CR without a line feed", Array("chr1\t1000\t6\t50\t51\r".utf8)),
        ("CRLF on the last line only", Array("chr1\t1000\t6\t50\t51\nchr2\t500\t1100\t50\t51\r\n".utf8)),
        ("only a CRLF", Array("\r\n".utf8)),
        ("CRLF inside a name", Array("chr\r\n1\t1000\t6\t50\t51\n".utf8)),
        ("UTF-8 names", Array("contig_\u{E9}\t10\t11\t10\t11\n\u{E9}\t10\t33\t10\t11\ne\u{301}\t10\t50\t10\t11\n".utf8)),
        ("byte order mark", [0xEF, 0xBB, 0xBF] + Array("chr1\t1000\t6\t50\t51\n".utf8)),
        ("invalid UTF-8", Array("chr".utf8) + [0xFF] + Array("1\t1000\t6\t50\t51\n".utf8)),
        ("empty file", []),
    ]

    private static func faiLine(_ entry: FASTAIndex.Entry) -> String {
        "\(entry.name)\t\(entry.length)\t\(entry.offset)\t\(entry.lineBases)\t\(entry.lineWidth)\n"
    }

    private static func summary(of error: Error) -> String {
        if let fastaError = error as? FASTAError {
            return "FASTAError \(fastaError)"
        }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }

    private func write(_ label: String) throws -> URL {
        let fixture = try XCTUnwrap(Self.fixtures.first { $0.label == label })
        let url = tempDirectory.appendingPathComponent("\(UUID().uuidString).fai")
        try Data(fixture.bytes).write(to: url)
        return url
    }

    /// Every entry of the index in order, duplicates included, as `write(to:)` lists them.
    private func faiText(of index: FASTAIndex) throws -> String {
        let url = tempDirectory.appendingPathComponent("\(UUID().uuidString).fai")
        try index.write(to: url)
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    func testByteParserMatchesStringParser() throws {
        for fixture in Self.fixtures {
            let url = try write(fixture.label)
            let expected = Result { try stringParserEntries(url: url) }
            let actual = Result { try FASTAIndex(url: url) }

            switch (expected, actual) {
            case let (.success(entries), .success(index)):
                XCTAssertEqual(try faiText(of: index), entries.map(Self.faiLine).joined(), fixture.label)
                XCTAssertEqual(index.sequenceNames, entries.map(\.name), fixture.label)
                XCTAssertEqual(index.count, entries.count, fixture.label)
                for entry in entries {
                    // The string parser's dictionary kept the last entry of a name, under String equality.
                    let last = try XCTUnwrap(entries.last { $0.name == entry.name })
                    XCTAssertEqual(index.entry(for: entry.name).map(Self.faiLine), Self.faiLine(last), "\(fixture.label) \(entry.name)")
                    XCTAssertEqual(index.length(of: entry.name), last.length, "\(fixture.label) \(entry.name)")
                }
            case let (.failure(expectedError), .failure(actualError)):
                XCTAssertEqual(Self.summary(of: actualError), Self.summary(of: expectedError), fixture.label)
            default:
                XCTFail("\(fixture.label): the string parser gave \(expected), the byte parser \(actual)")
            }
        }
    }

    func testTheEdgeCasesKeepTheirKnownResults() throws {
        XCTAssertEqual(try FASTAIndex(url: write("blank lines")).sequenceNames, ["chr1", "chr2"])
        XCTAssertEqual(try FASTAIndex(url: write("duplicate names")).entry(for: "chr1")?.length, 2000, "The last chr1 wins.")
        XCTAssertEqual(try FASTAIndex(url: write("signed numbers")).entry(for: "chr1")?.offset, -6)
        XCTAssertEqual(try FASTAIndex(url: write("CRLF with six fields")).sequenceNames, ["chr1"], "CR LF is one character, so the file is one line.")
        XCTAssertEqual(try FASTAIndex(url: write("UTF-8 names")).entry(for: "\u{E9}")?.offset, 50, "Canonically equal names are one name.")
        XCTAssertEqual(try FASTAIndex(url: write("spaces in a name")).sequenceNames, ["chr1 some words", " chr2 "], "Spaces stay in the name.")
        XCTAssertEqual(try FASTAIndex(url: write("CRLF inside a name")).sequenceNames, ["chr\r\n1"], "CR LF is one character, so it does not end the line.")

        let invalid: [(label: String, message: String)] = [
            ("CRLF with five fields", "Line 1: invalid numeric values"),
            ("overflow", "Line 1: invalid numeric values"),
            ("bad line after a blank line", "Line 2: expected 5 tab-separated fields"),
            ("tabs only", "Line 1: expected 5 tab-separated fields"),
            ("trailing CR without a line feed", "Line 1: invalid numeric values"),
            ("CRLF on the last line only", "Line 2: invalid numeric values"),
            ("only a CRLF", "Line 1: expected 5 tab-separated fields"),
        ]
        for (label, message) in invalid {
            XCTAssertThrowsError(try FASTAIndex(url: write(label)), label) { error in
                guard case FASTAError.invalidIndex(let actual) = error else {
                    return XCTFail("\(label) throws invalidIndex, not \(error)")
                }
                XCTAssertEqual(actual, message, label)
            }
        }
    }
}
