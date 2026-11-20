// RNASeqCellMapImport+TenX.swift - The given files of rnaseq cell-map import, read once and known by their first line (Phase 5.5 lane CM-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Each given file is opened once. Its bytes are hashed and parsed from the one read, and a gzip file is inflated from
// those bytes by `gzip -dc` on ToolProcess, so the file that is checked is the file whose sha256 the record names. The
// first line tells LGE's table from 10x's `projection.csv` and `clusters.csv` (`docs/formats/rnaseq-cell-map.md`, The
// inputs), and the columns of each form are read here.

import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

extension RNASeqCellMapImport {
    /// The form of a given file, known by its first line.
    public enum Form: String, Sendable {
        case lgeTable = "LGE's table"
        case projection = "a 10x projection"
        case clusters = "10x clusters"

        var isTenX: Bool { self != .lgeTable }
    }

    /// A given file after its first line: its bytes' digest, its data lines and where each column goes.
    struct Table {
        var place: Int
        var url: URL
        var file: String
        var form: Form
        var sha256: String
        var size: Int64
        var separator: Character
        var header: [String]
        /// Every line after the first, each with its line number from 1, empty lines left out.
        var lines: [(number: Int, text: Substring)]
        var barcodeAt: Int
        var sampleAt: Int?
        /// Each embedding of the file in column order, with its columns in dimension order.
        var embeddings: [(name: String, columns: [Int])]
        var labelSets: [(name: String, column: Int)]
        var readPast: [String]
    }

    /// The bytes of `url`, read once, with their sha256 and size, inflated when they start with gzip's magic bytes, and
    /// decoded as UTF-8.
    static func read(_ url: URL) throws -> (text: String, sha256: String, size: Int64) {
        let file = url.lastPathComponent
        let raw: Data
        do {
            raw = try Data(contentsOf: url)
        } catch {
            throw RNASeqCellMapImportRefusal.unreadable(file: file, reason: (error as NSError).localizedDescription)
        }
        let sha256 = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        var bytes = raw
        if raw.starts(with: [0x1f, 0x8b]) {
            let spec = ToolProcessSpec(executableURL: URL(fileURLWithPath: "/usr/bin/gzip"), arguments: ["-dc"],
                                       environment: ToolProcessSpec.inheritedEnvironment(), stdin: .data(raw),
                                       stdout: .capture(limit: nil), label: "gzip")
            let result: ToolProcessResult
            do throws(ToolProcessError) {
                result = try ToolProcess.runBlocking(spec)
            } catch {
                throw RNASeqCellMapImportRefusal.unreadable(file: file, reason: "gzip could not start, \(error.localizedDescription)")
            }
            guard result.isSuccess else {
                let said = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                let reason = said.isEmpty ? "gzip exited with code \(result.status)" : said.replacingOccurrences(of: "gzip: stdin: ", with: "gzip says ")
                throw RNASeqCellMapImportRefusal.unreadable(file: file, reason: reason)
            }
            bytes = result.stdout
        }
        guard var text = String(data: bytes, encoding: .utf8) else {
            throw RNASeqCellMapImportRefusal.unreadable(file: file, reason: "its bytes are not UTF-8")
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return (text, sha256, Int64(raw.count))
    }

    /// Reads the file at command-line place `place` and checks its first line and columns.
    static func table(place: Int, url: URL, labelColumns: [String], samples: Int) throws -> Table {
        let file = url.lastPathComponent
        let (text, sha256, size) = try read(url)
        var all = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
        if all.last?.isEmpty == true { all.removeLast() }
        let first = all.first.map(String.init) ?? ""
        let lines = all.enumerated().dropFirst().filter { !$0.element.isEmpty }.map { (number: $0.offset + 1, text: $0.element) }
        var table = Table(place: place, url: url, file: file, form: .lgeTable, sha256: sha256, size: size, separator: "\t", header: [],
                          lines: lines, barcodeAt: 0, sampleAt: nil, embeddings: [], labelSets: [], readPast: [])
        if first.contains("\t") || first == "barcode" {
            table.header = first.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let barcodeAt = table.header.firstIndex(of: "barcode") else { throw RNASeqCellMapImportRefusal.unknownForm(file: file) }
            table.barcodeAt = barcodeAt
        } else if first.hasPrefix("Barcode,") {
            table.separator = ","
            table.header = first.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            table.form = table.header == ["Barcode", "Cluster"] ? .clusters : .projection
        } else {
            throw RNASeqCellMapImportRefusal.unknownForm(file: file)
        }
        var seen = Set<String>()
        for column in table.header where !seen.insert(column).inserted {
            throw RNASeqCellMapImportRefusal.columnTwice(file: file, column: column)
        }
        switch table.form {
        case .clusters:
            table.labelSets = [(url.deletingLastPathComponent().lastPathComponent, 1)]
        case .projection:
            table.embeddings = try embeddings(of: table.header, from: 1, file: file, joiner: "-", unknown: true)
        case .lgeTable:
            table.sampleAt = table.header.firstIndex(of: "sample")
            table.labelSets = labelColumns.compactMap { name in table.header.firstIndex(of: name).map { (name, $0) } }
            table.embeddings = try embeddings(of: table.header, from: 0, file: file, joiner: "_", unknown: false,
                                              skip: Set([table.barcodeAt] + (table.sampleAt.map { [$0] } ?? []) + table.labelSets.map(\.column)))
            let used = Set(table.embeddings.flatMap(\.columns) + table.labelSets.map(\.column) + [table.barcodeAt] + (table.sampleAt.map { [$0] } ?? []))
            table.readPast = table.header.indices.filter { !used.contains($0) }.map { table.header[$0] }
        }
        if table.form.isTenX, samples >= 2 { throw RNASeqCellMapImportRefusal.tenXManySamples(file: file, samples: samples) }
        if table.form == .lgeTable, table.sampleAt == nil, samples >= 2 {
            throw RNASeqPseudobulkRefusal.noSampleColumn(file: file, samples: samples)
        }
        return table
    }

    /// The embeddings that the columns of `header` from `from` name as `<embedding><joiner><n>`, in the order of their
    /// first column, each checked for 2 or more dimensions numbered from 1 with no gap. A 10x projection names one
    /// prefix in every column, so another column makes it a file of no known form.
    static func embeddings(of header: [String], from: Int, file: String, joiner: Character, unknown: Bool, skip: Set<Int> = []
    ) throws -> [(name: String, columns: [Int])] {
        var order: [String] = []
        var numbered: [String: [(number: Int, column: Int)]] = [:]
        for column in header.indices where column >= from && !skip.contains(column) {
            let text = header[column]
            guard let cut = text.lastIndex(of: joiner), cut > text.startIndex else {
                if unknown { throw RNASeqCellMapImportRefusal.unknownForm(file: file) }
                continue
            }
            let digits = text[text.index(after: cut)...]
            guard let first = digits.first, first != "0", digits.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(digits) else {
                if unknown { throw RNASeqCellMapImportRefusal.unknownForm(file: file) }
                continue
            }
            let name = String(text[..<cut])
            if numbered[name] == nil { order.append(name) }
            numbered[name, default: []].append((number, column))
        }
        if unknown, order.count != 1 { throw RNASeqCellMapImportRefusal.unknownForm(file: file) }
        return try order.map { name in
            let columns = (numbered[name] ?? []).sorted { $0.number < $1.number }
            for (index, entry) in columns.enumerated() where entry.number != index + 1 {
                throw RNASeqCellMapImportRefusal.gap(file: file, name: name, present: entry.number, missing: index + 1, joiner: joiner)
            }
            guard columns.count >= 2 else {
                throw RNASeqCellMapImportRefusal.oneDimension(file: file, name: name, column: header[columns[0].column], joiner: joiner)
            }
            return (name, columns.map(\.column))
        }
    }

    /// One file's lines after the check: the parent's cell of each held line in file order, each embedding's values and
    /// each label set's labels in the same order, and for each sample the counts of the suffix rule and of the barcodes
    /// not held.
    struct Parsed {
        var cells: [Int32] = []
        var values: [[Double]]
        var labels: [[String]]
        var given: [Int]
        var matched: [Int]
        var wouldDrop: [Int]
        var wouldAdd: [Int]
        var notHeld: [Int]
        var firstNotHeld: [[String]]
        var firstNotHeldAll: [String] = []
    }

    /// Checks each line of `table` in order and matches its (sample, barcode) through the shared matcher (5.5 I1).
    static func parse(_ table: Table, samples: [RNASeqPseudobulk.SampleCells], firstCell: [Int], suffix: BarcodeSuffix?) throws -> Parsed {
        let zeros = [Int](repeating: 0, count: samples.count)
        var parsed = Parsed(values: table.embeddings.map { _ in [] }, labels: table.labelSets.map { _ in [] }, given: zeros, matched: zeros,
                            wouldDrop: zeros, wouldAdd: zeros, notHeld: zeros, firstNotHeld: samples.map { _ in [] })
        var matcher = RNASeqCellMatcher(samples: samples)
        let file = table.file
        for line in table.lines {
            try Task.checkCancellation()
            if table.form.isTenX, line.text.contains("\"") { throw RNASeqCellMapImportRefusal.quote(file: file, line: line.number) }
            let fields = line.text.split(separator: table.separator, omittingEmptySubsequences: false)
            guard fields.count == table.header.count else {
                throw RNASeqPseudobulkRefusal.lineCells(file: file, line: line.number, cells: fields.count, header: table.header.count)
            }
            let sample = try table.sampleAt.map { try matcher.sample(String(fields[$0]), file: file, line: line.number) } ?? 0
            let given = String(fields[table.barcodeAt])
            let barcode = suffix?.apply(given) ?? given
            var row: [Double] = []
            for embedding in table.embeddings {
                for column in embedding.columns {
                    guard let value = finiteDecimal(fields[column]) else {
                        throw RNASeqCellMapImportRefusal.notFinite(file: file, line: line.number, text: String(fields[column]), column: table.header[column])
                    }
                    row.append(value)
                }
            }
            if table.form == .clusters, fields[1].isEmpty { throw RNASeqPseudobulkRefusal.emptyLabel(file: file, line: line.number) }
            let column = try matcher.claim(sample: sample, barcode: barcode, file: file, line: line.number, given: given, changed: suffix?.changed)
            parsed.given[sample] += 1
            guard let column else {
                if suffix == nil {
                    let held = samples[sample].columnOfBarcode
                    if given.hasSuffix("-1"), held[String(given.dropLast(2))] != nil { parsed.wouldDrop[sample] += 1 }
                    if held[given + "-1"] != nil { parsed.wouldAdd[sample] += 1 }
                }
                parsed.notHeld[sample] += 1
                let shown = table.sampleAt == nil ? given : "\(given) of \(samples[sample].name)"
                if parsed.firstNotHeld[sample].count < 10 { parsed.firstNotHeld[sample].append(given) }
                if parsed.firstNotHeldAll.count < 10 { parsed.firstNotHeldAll.append(shown) }
                continue
            }
            parsed.matched[sample] += 1
            parsed.cells.append(Int32(firstCell[sample] + column - 1))
            var offset = 0
            for (index, embedding) in table.embeddings.enumerated() {
                parsed.values[index] += row[offset..<(offset + embedding.columns.count)]
                offset += embedding.columns.count
            }
            for (index, set) in table.labelSets.enumerated() { parsed.labels[index].append(String(fields[set.column])) }
        }
        return parsed
    }

    /// A finite decimal number, an optional sign, digits with an optional fraction and an optional exponent, whose
    /// Double is finite. `nan`, `inf`, an empty cell, `1,5` and hexadecimal are not.
    static func finiteDecimal(_ text: Substring) -> Double? {
        var bytes = text.utf8[...]
        if let sign = bytes.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") { bytes = bytes.dropFirst() }
        func digits() -> Int {
            let count = bytes.prefix { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }.count
            bytes = bytes.dropFirst(count)
            return count
        }
        var mantissa = digits()
        if bytes.first == UInt8(ascii: ".") {
            bytes = bytes.dropFirst()
            mantissa += digits()
        }
        guard mantissa > 0 else { return nil }
        if let e = bytes.first, e == UInt8(ascii: "e") || e == UInt8(ascii: "E") {
            bytes = bytes.dropFirst()
            if let sign = bytes.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") { bytes = bytes.dropFirst() }
            guard digits() > 0 else { return nil }
        }
        guard bytes.isEmpty, let value = Double(text), value.isFinite else { return nil }
        return value
    }
}
