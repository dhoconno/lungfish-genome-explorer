// RNASeqSampleSheet.swift - The sample sheet of an import of bulk counts (Phase 5.1 lane RS-BULK-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A tab-separated sheet with a `sample` column (or `sample_id`) and, when known, `run`, `animal`, `species`, `origin`
// and `group` (`docs/plans/2026-10-02-architecture-program.md:111,134`). A salmon folder is matched by its row's `run`,
// else by `sample`, and a table's column by `sample`. Ids that differ between the files and the sheet are refused in
// words that list both sides. A field the sheet leaves empty, or an import with no sheet, reads Not recorded.

import Foundation
import LungfishIO

public struct RNASeqSampleSheet: Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        public var sample: String
        public var run: String?
        public var animal: String?
        public var species: String?
        public var origin: String?
        public var group: String?

        public init(sample: String, run: String? = nil, animal: String? = nil, species: String? = nil, origin: String? = nil, group: String? = nil) {
            self.sample = sample
            self.run = run
            self.animal = animal
            self.species = species
            self.origin = origin
            self.group = group
        }
    }

    /// The sheet against the files.
    public struct Match: Sendable, Equatable {
        /// The sample id of each file id, in the order of the file ids.
        public var sampleIDs: [String]
        /// One record a sample, in the sheet's order, or in the files' order with no sheet.
        public var records: [RNASeqSampleRecord]
    }

    public var rows: [Row]

    public init(rows: [Row]) {
        self.rows = rows
    }

    public static func read(_ url: URL) throws -> RNASeqSampleSheet {
        let name = url.lastPathComponent
        let lines = try SalmonQuantFolderReader.tsvRows(Data(contentsOf: url), path: name)
            .map { $0.map { $0.trimmingCharacters(in: .whitespaces) } }
        guard let header = lines.first else {
            throw RNASeqImportError.invalidFile(path: name, reason: "it has no header line")
        }
        guard let sampleColumn = header.firstIndex(of: "sample") ?? header.firstIndex(of: "sample_id") else {
            throw RNASeqImportError.invalidFile(path: name, reason: "its first line names no sample column")
        }
        func cell(_ row: [String], _ column: String) -> String? {
            guard let index = header.firstIndex(of: column), index < row.count, !row[index].isEmpty else { return nil }
            return row[index]
        }
        let rows = try lines.dropFirst().enumerated().map { index, row -> Row in
            guard sampleColumn < row.count, !row[sampleColumn].isEmpty else {
                throw RNASeqImportError.invalidFile(path: name, reason: "line \(index + 2) names no sample")
            }
            return Row(
                sample: row[sampleColumn], run: cell(row, "run"), animal: cell(row, "animal"), species: cell(row, "species"),
                origin: cell(row, "origin"), group: cell(row, "group"))
        }
        return RNASeqSampleSheet(rows: rows)
    }

    /// Matches `fileIDs`, the folder names or the table's columns, to `sheet`. With `byRun` a row's `run` names its
    /// folder when the row has one. With no sheet each file id is a sample whose other fields read Not recorded.
    public static func match(_ sheet: RNASeqSampleSheet?, fileIDs: [String], byRun: Bool) throws -> Match {
        var files = Set<String>()
        if let repeated = fileIDs.first(where: { !files.insert($0).inserted }) {
            throw RNASeqImportError.duplicateSample(repeated)
        }
        guard let sheet else {
            return Match(sampleIDs: fileIDs, records: fileIDs.map { RNASeqSampleRecord(id: $0) })
        }
        var samples = Set<String>()
        if let repeated = sheet.rows.first(where: { !samples.insert($0.sample).inserted }) {
            throw RNASeqImportError.duplicateSample(repeated.sample)
        }
        let keys = sheet.rows.map { byRun ? ($0.run ?? $0.sample) : $0.sample }
        var keySet = Set<String>()
        if let repeated = keys.first(where: { !keySet.insert($0).inserted }) {
            throw RNASeqImportError.duplicateSample(repeated)
        }
        let onlyInFiles = fileIDs.filter { !keySet.contains($0) }
        let onlyInSheet = keys.filter { !files.contains($0) }
        guard onlyInFiles.isEmpty, onlyInSheet.isEmpty else {
            throw RNASeqImportError.sampleIDsDiffer(onlyInFiles: onlyInFiles, onlyInSheet: onlyInSheet)
        }
        let sampleByKey = Dictionary(uniqueKeysWithValues: zip(keys, sheet.rows.map(\.sample)))
        let records = sheet.rows.map {
            RNASeqSampleRecord(
                id: $0.sample, animal: $0.animal, species: $0.species, origin: $0.origin, group: $0.group,
                runs: $0.run.map { [$0] } ?? [])
        }
        return Match(sampleIDs: fileIDs.map { sampleByKey[$0] ?? $0 }, records: records)
    }
}
