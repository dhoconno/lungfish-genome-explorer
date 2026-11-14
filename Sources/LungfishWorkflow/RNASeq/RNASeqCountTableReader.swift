// RNASeqCountTableReader.swift - A plain genes-by-samples count table read as given (Phase 5.1 lane RS-BULK-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A plain table holds a feature id in its first column and one sample a column after it, such as the UMI counts of C9
// (`Tests/Fixtures/rnaseq/umi-table-c9/counts.tsv`). The counts are read as given through the one table parser of the
// result, and the file is kept as given in `source/tables/` (`docs/formats/rnaseq-bundle.md`, The tool's own files).

import Foundation
import LungfishIO

/// Why an import of bulk counts refused its files, in words a person can act on.
public enum RNASeqImportError: Error, Equatable, LocalizedError, Sendable {
    case missingFile(folder: String, file: String)
    case invalidFile(path: String, reason: String)
    case transcriptSetsDiffer(first: String, other: String)
    case routesDiffer(String)
    case transcriptsWithoutGene(count: Int, examples: [String])
    case duplicateSample(String)
    case duplicateFeature(String)
    case noSamples(String)
    case sampleIDsDiffer(onlyInFiles: [String], onlyInSheet: [String])

    public var errorDescription: String? {
        switch self {
        case .missingFile(let folder, let file):
            return "The salmon folder \(folder) has no \(file), so it cannot be imported."
        case .invalidFile(let path, let reason):
            return "\(path) could not be read, because \(reason)."
        case .transcriptSetsDiffer(let first, let other):
            return "The salmon folders \(first) and \(other) list different transcripts, so they were not quantified on one index and cannot share one table."
        case .routesDiffer(let what):
            return "The salmon folders differ in their \(what), so their counts come from two routes and cannot share one table."
        case .transcriptsWithoutGene(let count, let examples):
            return "\(count) transcripts of the salmon folders have no gene in the transcript-to-gene table, such as \(examples.joined(separator: ", ")). Pass a table that names a gene for every transcript."
        case .duplicateSample(let id):
            return "The sample \(id) appears twice. Each sample is one folder or one column."
        case .duplicateFeature(let id):
            return "The feature \(id) is on two rows of the count table."
        case .noSamples(let name):
            return "\(name) holds no sample column after its feature ids."
        case .sampleIDsDiffer(let onlyInFiles, let onlyInSheet):
            func list(_ ids: [String]) -> String { ids.isEmpty ? "none" : ids.joined(separator: ", ") }
            return "The sample ids of the files and the sample sheet differ. Only in the files: \(list(onlyInFiles)). Only in the sheet: \(list(onlyInSheet)). "
                + "Make the sheet's run or sample column name the same samples as the files, or leave out --samples."
        }
    }
}

/// The run facts an imported file does not state, which the record holds as Not recorded
/// (`docs/plans/2026-10-02-architecture-program.md:189`, `docs/plans/2026-11-13-phase-5-rnaseq-reproduction.md:100,103`).
public enum RNASeqImportFacts {
    public static let notRecorded = "Not recorded"
    /// The reference set, the instrument, the kit, poly-G trimming and duplicate handling.
    public static let unstatedKeys = ["referenceSet", "instrument", "kit", "polyGTrimming", "duplicates"]
    /// The key that names each file of a tool's folder the import leaves out, as `<sample>/<path>`, present only when
    /// the import leaves one out (`docs/formats/rnaseq-bundle.md`, The tool's own files).
    public static let filesLeftOutKey = "filesLeftOut"

    public static var unstated: [String: ParameterValue] {
        Dictionary(uniqueKeysWithValues: unstatedKeys.map { ($0, ParameterValue.string(notRecorded)) })
    }
}

public enum RNASeqCountTableReader {
    /// Reads a genes-by-samples table. A repeated sample or feature id is refused, and a cell that is no count too.
    public static func read(_ url: URL) throws -> RNASeqCountTable {
        let name = url.lastPathComponent
        let table = try RNASeqCountTable(tsv: Data(contentsOf: url), path: name)
        guard !table.sampleIDs.isEmpty else { throw RNASeqImportError.noSamples(name) }
        var samples = Set<String>()
        if let repeated = table.sampleIDs.first(where: { !samples.insert($0).inserted }) {
            throw RNASeqImportError.duplicateSample(repeated)
        }
        var features = Set<String>()
        if let repeated = table.rows.first(where: { !features.insert($0.id).inserted }) {
            throw RNASeqImportError.duplicateFeature(repeated.id)
        }
        return table
    }
}
