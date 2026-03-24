// MetagenomicsModels.swift - Core metagenomics value types
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - MetagenomicsTool

/// Metagenomics tools managed by the system.
///
/// Each tool has its own database format and execution requirements.
/// The registry and pipeline use this to filter compatible databases.
public enum MetagenomicsTool: String, Codable, Sendable, CaseIterable {
    /// Kraken2 taxonomic classification.
    case kraken2
    /// Bracken abundance re-estimation (operates on Kraken2 output).
    case bracken
    /// MetaPhlAn marker-gene-based profiling.
    case metaphlan
    /// KrakenTools utilities (extract reads, combine reports, etc.).
    case krakentools
    /// EsViritu viral metagenomics detection pipeline.
    case esviritu
    /// TaxTriage clinical metagenomic triage (Nextflow pipeline).
    case taxtriage

    /// Human-readable display name for the database section header.
    public var databaseSectionTitle: String {
        switch self {
        case .kraken2: return "Kraken2 Databases"
        case .bracken: return "Bracken Databases"
        case .metaphlan: return "MetaPhlAn Databases"
        case .krakentools: return "KrakenTools"
        case .esviritu: return "EsViritu Databases"
        case .taxtriage: return "TaxTriage Databases"
        }
    }

    /// SF Symbol for the tool icon.
    public var symbolName: String {
        switch self {
        case .kraken2, .bracken, .krakentools: return "cylinder.split.1x2"
        case .metaphlan: return "chart.bar"
        case .esviritu: return "ant"
        case .taxtriage: return "stethoscope"
        }
    }
}

// MARK: - DatabaseCollection

/// Pre-built database collections available for download from Ben Langmead's
/// Kraken2 index collection at `https://genome-idx.s3.amazonaws.com/kraken/`.
///
/// Each collection represents a curated set of reference genomes with different
/// size/comprehensiveness trade-offs. Capped variants (e.g., Standard-8) use
/// minimizer-space subsampling to fit within a RAM budget.
public enum DatabaseCollection: String, Codable, Sendable, CaseIterable {
    case standard
    case standard8 = "standard-8"
    case standard16 = "standard-16"
    case plusPF = "pluspf"
    case plusPF8 = "pluspf-8"
    case plusPF16 = "pluspf-16"
    case viral
    case minusB = "minus-b"
    case euPathDB46 = "eupathdb46"

    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .standard:    return "Standard"
        case .standard8:   return "Standard-8"
        case .standard16:  return "Standard-16"
        case .plusPF:      return "PlusPF"
        case .plusPF8:     return "PlusPF-8"
        case .plusPF16:    return "PlusPF-16"
        case .viral:       return "Viral"
        case .minusB:      return "MinusB"
        case .euPathDB46:  return "EuPathDB46"
        }
    }

    /// Approximate download size in bytes.
    public var approximateSizeBytes: Int64 {
        switch self {
        case .standard:    return 67 * 1_073_741_824  // 67 GB
        case .standard8:   return  8 * 1_073_741_824  //  8 GB
        case .standard16:  return 16 * 1_073_741_824  // 16 GB
        case .plusPF:      return 72 * 1_073_741_824  // 72 GB
        case .plusPF8:     return  8 * 1_073_741_824  //  8 GB
        case .plusPF16:    return 16 * 1_073_741_824  // 16 GB
        case .viral:       return     536_870_912     //  0.5 GB
        case .minusB:      return 11 * 1_073_741_824  // 11 GB
        case .euPathDB46:  return 34 * 1_073_741_824  // 34 GB
        }
    }

    /// Approximate RAM required for classification in bytes.
    ///
    /// When the database cannot fit in RAM, Kraken2 falls back to
    /// `--memory-mapping` which is significantly slower.
    public var approximateRAMBytes: Int64 {
        switch self {
        case .standard:    return 67 * 1_073_741_824
        case .standard8:   return  8 * 1_073_741_824
        case .standard16:  return 16 * 1_073_741_824
        case .plusPF:      return 72 * 1_073_741_824
        case .plusPF8:     return  8 * 1_073_741_824
        case .plusPF16:    return 16 * 1_073_741_824
        case .viral:       return     536_870_912
        case .minusB:      return 11 * 1_073_741_824
        case .euPathDB46:  return 34 * 1_073_741_824
        }
    }

    /// Description of the taxonomic contents.
    public var contentsDescription: String {
        switch self {
        case .standard:
            return "Archaea, bacteria, viral, plasmid, human, UniVec"
        case .standard8:
            return "Same as Standard, capped at 8 GB"
        case .standard16:
            return "Same as Standard, capped at 16 GB"
        case .plusPF:
            return "Standard + protozoa + fungi"
        case .plusPF8:
            return "PlusPF capped at 8 GB"
        case .plusPF16:
            return "PlusPF capped at 16 GB"
        case .viral:
            return "RefSeq viral genomes only"
        case .minusB:
            return "Standard minus bacteria"
        case .euPathDB46:
            return "Eukaryotic pathogens (EuPathDB)"
        }
    }

    /// Base download URL for this collection's tarball.
    ///
    /// The actual URL includes a date suffix (e.g., `k2_standard_20240904.tar.gz`).
    /// The registry appends the latest known version date.
    public var downloadURLBase: String {
        let base = "https://genome-idx.s3.amazonaws.com/kraken"
        switch self {
        case .standard:    return "\(base)/k2_standard"
        case .standard8:   return "\(base)/k2_standard_08gb"
        case .standard16:  return "\(base)/k2_standard_16gb"
        case .plusPF:      return "\(base)/k2_pluspf"
        case .plusPF8:     return "\(base)/k2_pluspf_08gb"
        case .plusPF16:    return "\(base)/k2_pluspf_16gb"
        case .viral:       return "\(base)/k2_viral"
        case .minusB:      return "\(base)/k2_minusb"
        case .euPathDB46:  return "\(base)/k2_eupathdb48"
        }
    }
}

// MARK: - DatabaseLocation

/// Where a database is stored on disk.
///
/// Local paths are stored as absolute strings. When a user moves a database
/// to an external volume, a security-scoped bookmark is created so the app
/// can re-access the location after relaunch without a new file-open dialog.
public enum DatabaseLocation: Codable, Sendable, Equatable {
    /// Database is on a local (always-mounted) volume.
    case local(path: String)

    /// Database is on an external or network volume, tracked via bookmark.
    ///
    /// - Parameters:
    ///   - data: Security-scoped bookmark data.
    ///   - lastKnownPath: The path at bookmark creation time, for display when
    ///     the volume is not mounted.
    case bookmark(data: Data, lastKnownPath: String)
}

// MARK: - DatabaseStatus

/// Current operational status of a registered database.
public enum DatabaseStatus: String, Codable, Sendable {
    /// Database is verified and ready to use.
    case ready
    /// Database is currently being downloaded.
    case downloading
    /// Database is being verified (checking required files).
    case verifying
    /// Database is missing required files or has been corrupted.
    case corrupt
    /// The external volume containing the database is not mounted.
    case volumeNotMounted
    /// The database directory no longer exists.
    case missing
}
