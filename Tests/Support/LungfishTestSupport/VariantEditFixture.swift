// VariantEditFixture.swift - The fixture and the dumps the variant edit pins, leaf tests and parity tests read
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import SQLite3

/// One bundle with a single variant database of three variants and two samples, the shape the
/// drawer's three stored edits change (Phase 2.10 lane A43, family L1). The pins of the services
/// (LungfishOperationsTests), the leaf tests (LungfishCLITests) and the route parity tests
/// (LungfishAppTests) build the same bundle, so this lives in the support target all three link.
public struct VariantEditFixture {
    public let root: URL
    public let bundleURL: URL
    public let databaseURL: URL
    /// The VCF the database was made from, beside the bundle.
    public let vcfURL: URL

    /// The track ID and name the manifest gives the database when it lists it.
    public static let trackID = "trackA"
    public static let trackName = "Variants"

    /// - Parameter withTrackManifest: When true the bundle's manifest lists the database as variant
    ///   track `trackA`, named `Variants`, so a command that resolves its targets from the manifest
    ///   finds it. When false the manifest holds `{}`, as the pins of the services were recorded.
    public static func make(
        in parent: URL, named name: String = "reference", withTrackManifest: Bool = false
    ) throws -> VariantEditFixture {
        let bundleURL = parent.appendingPathComponent("\(name).lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
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
        if withTrackManifest {
            let manifest = BundleManifest(
                name: name,
                identifier: "org.lungfish.test.variant-edit",
                source: SourceInfo(organism: "Test", assembly: name),
                variants: [VariantTrackInfo(
                    id: trackID, name: trackName, path: "variants.db", indexPath: "variants.db",
                    databasePath: "variants.db", variantType: .snp, variantCount: 3
                )]
            )
            try manifest.save(to: bundleURL)
        } else {
            try "{}".write(
                to: bundleURL.appendingPathComponent(BundleManifest.filename), atomically: true, encoding: .utf8
            )
        }
        return VariantEditFixture(root: parent, bundleURL: bundleURL, databaseURL: databaseURL, vcfURL: vcfURL)
    }

    /// The row IDs of the three variants, in ascending order.
    public func variantIDs() throws -> [Int64] {
        try VariantDatabase(url: databaseURL).queryForTable().compactMap(\.id).sorted()
    }

    /// A metadata file of two samples beside the bundle.
    public func writeMetadata(named name: String = "metadata.tsv") throws -> URL {
        let url = root.appendingPathComponent(name)
        try "sample_name\tcohort\tanimal\nSAMPLE_A\ttreated\tmacaque\nSAMPLE_B\tcontrol\tmacaque\n"
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A metadata file of two samples and one column, for a comparison of two runs. A second column
    /// writes the keys of `samples.metadata` in a different order from run to run.
    public func writeOneColumnMetadata(named name: String = "one-column.tsv") throws -> URL {
        let url = root.appendingPathComponent(name)
        try "sample_name\tcohort\nSAMPLE_A\ttreated\nSAMPLE_B\tcontrol\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The same fixture in `newRoot`, once `root` has been copied there (`FileManager.copyItem`).
    public func rebased(onto newRoot: URL) -> VariantEditFixture {
        func moved(_ url: URL) -> URL {
            URL(fileURLWithPath: newRoot.path + String(url.path.dropFirst(root.path.count)), isDirectory: url.hasDirectoryPath)
        }
        return VariantEditFixture(root: newRoot, bundleURL: moved(bundleURL), databaseURL: moved(databaseURL), vcfURL: moved(vcfURL))
    }

    /// A second database in the bundle with the same three variants, for an edit of two targets.
    public func addDatabase(named fileName: String) throws -> URL {
        let url = bundleURL.appendingPathComponent(fileName)
        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL, outputURL: url, parseGenotypes: true, sourceFile: "reference.vcf", progressHandler: nil
        )
        return url
    }
}

/// What a variant edit leaves in a bundle, as text a pin compares. Rows are sorted and nothing
/// that a run cannot repeat is kept (clocks, checksums, sizes, run IDs, the app's version, the
/// host's identity and the root's path).
public enum VariantEditDump {
    /// Each table's name and its sorted rows (not SQLite bytes and not the schema).
    public static func rows(of databaseURL: URL) throws -> String {
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
    public static func provenance(of bundleURL: URL, root: URL) throws -> String {
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

    /// What a cancelled or refused edit must leave as it found it. The sorted rows of each database
    /// stand for it, since a database's bytes can move when it is opened and restored, then every
    /// other file of the bundle by its path and bytes.
    public static func snapshot(ofBundleAt bundleURL: URL, databases: [URL]) throws -> String {
        var lines = try databases.map { try rows(of: $0) }
        let base = bundleURL.resolvingSymlinksInPath().path + "/"
        let enumerator = FileManager.default.enumerator(at: bundleURL, includingPropertiesForKeys: [.isRegularFileKey])
        var files: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let name = String(url.resolvingSymlinksInPath().path.dropFirst(base.count))
            files.append(url.pathExtension == "db" ? name : "\(name) \(try Data(contentsOf: url).base64EncodedString())")
        }
        lines += files.sorted()
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
