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

// MARK: - IngestionPlatform

/// The platform a FASTQ import runs as.
///
/// This is the import subset of `LungfishIO.SequencingPlatform`, the canonical
/// platform that FASTQ sidecars, barcode kits and demultiplex plans record. It
/// carries the ingestion defaults (pairing, storage optimization, quality
/// binning and compression). Its raw values are the spellings of
/// `lungfish-cli import fastq --platform`, which recipe files and import
/// provenance record, so they never change.
///
/// Oxford Nanopore is `ont` here and `oxfordNanopore` in LungfishIO, so convert
/// with ``sequencingPlatform`` and ``init(importing:)``, never through raw
/// values. The display name of `pacbio` is "PacBio HiFi" here and "PacBio" in
/// LungfishIO.
public enum IngestionPlatform: String, Codable, CaseIterable, Sendable {
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
    ///
    /// Quality binning is off by default everywhere. It is
    /// opt-in only, at import time, via an explicit user choice — never
    /// applied silently to downloads or derived operation outputs.
    public var defaultQualityBinning: QualityBinningScheme {
        .none
    }

    /// Default compression level. All platforms use `.balanced`.
    public var defaultCompressionLevel: CompressionLevel {
        return .balanced
    }
}

// MARK: - Auto-detection

extension IngestionPlatform {

    /// Attempts to identify the sequencing platform from a FASTQ read header line.
    ///
    /// This is not `LungfishIO.SequencingPlatform.detect(fromHeader:)`, and the
    /// two disagree on several headers (WorkflowPlatformPinTests lists them).
    /// `lungfish-cli import fastq` uses this one when `--platform` is absent.
    ///
    /// - Parameter header: The first line of a FASTQ record (may or may not start with `@`).
    /// - Returns: The detected platform, or `nil` if the header format is unrecognised.
    public static func detect(fromFASTQHeader header: String) -> IngestionPlatform? {
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

// MARK: - Relationship to LungfishIO.SequencingPlatform

extension IngestionPlatform {

    /// The canonical platform that a bundle imported as this platform records
    /// in its FASTQ sidecar (`PersistedFASTQMetadata.sequencingPlatform`).
    public var sequencingPlatform: LungfishIO.SequencingPlatform {
        switch self {
        case .illumina: return .illumina
        case .ont:      return .oxfordNanopore
        case .pacbio:   return .pacbio
        case .ultima:   return .ultima
        }
    }

    /// The import platform for a canonical platform, as the app passes it to
    /// `lungfish-cli import fastq --platform`.
    ///
    /// Element, MGI and unknown data have no import platform of their own and
    /// import as `illumina`, which the import then records in the bundle's
    /// sidecar through ``sequencingPlatform``.
    public init(importing platform: LungfishIO.SequencingPlatform) {
        switch platform {
        case .illumina:                self = .illumina
        case .oxfordNanopore:          self = .ont
        case .pacbio:                  self = .pacbio
        case .ultima:                  self = .ultima
        case .element, .mgi, .unknown: self = .illumina
        }
    }
}
