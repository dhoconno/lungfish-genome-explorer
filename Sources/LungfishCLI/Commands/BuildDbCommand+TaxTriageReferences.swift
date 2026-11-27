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

    /// The references of the row whose primary accession is `accession` in `sample`, every strain the row sums in gcfmap
    /// order (`taxTriageStrainGroups`, TT-STRAIN-GROUP), the primary first. Its reads can sit on any of them, as
    /// Influenza A's sat on segments 2 and 5 and not on segment 4 in the NTC-P batch (3.2 TTREADS). No reference is in
    /// two rows' lists. An accession no row holds stands alone.
    static func organismAccessions(
        rows: [TaxTriageTaxonomyRow], accessionMap: [TaxTriageAccessionEntry]
    ) -> (String, String) -> [String] {
        let gcfmaps = Dictionary(grouping: accessionMap, by: \.sample)
        var listOf: [String: [String]] = [:]
        for (sample, sampleRows) in Dictionary(grouping: rows, by: \.sample) {
            let gcfmap = (gcfmaps[sample] ?? []).map { (accession: $0.accession, organism: $0.organism) }
            let groups = taxTriageStrainGroups(organisms: sampleRows.map(\.organism), gcfmap: gcfmap)
            let claimed = Set(groups.values.joined())
            for row in sampleRows {
                guard let primary = row.primaryAccession else { continue }
                if let list = groups[row.organism] {
                    listOf["\(sample)\t\(primary)"] = list
                } else if let organism = gcfmap.first(where: { $0.accession == primary })?.organism {
                    // A row linked by its tax ID (TT-TAXID-SYNONYM) counts every unclaimed reference of the gcfmap
                    // organism its primary accession belongs to.
                    var seen: Set<String> = []
                    listOf["\(sample)\t\(primary)"] = gcfmap
                        .filter { $0.organism == organism && !claimed.contains($0.accession) }
                        .map(\.accession)
                        .filter { seen.insert($0).inserted }
                }
            }
        }
        return { [listOf] sample, accession in listOf["\(sample)\t\(accession)"] ?? [accession] }
    }
}
