// EsVirituDatabaseTaxonomy.swift - The NCBI tax ID EsViritu's database files an accession under
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The NCBI tax ID EsViritu's database files an accession under, from its local
/// `virus_pathogen_database.all_metadata.tsv`.
///
/// EsViritu's result tables keep no tax IDs, but its database table does, for every accession. A row's name can be adjusted
/// while its accession stays the reference's (`[tax adj: …]`), so the species must agree before the ID stands for the row.
/// This type only reads the file, and a missing file or a table of another shape is nil, never an error.
public enum EsVirituDatabaseTaxonomy {

    /// The file inside the database's versioned folder.
    public static let tableFileName = "virus_pathogen_database.all_metadata.tsv"

    /// The tax ID of `accession`, or nil when the table is missing, lacks the accession or a needed column, or files the
    /// accession under another species than `species`. The species compares as the result table's parser reads a cell, so
    /// the raw text with its prefix, `s__Rhinovirus B`, and a row with no species matches only a table row with none.
    public static func taxId(accession: String, species: String?, databaseDirectory: URL) -> Int? {
        guard let table = try? Data(contentsOf: databaseDirectory.appendingPathComponent(tableFileName), options: .mappedIfSafe),
              let (header, row) = cells(ofAccession: accession, in: table),
              let speciesColumn = header.firstIndex(of: "species"), speciesColumn < row.count,
              let taxIdColumn = header.firstIndex(of: "TaxID"), taxIdColumn < row.count,
              EsVirituDetectionParser.optionalString(row[speciesColumn]) == species,
              let taxId = Int(row[taxIdColumn].trimmingCharacters(in: .whitespaces)), taxId > 0
        else { return nil }
        return taxId
    }

    /// The header's cells and the cells of the row that holds `accession`. It compares each row's accession cell in place
    /// and decodes only the row it keeps, because the table holds about 31,000 rows.
    private static func cells(ofAccession accession: String, in table: Data) -> (header: [String], row: [String])? {
        let wanted = Array(accession.utf8)
        guard !wanted.isEmpty else { return nil }
        return table.withUnsafeBytes { raw -> (header: [String], row: [String])? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let lineEnd = { (start: Int) -> Int in
                memchr(base + start, 0x0A, raw.count - start)
                    .map { base.distance(to: UnsafePointer($0.assumingMemoryBound(to: UInt8.self))) } ?? raw.count
            }
            let splitCells = { (start: Int, end: Int) -> [String] in
                String(decoding: UnsafeBufferPointer(start: base + start, count: end - start), as: UTF8.self)
                    .trimmingCharacters(in: .newlines)
                    .split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            }
            let headerEnd = lineEnd(0)
            let header = splitCells(0, headerEnd)
            guard let column = header.firstIndex(of: "Accession") else { return nil }

            var start = headerEnd + 1
            while start < raw.count {
                let end = lineEnd(start)
                var cell = start
                var index = 0
                while index < column, let tab = memchr(base + cell, 0x09, end - cell) {
                    cell = base.distance(to: UnsafePointer(tab.assumingMemoryBound(to: UInt8.self))) + 1
                    index += 1
                }
                if index == column, cell + wanted.count < end,
                   base[cell + wanted.count] == 0x09,
                   memcmp(base + cell, wanted, wanted.count) == 0 {
                    return (header, splitCells(start, end))
                }
                start = end + 1
            }
            return nil
        }
    }
}
