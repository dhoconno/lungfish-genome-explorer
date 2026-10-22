// QualityBinningScheme.swift - The quality binning an import applies to the reads it stores
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Quality score binning schemes for FASTQ compression optimization.
///
/// Binning reduces the alphabet of quality characters, improving gzip compression.
/// All schemes preserve enough resolution for variant calling and QC.
public enum QualityBinningScheme: String, Sendable, CaseIterable, Codable {
    /// Named after Illumina's NovaSeq/NovaSeqX binning scheme, but the actual
    /// `clumpify.sh quantize=0,8,13,22,27,32,37` boundaries used below produce
    /// 7 distinct quality levels, not 4. The raw value is kept as
    /// "illumina4" for backward compatibility with persisted provenance and
    /// CLI invocations; do not rename the case without a decode migration.
    case illumina4
    /// `clumpify.sh quantize=2` groups quality scores in steps of 2, which on
    /// a typical 0-40 Phred range yields roughly 21 levels, not 8.
    /// The raw value is kept as "eightLevel" for backward compatibility.
    case eightLevel
    /// No binning, which keeps every quality score as the reads have it. A user picks it at import, and a derived
    /// operation output is re-imported with it, so an output is never binned twice.
    case none

    /// The binning an import applies when the user names none, `illumina4` on every platform and every import route
    /// (owner answer Q4, 2026-10-22, lane C2-BINNING). Binning saves space and is lossy. `none` and `eightLevel` stay
    /// selectable. Every route reads this one value, so the routes cannot drift apart.
    public static let importDefault: QualityBinningScheme = .illumina4

    /// The user-visible name. The raw values are historical identifiers and are
    /// never shown in the UI (the import sheet and the Inspector both use this).
    public var displayName: String {
        switch self {
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
