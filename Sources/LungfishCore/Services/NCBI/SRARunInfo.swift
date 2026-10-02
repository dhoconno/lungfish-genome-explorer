// SRARunInfo.swift - Information about an SRA run
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import os.log

// MARK: - SRA Run Info

/// Information about an SRA run.
public struct SRARunInfo: Sendable, Identifiable, Equatable, Codable {
    public var id: String { accession }

    /// Run accession (SRR...)
    public let accession: String

    /// Experiment accession (SRX...)
    public let experiment: String?

    /// Sample accession (SRS...)
    public let sample: String?

    /// Study accession (SRP...)
    public let study: String?

    /// BioProject accession
    public let bioproject: String?

    /// BioSample accession
    public let biosample: String?

    /// Organism name
    public let organism: String?

    /// Sequencing platform (ILLUMINA, PACBIO, etc.)
    public let platform: String?

    /// Library strategy (WGS, RNA-Seq, AMPLICON, etc.)
    public let libraryStrategy: String?

    /// Library source (GENOMIC, TRANSCRIPTOMIC, etc.)
    public let librarySource: String?

    /// Library layout (SINGLE, PAIRED)
    public let libraryLayout: String?

    /// Number of spots (reads)
    public let spots: Int?

    /// Total bases
    public let bases: Int?

    /// Average read length
    public let avgLength: Int?

    /// Size in MB
    public let size: Int?

    /// Release date
    public let releaseDate: Date?

    /// Formatted size string
    public var sizeString: String {
        guard let mb = size else { return "Unknown" }
        if mb >= 1000 {
            return String(format: "%.1f GB", Double(mb) / 1000.0)
        }
        return "\(mb) MB"
    }

    /// Formatted spots string
    public var spotsString: String {
        guard let spots = spots else { return "Unknown" }
        if spots >= 1_000_000 {
            return String(format: "%.1fM reads", Double(spots) / 1_000_000.0)
        } else if spots >= 1000 {
            return String(format: "%.1fK reads", Double(spots) / 1000.0)
        }
        return "\(spots) reads"
    }
}
