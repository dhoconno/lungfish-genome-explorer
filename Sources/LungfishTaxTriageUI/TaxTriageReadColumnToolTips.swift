// TaxTriageReadColumnToolTips.swift - What the Reads and Unique Reads columns of a TaxTriage table count
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The header tooltips of the Reads and Unique Reads columns, which count different sets of reads (3.2 lane TTREADS,
/// BIO ruling F1). A person who checks Lungfish against TaxTriage's own report finds the Reads cell there.
enum TaxTriageReadColumnToolTips {
    static let reads = "Reads TaxTriage assigned to this organism in its report (# Reads Aligned): primary alignments that pass the run's mapping-quality and conflict filters, summed over every reference of the organism. Abundance is this count as a share of the sample's reads."

    static let uniqueReads = "Of the BAM's primary alignments on this organism's references, those samtools markdup did not mark as duplicates, counted before TaxTriage's filters. A dash means the BAM holds more of them than TaxTriage kept, so the count does not apply to this row."
}
