// PathoplexusModels.swift - Data models for Pathoplexus integration
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Product Fit Expert (Role 21)

import Foundation

// MARK: - Pathoplexus Organism

/// An organism tracked in Pathoplexus.
public struct PathoplexusOrganism: Sendable, Codable, Identifiable, Equatable {
    /// Unique identifier (e.g., "ebola-zaire", "mpox")
    public let id: String

    /// Human-readable name
    public let displayName: String

    /// Whether this organism has a segmented genome
    public let segmented: Bool

    /// Segment names for segmented genomes (e.g., ["S", "M", "L"] for CCHF)
    public let segments: [String]?

    public init(id: String, displayName: String, segmented: Bool, segments: [String]?) {
        self.id = id
        self.displayName = displayName
        self.segmented = segmented
        self.segments = segments
    }
}

// MARK: - Pathoplexus Filters

/// Search filters for Pathoplexus queries.
public struct PathoplexusFilters: Sendable, Equatable {
    /// Filter by specific accession
    public var accession: String?

    /// Filter by accession version
    public var accessionVersion: String?

    /// Filter by geographic location
    public var geoLocCountry: String?

    /// Filter by collection date (start)
    public var sampleCollectionDateFrom: Date?

    /// Filter by collection date (end)
    public var sampleCollectionDateTo: Date?

    /// Minimum sequence length
    public var lengthFrom: Int?

    /// Maximum sequence length
    public var lengthTo: Int?

    /// Filter by nucleotide mutations (format: "C180T")
    public var nucleotideMutations: [String]?

    /// Filter by amino acid mutations (format: "GP:440G")
    public var aminoAcidMutations: [String]?

    /// Version status filter
    public var versionStatus: VersionStatus?

    /// Filter by clade
    public var clade: String?

    /// Filter by lineage
    public var lineage: String?

    /// Filter by host name (scientific)
    public var hostNameScientific: String?

    /// Filter by data use terms (OPEN or RESTRICTED)
    public var dataUseTerms: DataUseTerms?

    public init(
        accession: String? = nil,
        accessionVersion: String? = nil,
        geoLocCountry: String? = nil,
        sampleCollectionDateFrom: Date? = nil,
        sampleCollectionDateTo: Date? = nil,
        lengthFrom: Int? = nil,
        lengthTo: Int? = nil,
        nucleotideMutations: [String]? = nil,
        aminoAcidMutations: [String]? = nil,
        versionStatus: VersionStatus? = nil,
        clade: String? = nil,
        lineage: String? = nil,
        hostNameScientific: String? = nil,
        dataUseTerms: DataUseTerms? = nil
    ) {
        self.accession = accession
        self.accessionVersion = accessionVersion
        self.geoLocCountry = geoLocCountry
        self.sampleCollectionDateFrom = sampleCollectionDateFrom
        self.sampleCollectionDateTo = sampleCollectionDateTo
        self.lengthFrom = lengthFrom
        self.lengthTo = lengthTo
        self.nucleotideMutations = nucleotideMutations
        self.aminoAcidMutations = aminoAcidMutations
        self.versionStatus = versionStatus
        self.clade = clade
        self.lineage = lineage
        self.hostNameScientific = hostNameScientific
        self.dataUseTerms = dataUseTerms
    }
}

// MARK: - Version Status

/// Version status for Pathoplexus records.
public enum VersionStatus: String, Sendable, Codable {
    case latestVersion = "LATEST_VERSION"
    case revisedVersion = "REVISED_VERSION"
}

// MARK: - Pathoplexus Metadata

/// Metadata for a sequence in Pathoplexus.
public struct PathoplexusMetadata: Sendable, Codable, Identifiable {
    public var id: String { accession }

    /// Primary accession
    public let accession: String

    /// Version of the accession
    public let accessionVersion: String?

    /// Organism name
    public let organism: String?

    /// Geographic location country
    public let geoLocCountry: String?

    /// Sample collection date (string format)
    public let sampleCollectionDate: String?

    /// Sequence length
    public let length: Int?

    /// Submitting laboratory
    public let submittingLab: String?

    /// Authors
    public let authors: String?

    /// Data use terms
    public let dataUseTerms: String?

    /// Version status
    public let versionStatus: String?

    /// INSDC accession base (e.g., "PP123456") — links to GenBank/ENA/DDBJ
    public let insdcAccessionBase: String?

    /// INSDC accession with version (e.g., "PP123456.1")
    public let insdcAccessionFull: String?

    /// Clade classification
    public let clade: String?

    /// Lineage classification
    public let lineage: String?

    /// Scientific name of the host organism
    public let hostNameScientific: String?

    /// Common name of the host organism
    public let hostNameCommon: String?

    /// Parsed collection date
    public var collectionDate: Date? {
        guard let dateStr = sampleCollectionDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: dateStr)
    }

    /// Whether this record has an INSDC accession that can be used to fetch from GenBank
    public var hasINSDCAccession: Bool {
        if let base = insdcAccessionBase, !base.isEmpty { return true }
        if let full = insdcAccessionFull, !full.isEmpty { return true }
        return false
    }

    /// Best INSDC accession to use for GenBank retrieval
    public var bestINSDCAccession: String? {
        if let full = insdcAccessionFull, !full.isEmpty { return full }
        if let base = insdcAccessionBase, !base.isEmpty { return base }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case accession
        case accessionVersion
        case organism
        case geoLocCountry
        case sampleCollectionDate
        case length
        case submittingLab
        case authors
        case dataUseTerms
        case versionStatus
        case insdcAccessionBase
        case insdcAccessionFull
        case clade
        case lineage
        case hostNameScientific
        case hostNameCommon
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accession = try container.decode(String.self, forKey: .accession)
        accessionVersion = try container.decodeIfPresent(String.self, forKey: .accessionVersion)
        organism = try container.decodeIfPresent(String.self, forKey: .organism)
        geoLocCountry = try container.decodeIfPresent(String.self, forKey: .geoLocCountry)
        sampleCollectionDate = try container.decodeIfPresent(String.self, forKey: .sampleCollectionDate)

        // Handle length as either int or string
        if let lengthInt = try? container.decodeIfPresent(Int.self, forKey: .length) {
            length = lengthInt
        } else if let lengthStr = try? container.decodeIfPresent(String.self, forKey: .length) {
            length = Int(lengthStr)
        } else {
            length = nil
        }

        submittingLab = try container.decodeIfPresent(String.self, forKey: .submittingLab)
        authors = try container.decodeIfPresent(String.self, forKey: .authors)
        dataUseTerms = try container.decodeIfPresent(String.self, forKey: .dataUseTerms)
        versionStatus = try container.decodeIfPresent(String.self, forKey: .versionStatus)
        insdcAccessionBase = try container.decodeIfPresent(String.self, forKey: .insdcAccessionBase)
        insdcAccessionFull = try container.decodeIfPresent(String.self, forKey: .insdcAccessionFull)
        clade = try container.decodeIfPresent(String.self, forKey: .clade)
        lineage = try container.decodeIfPresent(String.self, forKey: .lineage)
        hostNameScientific = try container.decodeIfPresent(String.self, forKey: .hostNameScientific)
        hostNameCommon = try container.decodeIfPresent(String.self, forKey: .hostNameCommon)
    }
}

// MARK: - Data Use Terms

/// Data use terms for Pathoplexus submissions.
public enum DataUseTerms: String, Sendable, Codable, CaseIterable {
    /// Immediately open and shared
    case open = "OPEN"

    /// Time-limited protection (up to one year)
    case restricted = "RESTRICTED"

    /// Human-readable description.
    public var description: String {
        switch self {
        case .open:
            return "Open - Immediately available for public access"
        case .restricted:
            return "Restricted - Time-limited protection for attribution"
        }
    }
}

// MARK: - Pathoplexus Group

/// A group/organization in Pathoplexus.
public struct PathoplexusGroup: Sendable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let institution: String?
    public let contactEmail: String?

    public init(id: String, name: String, institution: String? = nil, contactEmail: String? = nil) {
        self.id = id
        self.name = name
        self.institution = institution
        self.contactEmail = contactEmail
    }
}

// MARK: - Submission Types

/// A submission request to Pathoplexus.
public struct PathoplexusSubmissionRequest: Sendable {
    /// The organism this submission is for
    public let organism: String

    /// URL to the FASTA file
    public let sequencesFile: URL

    /// URL to the TSV metadata file
    public let metadataFile: URL

    /// The group to submit under
    public let groupId: String

    /// Data use terms
    public let dataUseTerms: DataUseTerms

    public init(
        organism: String,
        sequencesFile: URL,
        metadataFile: URL,
        groupId: String,
        dataUseTerms: DataUseTerms
    ) {
        self.organism = organism
        self.sequencesFile = sequencesFile
        self.metadataFile = metadataFile
        self.groupId = groupId
        self.dataUseTerms = dataUseTerms
    }
}
