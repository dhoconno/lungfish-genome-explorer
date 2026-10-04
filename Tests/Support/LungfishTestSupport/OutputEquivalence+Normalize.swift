// OutputEquivalence+Normalize.swift - Turns one output file into the text a comparison reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import SQLite3

extension OutputEquivalence {
    public enum NormalizeError: Error, CustomStringConvertible {
        case toolFailed(tool: String, status: Int32, stderr: String)
        case samtoolsNotFound
        case sqlite(path: String, message: String)

        public var description: String {
            switch self {
            case .toolFailed(let tool, let status, let stderr):
                return "\(tool) exited \(status): \(stderr)"
            case .samtoolsNotFound:
                return "Comparing a BAM needs samtools, and none was found."
            case .sqlite(let path, let message):
                return "SQLite could not read \(path): \(message)"
            }
        }
    }

    /// The comparable form of `url` for `kind`, with the masks its role gets.
    static func normalized(_ url: URL, kind: Kind, masks: MaskPolicy, context: MaskContext) throws -> String {
        switch kind {
        case .files:
            return try normalizedPayload(url, masks: masks, context: context, dumpDatabases: false)
        case .database:
            return applying(masks.records, to: try sqliteDump(url), context: context)
        case .bundle:
            return try normalizedPayload(url, masks: masks, context: context, dumpDatabases: true)
        case .remoteRequest:
            return try normalizedRequest(url, masks: masks.payloads, context: context)
        case .managedPlan:
            let text = applying(masks.payloads, to: try String(contentsOf: url, encoding: .utf8), context: context)
            return canonicalJSON(text) ?? text
        }
    }

    /// A file compared under its own extension.
    static func normalizedPayload(_ url: URL, masks: MaskPolicy, context: MaskContext, dumpDatabases: Bool) throws -> String {
        let data = try Data(contentsOf: url)
        var name = url.lastPathComponent.lowercased()
        var bytes = data
        if isGzip(data) {
            bytes = try run("/usr/bin/gzip", ["-dc", url.path]).stdout
            for suffix in [".gz", ".bgz", ".bgzf"] where name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
            }
        }
        if name.hasSuffix(".bam") {
            return try normalizedBAM(url, masks: masks.payloads, context: context)
        }
        if indexExtensions.contains(where: name.hasSuffix) {
            return try normalizedIndex(url, masks: masks.payloads, context: context)
        }
        if dumpDatabases, isSQLite(bytes) {
            return applying(masks.records, to: try sqliteDump(url), context: context)
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            return "binary sha256 " + sha256(bytes)
        }
        var lines = text
        if name.hasSuffix(".vcf") {
            lines = text
                .components(separatedBy: "\n")
                .filter { !isVolatileVCFHeaderLine($0) }
                .joined(separator: "\n")
        }
        let masked = applying(masks.masks(for: role(ofFileNamed: name)), to: lines, context: context)
        if name.hasSuffix(".json") {
            return canonicalJSON(masked) ?? masked
        }
        return masked
    }

    /// Binary indexes compared through the file they index.
    static let indexExtensions = [".bai", ".csi", ".tbi", ".crai"]

    /// An index records the byte offsets of the file it indexes, which a
    /// header line changes, so it is never compared byte for byte. A BAM
    /// index is compared through `samtools idxstats` and a tabix index through
    /// `tabix -l`. When the tool or the indexed file is missing, the index is
    /// compared on its presence alone.
    static func normalizedIndex(_ url: URL, masks: [Mask], context: MaskContext) throws -> String {
        let name = url.lastPathComponent.lowercased()
        let stripped = url.deletingPathExtension()
        let fileManager = FileManager.default
        var bamCandidates = [stripped]
        if name.hasSuffix(".bai") || name.hasSuffix(".csi") {
            bamCandidates.append(stripped.appendingPathExtension("bam"))
        }
        if let bam = bamCandidates.first(where: { $0.pathExtension.lowercased() == "bam" && fileManager.fileExists(atPath: $0.path) }) {
            guard let samtools = BamFixtureBuilder.locateSamtools() else { return "index present" }
            let stats = try run(samtools, ["idxstats", bam.path]).stdout
            return "idxstats\n" + applying(masks, to: String(decoding: stats, as: UTF8.self), context: context)
        }
        if (name.hasSuffix(".tbi") || name.hasSuffix(".csi")), fileManager.fileExists(atPath: stripped.path) {
            guard let tabix = locateTool("tabix") else { return "index present" }
            let sequences = try run(tabix, ["-l", stripped.path]).stdout
            return "tabix -l\n" + String(decoding: sequences, as: UTF8.self)
        }
        return "index present"
    }

    /// An executable named `name` on PATH or in the usual Homebrew folders.
    static func locateTool(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let folders = path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        return folders
            .map { $0 + "/" + name }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// A VCF header line that records when or how the file was written.
    static func isVolatileVCFHeaderLine(_ line: String) -> Bool {
        guard line.hasPrefix("##") else { return false }
        let key = line.dropFirst(2).prefix { $0 != "=" }.lowercased()
        return key == "filedate" || key.contains("command")
    }

    /// The header without `@PG` lines and a hash of the records in file order.
    static func normalizedBAM(_ url: URL, masks: [Mask], context: MaskContext) throws -> String {
        guard let samtools = BamFixtureBuilder.locateSamtools() else { throw NormalizeError.samtoolsNotFound }
        let header = try run(samtools, ["view", "-H", "--no-PG", url.path]).stdout
        let records = try run(samtools, ["view", "--no-PG", url.path]).stdout
        let headerText = (String(data: header, encoding: .utf8) ?? "")
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("@PG") }
            .joined(separator: "\n")
        return applying(masks, to: headerText, context: context) + "\nrecords sha256 " + sha256(records)
    }

    /// A request body and its parameters. JSON is compared with sorted keys.
    /// A form or query body is compared as a sorted set of `key=value` pairs.
    /// Every parameter is compared as written, so `masks` is the roots mask
    /// alone unless a caller says otherwise.
    static func normalizedRequest(_ url: URL, masks: [Mask], context: MaskContext) throws -> String {
        let text = applying(masks, to: try String(contentsOf: url, encoding: .utf8), context: context)
        if let json = canonicalJSON(text) { return json }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("="), !trimmed.contains("\n"), !trimmed.contains(" ") {
            return trimmed.split(separator: "&").map(String.init).sorted().joined(separator: "\n")
        }
        return text
    }

    /// `text` re-encoded with sorted keys, or nil when it is not JSON.
    static func canonicalJSON(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let encoded = try? JSONSerialization.data(
                  withJSONObject: value,
                  options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed, .withoutEscapingSlashes]
              )
        else { return nil }
        return String(data: encoded, encoding: .utf8)
    }

    // MARK: - SQLite

    /// Each table's schema and its rows, sorted, for every table in the file.
    /// A directory dumps every SQLite file inside it, in path order.
    static func sqliteDump(_ url: URL) throws -> String {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(database)
            throw NormalizeError.sqlite(path: url.path, message: message)
        }
        defer { sqlite3_close(database) }
        let tables = try query(
            database,
            "SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
            path: url.path
        )
        var dump: [String] = []
        for table in tables {
            let name = table[0]
            dump.append("table \(name)")
            dump.append(table[1])
            let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let rows = try query(database, "SELECT * FROM \(quoted)", path: url.path)
            dump.append(contentsOf: rows.map { $0.joined(separator: "\t") }.sorted())
        }
        return dump.joined(separator: "\n")
    }

    private static func query(_ database: OpaquePointer?, _ sql: String, path: String) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NormalizeError.sqlite(path: path, message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw NormalizeError.sqlite(path: path, message: String(cString: sqlite3_errmsg(database)))
            }
            var row: [String] = []
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_NULL:
                    row.append("NULL")
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    let bytes = sqlite3_column_blob(statement, column).map { Data(bytes: $0, count: count) } ?? Data()
                    row.append("blob " + sha256(bytes))
                default:
                    row.append(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "")
                }
            }
            rows.append(row)
        }
        return rows
    }

    // MARK: - Bytes and tools

    static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    static func isSQLite(_ data: Data) -> Bool {
        data.starts(with: Data("SQLite format 3\u{0}".utf8))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Runs `executable` and returns its standard output. Standard error goes
    /// to a file, so a chatty tool cannot fill a pipe and stall.
    static func run(_ executable: String, _ arguments: [String]) throws -> (stdout: Data, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let errorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("output-equivalence-\(UUID().uuidString).stderr")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errorURL) }
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer { try? errorHandle.close() }
        process.standardOutput = output
        process.standardError = errorHandle
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
            throw NormalizeError.toolFailed(
                tool: URL(fileURLWithPath: executable).lastPathComponent,
                status: process.terminationStatus,
                stderr: stderr
            )
        }
        return (data, process.terminationStatus)
    }
}
