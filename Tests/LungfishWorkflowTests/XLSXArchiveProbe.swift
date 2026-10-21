import CryptoKit
import Foundation
import XCTest
@testable import LungfishWorkflow

/// What lane 13.50's tests read from an XLSX archive. `/usr/bin/unzip -Z` is `zipinfo`, so one tool lists the entries
/// with their times and flags and prints each part.
enum XLSXArchiveProbe {
    /// An entry as `unzip -Z -T -l` lists it, for example `-rw-r--r--  3.0 unx 315 t- 18 defN 19800101.000000 xl/styles.xml`.
    struct Entry: Equatable {
        let mode: String
        /// Text or binary, then `-` for no extra field and no extended local header, `x` for an extra field.
        let flags: String
        /// The DOS time as `yyyymmdd.hhmmss`.
        let time: String
        let name: String
    }

    /// The six files the writer makes, which are the parts of the workbook.
    static let partNames = [
        "[Content_Types].xml", "_rels/.rels", "xl/_rels/workbook.xml.rels", "xl/styles.xml", "xl/workbook.xml",
        "xl/worksheets/sheet1.xml",
    ]

    /// The four folders of those parts, which `zip -r .` stores as entries of their own.
    static let folderNames = ["_rels/", "xl/", "xl/_rels/", "xl/worksheets/"]

    /// The table of the lane's tests, which is the fixture of `ScientificTableWriterTests` (text identifiers, formula text,
    /// integers, numbers, a boolean, an empty cell and a CRLF).
    static let table = ScientificTableData(
        name: "Variants",
        columns: [
            .init(id: "gene", title: "Gene"),
            .init(id: "position", title: "Position (1-based)"),
            .init(id: "frequency", title: "AF"),
            .init(id: "missing", title: "Missing"),
        ],
        rows: [
            [.text("SEPT1"), .integer(29_409), .number(0.999628), .empty],
            [.text("00123"), .text("9007199254740993"), .text("=1+1"), .text("1|0")],
            [.text("a,\"b\"\r\nc"), .integer(-7), .number(-0.25), .boolean(true)],
        ]
    )

    /// Exports `table` as an XLSX file named `name` in `directory`.
    static func export(
        _ name: String, in directory: URL, table: ScientificTableData = XLSXArchiveProbe.table
    ) throws -> (url: URL, report: ScientificTableWriteReport) {
        let url = directory.appendingPathComponent(name)
        let report = try ScientificTableWriter.writeWithReport(table, format: .xlsx, to: url)
        return (url, report)
    }

    static func output(of executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(executable) \(arguments)")
        return data
    }

    /// The entries in the order the archive stores them.
    static func entries(of archive: URL) throws -> [Entry] {
        let text = String(decoding: try output(of: "/usr/bin/unzip", ["-Z", "-T", "-l", archive.path]), as: UTF8.self)
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard fields.count == 9, fields[2] == "unx" else { return nil }
            return Entry(mode: String(fields[0]), flags: String(fields[4]), time: String(fields[7]), name: String(fields[8]))
        }
    }

    /// The SHA-256 of each part, read with `unzip -p`.
    static func partDigests(of archive: URL) throws -> [String: String] {
        var digests: [String: String] = [:]
        for name in partNames {
            // unzip reads a name as a pattern, so a bracket is matched as itself with `[[]`.
            let pattern = name.replacingOccurrences(of: "[", with: "[[]")
            let data = try output(of: "/usr/bin/unzip", ["-p", archive.path, pattern])
            digests[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return digests
    }
}
