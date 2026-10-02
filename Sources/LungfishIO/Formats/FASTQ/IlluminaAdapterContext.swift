// IlluminaAdapterContext.swift - Standard Illumina adapter sequences flanking the index for improved
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Illumina Adapter Flanking Sequences

/// Standard Illumina adapter sequences flanking the index for improved matching specificity.
///
/// For TruSeq/Nextera kits, the i7 index sits within the P7 adapter:
/// `...GATCGGAAGAGCACACGTCTGAACTCCAGTCAC[i7_INDEX]ATCTCGTATGCCGTCTTCTGCTTG`
///
/// Including flanking context reduces false positive barcode matches in long reads (ONT).
public enum IlluminaAdapterContext {
    /// 15 bp upstream of the i7 index in the TruSeq/Nextera P7 adapter.
    public static let i7Upstream = "AACTCCAGTCAC"

    /// 15 bp downstream of the i7 index in the TruSeq/Nextera P7 adapter.
    public static let i7Downstream = "ATCTCGTATGCC"

    /// 12 bp upstream of the i5 index in the TruSeq P5 adapter.
    public static let i5Upstream = "AGATCGGAAGAG"

    /// 12 bp downstream of the i5 index in the TruSeq P5 adapter.
    public static let i5Downstream = "GTGTAGATCTCG"

    /// Wraps a barcode sequence with flanking adapter context for improved specificity.
    public static func withContext(
        sequence: String,
        upstream: String,
        downstream: String
    ) -> String {
        "\(upstream)\(sequence)\(downstream)"
    }
}
