// BuildDbCommand+TaxTriageCarried.swift - The rows a TaxTriage rebuild keeps from the database it replaces
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// S1 sweep before Preview 2026.11.17, lane TT-m1 (TT-LEGACY-CLEANUP-REMOVES-TOP, folding TT-OLD-RESULT-CANNOT-RECOUNT).
// Before it the command's `.legacy` cleanup removed `top/`, the only file source of a sample whose rows came from
// `top/<sample>.top_report.tsv`, and the app ran that build on the first open of such a result. A rebuild of the folder
// then found no rows for the sample and refused, since a rebuild never leaves fewer samples than the database it
// replaces (3.2 TTREADS), so the result could never be recounted. A rebuild now keeps the earlier database's rows of
// each sample that no report of the folder holds, with every number as that database held it, out of the count pass,
// and names those samples in the database's metadata.

import Foundation
import LungfishIO

extension BuildDbCommand.TaxTriageSubcommand {
    /// Metadata key naming the samples whose rows a build kept from the database it replaced without recounting them,
    /// a JSON array in byte order. A build that kept none writes no key.
    static let notRecountedSamplesMetadataKey = "not_recounted_samples"

    /// The samples that the database a build replaces holds and that no report of the folder holds any more, with their
    /// rows, accession map entries and organism references as that database holds them.
    struct CarriedSamples {
        let samples: [String]
        let rows: [TaxTriageTaxonomyRow]
        let accessionMap: [TaxTriageAccessionEntry]
        let references: [TaxTriageOrganismReference]
        /// The carried samples the earlier database marked as fitted to another sample's BAM, or, for a database built
        /// before that mark, those with a recorded BAM named other than the sample's own two (BUILDDB-BAM-FIT).
        let fittedSamples: [String]

        /// Nil when no database is at `dbURL`, when it cannot be read, or when `rows` hold every sample it holds. Throws
        /// when it lists a sample beyond `rows` whose rows cannot be read, so the build fails and the database stays.
        static func read(from dbURL: URL, keeping rows: [TaxTriageTaxonomyRow]) throws -> CarriedSamples? {
            guard FileManager.default.fileExists(atPath: dbURL.path),
                  let earlier = try? TaxTriageDatabase(at: dbURL),
                  let held = try? earlier.fetchSamples().map(\.sample) else { return nil }
            let read = Set(rows.map(\.sample))
            let samples = held.filter { !read.contains($0) }.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            guard !samples.isEmpty else { return nil }
            let carried = try earlier.fetchRows(samples: samples)

            var accessionMap: [TaxTriageAccessionEntry] = []
            var organisms = Set<String>()
            for row in carried where organisms.insert("\(row.sample)\t\(row.organism)").inserted {
                accessionMap += (try? earlier.fetchAccessions(sample: row.sample, organism: row.organism)) ?? []
            }
            let metadata = (try? earlier.fetchMetadata()) ?? [:]
            let fitted: [String]
            if metadata[TaxTriageDatabase.fittedBAMSamplesMetadataKey] != nil {
                let marked = TaxTriageDatabase.fittedBAMSamples(in: metadata)
                fitted = samples.filter { marked.contains($0) }
            } else {
                fitted = samples.filter { sample in
                    carried.contains { row in
                        guard row.sample == sample, let path = row.bamPath else { return false }
                        let name = URL(fileURLWithPath: path).lastPathComponent
                        return name != "\(sample).bam" && name != "\(sample).\(sample).dwnld.references.bam"
                    }
                }
            }
            return CarriedSamples(
                samples: samples,
                rows: carried,
                accessionMap: accessionMap,
                references: orderedReferences(of: carried, in: earlier),
                fittedSamples: fitted
            )
        }

        /// The metadata value of ``notRecountedSamplesMetadataKey``.
        var metadataValue: String {
            guard let data = try? JSONEncoder().encode(samples), let value = String(data: data, encoding: .utf8) else { return "[]" }
            return value
        }

        /// What the build says when it keeps the rows.
        func warning(databaseName: String) -> String {
            "Warning: Kept the rows of \(samples.joined(separator: ", ")) from the earlier \(databaseName) without recounting "
                + "them, because this folder has no report for them that Lungfish can read (usually an earlier build removed "
                + "their top/ folder). To recount them, import the original TaxTriage run folder again, if you still have it."
        }

        /// Writes the database at `dbURL` again, the rows the build read and counted first and then the carried rows as the
        /// earlier database held them, so the count pass never touched them, with the organism references of both.
        func publish(at dbURL: URL, accessionMap: [TaxTriageAccessionEntry], metadata: [String: String]) throws {
            let counted = try Self.countedRows(at: dbURL)
            try TaxTriageDatabase.create(
                at: dbURL, rows: counted.rows + rows, accessionMap: accessionMap + self.accessionMap, metadata: metadata
            )
            try TaxTriageDatabase.storeOrganismReferences(counted.references + references, at: dbURL)
        }

        private static func countedRows(at dbURL: URL) throws -> (rows: [TaxTriageTaxonomyRow], references: [TaxTriageOrganismReference]) {
            let built = try TaxTriageDatabase(at: dbURL)
            let rows = try built.fetchRows(samples: try built.fetchSamples().map(\.sample))
            return (rows, orderedReferences(of: rows, in: built))
        }

        /// The stored references of each of `rows` in row order, each row's once, empty for a database built before
        /// 3.2 lane TTACCESSIONS.
        private static func orderedReferences(
            of rows: [TaxTriageTaxonomyRow], in database: TaxTriageDatabase
        ) -> [TaxTriageOrganismReference] {
            let byKey = (try? database.fetchOrganismReferences(of: rows)) ?? [:]
            var keys = Set<String>()
            var references: [TaxTriageOrganismReference] = []
            for row in rows {
                guard let primary = row.primaryAccession, !primary.isEmpty else { continue }
                let key = TaxTriageOrganismReference.rowKey(sample: row.sample, primaryAccession: primary)
                if keys.insert(key).inserted { references += byKey[key] ?? [] }
            }
            return references
        }
    }
}
