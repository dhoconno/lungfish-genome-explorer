// VariantEditPinSupport.swift - The fixture and the dumps the variant edit pins and parity tests read
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow
import SQLite3
import XCTest

/// One bundle with a single variant database of three variants and two samples, the shape the
/// drawer's three stored edits change (Phase 2.10 lane A43, family L1).
struct VariantEditFixture {
    let root: URL
    let bundleURL: URL
    let databaseURL: URL

    static func make(in parent: URL, named name: String = "reference") throws -> VariantEditFixture {
        let bundleURL = parent.appendingPathComponent("\(name).lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try "{}".write(
            to: bundleURL.appendingPathComponent(BundleManifest.filename), atomically: true, encoding: .utf8
        )
        let vcfURL = parent.appendingPathComponent("\(name).vcf")
        try """
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tSAMPLE_A\tSAMPLE_B
        chr1\t100\t.\tA\tG\t50\tPASS\tDP=10\tGT\t0/1\t0/0
        chr1\t200\t.\tC\tT\t50\tPASS\tDP=12\tGT\t0/1\t1/1
        chr2\t300\t.\tG\tA\t40\tPASS\tDP=8\tGT\t0/0\t0/1
        """.write(to: vcfURL, atomically: true, encoding: .utf8)
        let databaseURL = bundleURL.appendingPathComponent("variants.db")
        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL, outputURL: databaseURL, parseGenotypes: true, sourceFile: "reference.vcf", progressHandler: nil
        )
        return VariantEditFixture(root: parent, bundleURL: bundleURL, databaseURL: databaseURL)
    }

    /// The row IDs of the three variants, in ascending order.
    func variantIDs() throws -> [Int64] {
        try VariantDatabase(url: databaseURL).queryForTable().compactMap(\.id).sorted()
    }

    /// A metadata file of two samples beside the bundle.
    func writeMetadata(named name: String = "metadata.tsv") throws -> URL {
        let url = root.appendingPathComponent(name)
        try "sample_name\tcohort\tanimal\nSAMPLE_A\ttreated\tmacaque\nSAMPLE_B\tcontrol\tmacaque\n"
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// What a variant edit leaves in a bundle, as text a pin compares. Rows are sorted and nothing
/// that a run cannot repeat is kept (clocks, checksums, sizes, run IDs, the app's version, the
/// host's identity and the root's path).
enum VariantEditDump {
    /// Each table's name and its sorted rows (not SQLite bytes and not the schema).
    static func rows(of databaseURL: URL) throws -> String {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw NSError(domain: "VariantEditDump", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot open \(databaseURL.path)"])
        }
        defer { sqlite3_close(database) }
        var lines: [String] = []
        let tables = try query(database, "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        for name in tables.map({ $0[0] }) {
            lines.append("table \(name)")
            let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            lines += try query(database, "SELECT * FROM \(quoted)").map { $0.joined(separator: "\t") }.sorted()
        }
        return lines.joined(separator: "\n")
    }

    /// The bundle's files by their path in the bundle, then the main provenance record as one
    /// line per value, with a sorted path to each.
    static func provenance(of bundleURL: URL, root: URL) throws -> String {
        var lines = ["files"]
        lines += try relativeFiles(under: bundleURL).map { maskedText($0, roots: []) }.sorted()
        let record = bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: record))
        var values: [String] = []
        flatten(json, path: "", into: &values, roots: roots(of: root))
        lines.append("record")
        lines += values.sorted()
        return lines.joined(separator: "\n")
    }

    private static let omittedKeys: Set<String> = [
        "checksumSHA256", "fileSize", "startedAt", "completedAt", "endedAt", "wallTimeSeconds", "createdAt", "id",
        "durableReplayArgv", "runtimeIdentity", "signatures",
    ]

    private static func roots(of root: URL) -> [String] {
        [root.resolvingSymlinksInPath().path, root.path].reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    private static func flatten(_ value: Any, path: String, into lines: inout [String], roots: [String]) {
        if let object = value as? [String: Any] {
            for key in object.keys.sorted() where !omittedKeys.contains(key) {
                let name = maskedText(key, roots: roots)
                flatten(object[key]!, path: path.isEmpty ? name : path + "." + name, into: &lines, roots: roots)
            }
        } else if let array = value as? [Any] {
            if array.isEmpty { lines.append("\(path) = []") }
            for (index, item) in array.enumerated() { flatten(item, path: "\(path)[\(index)]", into: &lines, roots: roots) }
        } else if let text = value as? String {
            lines.append("\(path) = \(maskedText(text, roots: roots))")
        } else {
            lines.append("\(path) = \(value)")
        }
    }

    /// The root's path becomes `<ROOT>`, a UUID `<UUID>` (`.mutation-inputs/<UUID>/` keeps one
    /// folder per edit) and the app's version and build `<version>`.
    private static func maskedText(_ text: String, roots: [String]) -> String {
        var masked = text
        for root in roots { masked = masked.replacingOccurrences(of: root, with: "<ROOT>") }
        masked = masked.replacingOccurrences(
            of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
            with: "<UUID>", options: .regularExpression
        )
        return masked.replacingOccurrences(
            of: "Lungfish [0-9][^ ]* \\([^)]*\\)", with: "Lungfish <version>", options: .regularExpression
        )
    }

    private static func relativeFiles(under bundleURL: URL) throws -> [String] {
        let base = bundleURL.resolvingSymlinksInPath().path + "/"
        var names: [String] = []
        let enumerator = FileManager.default.enumerator(at: bundleURL, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            names.append(String(url.resolvingSymlinksInPath().path.dropFirst(base.count)))
        }
        return names
    }

    private static func query(_ database: OpaquePointer?, _ sql: String) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "VariantEditDump", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_type(statement, column) == SQLITE_NULL
                    ? "NULL" : canonicalJSON(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "")
            })
        }
        return rows
    }

    /// A cell that holds a JSON object or array is written with sorted keys. The service encodes
    /// a sample's metadata from a dictionary, so the order of its keys differs from run to run.
    private static func canonicalJSON(_ text: String) -> String {
        guard text.hasPrefix("{") || text.hasPrefix("["),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return text }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Compares a dump with its pin, or records it when `LUNGFISH_RECORD_PINS_DIR` names a folder.
enum VariantEditPins {
    static func assertPin(
        _ name: String, actual: String, expected: [String: String] = VariantEditPinExpectations.all,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        if let folder = ProcessInfo.processInfo.environment["LUNGFISH_RECORD_PINS_DIR"], !folder.isEmpty {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try actual.write(toFile: folder + "/" + name + ".txt", atomically: true, encoding: .utf8)
            return
        }
        XCTAssertEqual(actual, expected[name], "The pin \(name) moved", file: file, line: line)
    }
}
