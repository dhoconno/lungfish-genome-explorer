// SequencingPlatform.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

// MARK: - CompressionLevel

/// Gzip compression level for FASTQ storage.
public enum CompressionLevel: String, Codable, Sendable, CaseIterable {
    /// Fast compression (zl=1). Larger files, faster import.
    case fast
    /// Balanced compression (zl=4). Good trade-off between size and speed.
    case balanced
    /// Maximum compression (zl=9). Smallest files, slowest import.
    case maximum

    /// The numeric zlib compression level passed to pigz/bbduk.
    public var zlValue: Int {
        switch self {
        case .fast:    return 1
        case .balanced: return 4
        case .maximum:  return 9
        }
    }

    public var displayName: String {
        switch self {
        case .fast:    return "Fast (larger files)"
        case .balanced: return "Balanced"
        case .maximum:  return "Maximum (slower import)"
        }
    }
}

// MARK: - SequencingPlatform

/// Sequencing platform of a FASTQ dataset.
///
/// Used to provide sensible defaults for the ingestion pipeline configuration.
public enum SequencingPlatform: String, Codable, CaseIterable, Sendable {
    case illumina
    case ont
    case pacbio
    case ultima

    public var displayName: String {
        switch self {
        case .illumina: return "Illumina"
        case .ont:      return "Oxford Nanopore"
        case .pacbio:   return "PacBio HiFi"
        case .ultima:   return "Ultima Genomics"
        }
    }

    /// Default pairing mode for the platform.
    ///
    /// Illumina and Ultima produce paired reads (stored as interleaved);
    /// ONT and PacBio produce single-end long reads.
    public var defaultPairing: IngestionMetadata.PairingMode {
        switch self {
        case .illumina, .ultima: return .interleaved
        case .ont, .pacbio:      return .singleEnd
        }
    }

    /// Whether storage optimization (clumpify + quality binning) should be
    /// enabled by default for this platform.
    public var defaultOptimizeStorage: Bool {
        switch self {
        case .illumina, .ultima: return true
        case .ont, .pacbio:      return false
        }
    }

    /// Default quality binning scheme for this platform.
    public var defaultQualityBinning: QualityBinningScheme {
        switch self {
        case .illumina, .ultima: return .illumina4
        case .ont, .pacbio:      return .none
        }
    }

    /// Default compression level. All platforms use `.balanced`.
    public var defaultCompressionLevel: CompressionLevel {
        return .balanced
    }
}

// MARK: - Auto-detection

extension SequencingPlatform {

    /// Attempts to identify the sequencing platform from a FASTQ read header line.
    ///
    /// - Parameter header: The first line of a FASTQ record (may or may not start with `@`).
    /// - Returns: The detected platform, or `nil` if the header format is unrecognised.
    public static func detect(fromFASTQHeader header: String) -> SequencingPlatform? {
        // Strip leading @ if present.
        let line = header.hasPrefix("@") ? String(header.dropFirst()) : header

        // ONT: header contains "runid=" key-value pair.
        if line.contains("runid=") {
            return .ont
        }

        // PacBio CCS/subreads: ^m<digits>_<digits>_<digits>/<digits>/(ccs|subreads)
        let pacbioPattern = #"^m\d+_\d+_\d+/\d+/(ccs|subreads)"#
        if let _ = line.range(of: pacbioPattern, options: .regularExpression) {
            return .pacbio
        }

        // Illumina: ^<instrument>:<run>:<flowcell>:<lane>:<tile>:<x>:<y>
        // e.g. A00488:61:HMLGNDSXX:4:1101:1234:5678
        let illuminaPattern = #"^[A-Za-z0-9_-]+:\d+:[A-Za-z0-9]+:\d+:\d+:\d+:\d+"#
        if let _ = line.range(of: illuminaPattern, options: .regularExpression) {
            return .illumina
        }

        return nil
    }
}
