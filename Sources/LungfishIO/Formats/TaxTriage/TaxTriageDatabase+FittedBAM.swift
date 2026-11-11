// TaxTriageDatabase+FittedBAM.swift - The samples whose recorded BAM build-db took by a fit of its name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension TaxTriageDatabase {
    /// Metadata key holding, as a JSON array of sample ids, each sample whose recorded BAM `build-db taxtriage` took
    /// from a scan of `minimap2/` because neither name the pipeline gives a sample's BAM was there (Phase 4 close, row
    /// BUILDDB-BAM-FIT). Every build since then writes it, `[]` when it fitted none. A database of an older build has
    /// no key, so nothing marks a BAM it fitted, and its recorded paths are read as they are until it is built again.
    public static let fittedBAMSamplesMetadataKey = "fitted_bam_samples"

    /// The metadata value for `samples`, a JSON array of the distinct ids in byte order.
    public static func fittedBAMSamplesMetadataValue(_ samples: [String]) -> String {
        let sorted = Set(samples).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        guard let data = try? JSONEncoder().encode(sorted), let value = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return value
    }

    /// The samples that `metadata` marks as fitted, empty for a database with no mark.
    public static func fittedBAMSamples(in metadata: [String: String]) -> Set<String> {
        guard let value = metadata[fittedBAMSamplesMetadataKey],
              let samples = try? JSONDecoder().decode([String].self, from: Data(value.utf8)) else { return [] }
        return Set(samples)
    }
}
