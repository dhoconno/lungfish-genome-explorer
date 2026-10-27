// QualityBinningScheme.swift - The quality binning an import applies to the reads it stores
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Quality score binning schemes for FASTQ compression optimization.
///
/// Binning reduces the alphabet of quality characters, improving gzip compression. It changes the stored scores, and
/// the scheme decides whether a score moves across a line LGE reports or filters on.
public enum QualityBinningScheme: String, Sendable, CaseIterable, Codable {
    /// `quantize=0,2,7,12,17,22,27,32,37`: scores in steps of five, Q0 to Q4 stored as 2, up to Q35 and above as 37;
    /// no score crosses Q10, Q20 or Q30 (BIO-BIN, Phase 3.0). The binning an Illumina import runs when nobody names
    /// one, `IngestionPlatform.defaultQualityBinning(for:)`.
    case fiveStep
    /// `quantize=0,8,13,22,27,32,37`, 7 levels. It raises called Q0 to Q10 to 8 and Q18 and Q19 to 22, so a Q20 share
    /// reads high (BIO-BIN, S1). No route picks it any more. It stays so an older import's record decodes and replays
    /// to the same bytes, and the CLI still accepts it. The raw value is historical, so do not rename the case.
    case illumina4
    /// `clumpify.sh quantize=2` groups quality scores in steps of 2, which on
    /// a typical 0-40 Phred range yields roughly 21 levels, not 8.
    /// The raw value is kept as "eightLevel" for backward compatibility.
    case eightLevel
    /// No binning, which keeps every quality score as the reads have it. A user picks it at import, and a derived
    /// operation output is re-imported with it, so an output is never binned twice.
    case none

    /// The user-visible name. The raw values are historical identifiers and are
    /// never shown in the UI (the import sheet and the Inspector both use this).
    public var displayName: String {
        switch self {
        case .fiveStep: return "Q5 steps (8-level)"
        case .illumina4: return "Illumina (7-level)"
        case .eightLevel: return "Fine (~21-level)"
        case .none: return "None (preserve original)"
        }
    }

    /// Display name for a persisted raw value, falling back to the raw value
    /// itself for a scheme this build does not know.
    public static func displayName(forRawValue rawValue: String) -> String {
        QualityBinningScheme(rawValue: rawValue)?.displayName ?? rawValue
    }
}
