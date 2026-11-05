// BuildDbCommand+TaxTriageReferences.swift - Store every reference of each TaxTriage row's organism
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension BuildDbCommand.TaxTriageSubcommand {
    /// Stores, for each row with a primary accession, every reference of its organism in its sample's gcfmap, from
    /// the same `organismAccessions` the count pass counted Unique Reads on. Each reference takes its own length and its
    /// mapped records from the `samtools idxstats` of the row's BAM that the count pass read, so the viewer's Extract
    /// Reads, BLAST Verify and alignment pane reach the references that hold the reads, ranked by them. Influenza A's
    /// row reached segment 4 alone, whose length it showed and which held none of its reads (3.2 lane TTACCESSIONS).
    static func storeOrganismReferences(
        rows: [TaxTriageTaxonomyRow],
        organismAccessions: (String, String) -> [String],
        idxstatsByBAM: [String: String],
        resultURL: URL,
        dbURL: URL
    ) throws {
        let statsByBAM = idxstatsByBAM.mapValues(referenceStats(fromIdxstats:))
        var references: [TaxTriageOrganismReference] = []
        for row in rows {
            guard let primary = row.primaryAccession, !primary.isEmpty else { continue }
            let stats = row.bamPath.flatMap { path in
                statsByBAM[path.hasPrefix("/") ? path : resultURL.appendingPathComponent(path).path]
            } ?? [:]
            for accession in organismAccessions(row.sample, primary) {
                references.append(TaxTriageOrganismReference(
                    sample: row.sample, primaryAccession: primary, accession: accession,
                    length: stats[accession]?.length, mappedReads: stats[accession]?.mappedReads
                ))
            }
        }
        try TaxTriageDatabase.storeOrganismReferences(references, at: dbURL)
    }

    /// The length and mapped records of each reference named in `samtools idxstats` output, whose columns are the
    /// reference, its length, its mapped records and its unmapped records.
    static func referenceStats(fromIdxstats output: String) -> [String: (length: Int, mappedReads: Int)] {
        var stats: [String: (length: Int, mappedReads: Int)] = [:]
        for line in output.split(separator: "\n") {
            let columns = line.split(separator: "\t")
            guard columns.count >= 3, columns[0] != "*", let length = Int(columns[1]), let mapped = Int(columns[2]) else {
                continue
            }
            stats[String(columns[0])] = (length, mapped)
        }
        return stats
    }
}
