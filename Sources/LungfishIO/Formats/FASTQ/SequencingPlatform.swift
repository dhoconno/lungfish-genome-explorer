// SequencingPlatform.swift - Sequencing platform identification and capabilities
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Identifies the sequencing platform that generated a FASTQ dataset.
///
/// Used to select platform-appropriate adapter contexts, error rates,
/// and demultiplexing strategies.
public enum SequencingPlatform: String, Sendable, CaseIterable {
    case illumina
    case oxfordNanopore
    case pacbio
    case element
    case ultima
    case mgi
    case unknown

    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .illumina:       return "Illumina"
        case .oxfordNanopore: return "Oxford Nanopore"
        case .pacbio:         return "PacBio"
        case .element:        return "Element Biosciences"
        case .ultima:         return "Ultima Genomics"
        case .mgi:            return "MGI / DNBSEQ"
        case .unknown:        return "Unknown"
        }
    }

    /// Whether reads can appear in either orientation (forward or reverse complement).
    ///
    /// Long-read platforms (ONT, PacBio) sequence both strands randomly;
    /// short-read platforms always read from a defined primer.
    public var readsCanBeReverseComplemented: Bool {
        switch self {
        case .oxfordNanopore, .pacbio: return true
        default: return false
        }
    }

    /// Whether this platform demultiplexes via separate index reads
    /// (i.e., demux is done before the user receives FASTQ files).
    ///
    /// When true, the app only needs to trim residual adapter read-through,
    /// not perform barcode-based demultiplexing.
    public var indexesInSeparateReads: Bool {
        switch self {
        case .illumina, .element, .ultima, .mgi: return true
        case .oxfordNanopore, .pacbio: return false
        default: return false
        }
    }

    /// Whether poly-G trimming may be needed (two-color SBS platforms).
    ///
    /// On NextSeq/NovaSeq (Illumina) and AVITI (Element), no-signal clusters
    /// produce runs of G at read ends.
    public var mayNeedPolyGTrimming: Bool {
        switch self {
        case .illumina, .element: return true
        default: return false
        }
    }

    /// Default poly-G trim quality threshold for two-color platforms.
    ///
    /// cutadapt `--nextseq-trim=N` uses this quality score to trim trailing
    /// poly-G artifacts. Only meaningful when `mayNeedPolyGTrimming` is true.
    /// Returns nil for platforms that don't need poly-G trimming.
    public var defaultPolyGTrimQuality: Int? {
        mayNeedPolyGTrimming ? 20 : nil
    }

    /// Recommended cutadapt error rate for this platform.
    ///
    /// ONT has higher error rates at read ends / adapter junctions (~5-10%),
    /// but 0.20 is overly permissive and risks false barcode matches.
    /// 0.15 balances sensitivity with specificity for noisy long reads.
    /// PacBio HiFi and short-read platforms are Q30+ (~0.1% error).
    public var recommendedErrorRate: Double {
        switch self {
        case .oxfordNanopore: return 0.15
        default:              return 0.10
        }
    }

    /// Recommended minimum overlap for cutadapt barcode matching.
    ///
    /// Short-read platforms use 5 bp minimum to reduce spurious matches
    /// while retaining sensitivity for standard 6-8 bp index sequences.
    public var recommendedMinimumOverlap: Int {
        switch self {
        case .oxfordNanopore: return 20
        case .pacbio:         return 14
        default:              return 5
        }
    }

    /// Detects the sequencing platform from one FASTQ header line.
    ///
    /// A thin wrapper over ``PlatformInference``. Returns the platform when the
    /// header alone gives high or medium confidence, otherwise nil.
    public static func detect(fromHeader header: String) -> SequencingPlatform? {
        let inference = PlatformInference.infer(fromHeader: header)
        return inference.isActionable ? inference.platform : nil
    }

    /// Detects the sequencing platform from a bounded sample of a FASTQ file
    /// (plain, gzip or BGZF). A thin wrapper over ``PlatformInference``.
    public static func detect(fromFASTQ url: URL) -> SequencingPlatform? {
        let inference = PlatformInference.infer(fromFASTQ: url)
        return inference.isActionable ? inference.platform : nil
    }

    /// Maps vendor strings to platform enum values.
    ///
    /// Covers the `lungfish-cli import fastq --platform` values, the LungfishIO
    /// raw values and the ENA and SRA `instrument_platform` spellings
    /// (`OXFORD_NANOPORE`, `PACBIO_SMRT`, `BGISEQ`, `DNBSEQ`, `ELEMENT`).
    /// `ION_TORRENT` and anything unrecognised map to `.unknown`.
    public init(vendor: String) {
        switch vendor.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "illumina":
            self = .illumina
        case "oxford-nanopore", "oxfordnanopore", "ont", "nanopore":
            self = .oxfordNanopore
        case "pacbio", "pacific-biosciences", "pacbio-smrt":
            self = .pacbio
        case "element", "element-biosciences", "element-aviti", "aviti":
            self = .element
        case "ultima", "ultima-genomics":
            self = .ultima
        case "mgi", "bgi", "dnbseq", "mgi-tech", "bgiseq":
            self = .mgi
        default:
            self = .unknown
        }
    }
}

// MARK: - Tolerant coding

/// An unrecognised raw value decodes as `.unknown` instead of failing the whole
/// file, so a later case (such as Ion Torrent) never makes an older reader drop
/// a sidecar, kit or plan.
extension SequencingPlatform: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SequencingPlatform(rawValue: raw) ?? .unknown
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
