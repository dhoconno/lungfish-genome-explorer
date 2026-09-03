// MSASequenceSelection.swift - Tiered name resolution for MSA input subsetting
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum MSASequenceSelectionError: Error, Equatable, LocalizedError {
    case unmatched([String])
    case ambiguous(name: String, matches: [String])

    public var errorDescription: String? {
        switch self {
        case .unmatched(let names):
            let list = names.joined(separator: ", ")
            return "No sequence matched --sequence \(list). A name may be a full FASTA header, an accession, or the label shown in the alignment."
        case .ambiguous(let name, let matches):
            return "--sequence \(name) matched more than one record: \(matches.joined(separator: ", ")). Use a full FASTA header to disambiguate."
        }
    }
}

/// Resolves user-supplied sequence names to input record indices.
///
/// The FASTA parser keeps the entire header line as a record's name, so a
/// GenBank record is named `MT192765.1 Severe acute respiratory syndrome ...`
/// rather than `MT192765.1`. Matching only that raw string would make
/// `--sequence MT192765.1` fail for nearly every real file, so names resolve
/// through ordered tiers instead.
public enum MSASequenceSelection {
    /// Resolves `requestedNames` to the indices of records to keep.
    ///
    /// Tiers are tried in order and the first that matches a given requested
    /// name wins, so an exact raw header always beats a token match against a
    /// different record. A name matching several records is an error rather
    /// than a silent multi-include: for a subset alignment, quietly pulling in
    /// an unintended homolog changes the resulting tree.
    ///
    /// - Parameters:
    ///   - requestedNames: Names as the user wrote them.
    ///   - records: Each input record's raw name and the file it came from.
    ///     Collected across every input file before resolution, so a name
    ///     living in the second of two files is not a false negative.
    ///   - sanitize: The pipeline's label sanitiser, injected so this stays
    ///     pure and testable.
    public static func resolve(
        requestedNames: [String],
        records: [(name: String, sourceFile: String)],
        sanitize: (String) -> String
    ) throws -> Set<Int> {
        var kept: Set<Int> = []
        var unmatched: [String] = []

        // Tier 4 keys, replicating the pipeline's de-duplication so callers
        // need not compute them.
        var occurrences: [String: Int] = [:]
        var finalLabels: [String] = []
        finalLabels.reserveCapacity(records.count)
        for record in records {
            let base = sanitize(record.name)
            let occurrence = occurrences[base, default: 0] + 1
            occurrences[base] = occurrence
            finalLabels.append(occurrence == 1 ? base : "\(base)_\(occurrence)")
        }

        for requested in requestedNames {
            let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let tiers: [[Int]] = [
                records.indices.filter { records[$0].name == trimmed },
                records.indices.filter { sanitize(records[$0].name) == trimmed },
                records.indices.filter { firstToken(records[$0].name) == trimmed },
                records.indices.filter { finalLabels[$0] == trimmed },
            ]

            guard let hits = tiers.first(where: { !$0.isEmpty }) else {
                unmatched.append(trimmed)
                continue
            }
            if hits.count > 1 {
                throw MSASequenceSelectionError.ambiguous(
                    name: trimmed,
                    matches: hits.map { "\(records[$0].name) (\(records[$0].sourceFile))" }
                )
            }
            kept.insert(hits[0])
        }

        if !unmatched.isEmpty {
            throw MSASequenceSelectionError.unmatched(unmatched)
        }
        return kept
    }

    /// The first whitespace-delimited token of a FASTA header, which is what
    /// every other tool means by a sequence's name.
    static func firstToken(_ value: String) -> String {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? value
    }
}
