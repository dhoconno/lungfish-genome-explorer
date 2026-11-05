// TaxTriageDatabase+ReadCount.swift - Which references a TaxTriage row's Reads were counted on
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension TaxTriageDatabase {
    /// Metadata key naming the references on which `lungfish build-db taxtriage` counted each row's Reads and
    /// Unique Reads.
    public static let readCountMetadataKey = "read_count"
    /// Each row counts the primary records on every reference of its organism, each segment of a segmented virus
    /// and each contig of an assembly (3.2 lane TTREADS).
    public static let currentReadCount = "organism_references"

    /// True for the metadata of a build that counted each row on its first reference alone. Its Reads can read 0 for
    /// an organism that holds reads, as Influenza A did in the NTC-P batch, whose reads sat on segments 2 and 5.
    static func countedReadsOnFirstReference(_ metadata: [String: String]) -> Bool {
        metadata[readCountMetadataKey] != currentReadCount
    }
}
