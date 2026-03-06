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

    /// Filter by geographic location
    public var geoLocCountry: String?

    /// Filter by collection date (start), format: YYYY-MM-DD
    public var sampleCollectionDateFrom: String?

    /// Filter by collection date (end), format: YYYY-MM-DD
    public var sampleCollectionDateTo: String?

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
        geoLocCountry: String? = nil,
        sampleCollectionDateFrom: String? = nil,
        sampleCollectionDateTo: String? = nil,
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

    // MARK: - Core Identifiers

    /// Primary accession (e.g., "PP_0015NF5")
    public let accession: String
    /// Version string (e.g., "PP_0015NF5.2")
    public let accessionVersion: String?
    /// Organism name
    public let organism: String?
    /// Display name (e.g., "Japan/PP_0015NF5.2")
    public let displayName: String?

    // MARK: - Geographic & Temporal

    /// Geographic location country
    public let geoLocCountry: String?
    /// Geographic admin level 1 (e.g., "Hokkaido, Sapporo")
    public let geoLocAdmin1: String?
    /// Geographic city
    public let geoLocCity: String?
    /// Sample collection date (string format)
    public let sampleCollectionDate: String?
    /// Submission date
    public let submittedDate: String?
    /// Release date
    public let releasedDate: String?

    // MARK: - Sequence Properties

    /// Sequence length
    public let length: Int?
    /// Subtype/genotype (e.g., "A.2.1")
    public let subtype: String?
    /// Clade classification
    public let clade: String?
    /// Lineage classification
    public let lineage: String?

    // MARK: - Host Information

    /// Scientific name of the host organism
    public let hostNameScientific: String?
    /// Common name of the host organism
    public let hostNameCommon: String?

    // MARK: - Cross-References

    /// INSDC accession base (e.g., "AB160902")
    public let insdcAccessionBase: String?
    /// INSDC accession with version (e.g., "AB160902.1")
    public let insdcAccessionFull: String?
    /// BioProject accession
    public let bioprojectAccession: String?
    /// BioSample accession
    public let biosampleAccession: String?
    /// NCBI source database (e.g., "GenBank")
    public let ncbiSourceDb: String?
    /// NCBI virus name
    public let ncbiVirusName: String?
    /// NCBI virus taxonomy ID
    public let ncbiVirusTaxId: Int?

    // MARK: - Submission & Provenance

    /// Authors
    public let authors: String?
    /// Submitter group name
    public let groupName: String?
    /// Data use terms (e.g., "OPEN", "RESTRICTED")
    public let dataUseTerms: String?
    /// Version status
    public let versionStatus: String?

    // MARK: - Sequencing Details

    /// Sequencing organization
    public let sequencedByOrganization: String?
    /// Sequencing instrument
    public let sequencingInstrument: String?
    /// Consensus sequence software name
    public let consensusSequenceSoftwareName: String?
    /// Consensus sequence software version
    public let consensusSequenceSoftwareVersion: String?
    /// Purpose of sampling
    public let purposeOfSampling: String?
    /// Purpose of sequencing
    public let purposeOfSequencing: String?

    // MARK: - Quality Metrics

    /// Depth of coverage
    public let depthOfCoverage: Double?
    /// Breadth of coverage
    public let breadthOfCoverage: Double?
    /// Completeness fraction
    public let completeness: Double?
    /// Quality control determination
    public let qualityControlDetermination: String?
    /// Total SNPs
    public let totalSnps: Int?
    /// Total deleted nucleotides
    public let totalDeletedNucs: Int?
    /// Total inserted nucleotides
    public let totalInsertedNucs: Int?
    /// Total unknown nucleotides
    public let totalUnknownNucs: Int?

    // MARK: - Computed Properties

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Parsed collection date
    public var collectionDate: Date? {
        guard let dateStr = sampleCollectionDate else { return nil }
        return Self.dateFormatter.date(from: dateStr)
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

    /// Best geographic location string
    public var bestLocation: String? {
        var parts: [String] = []
        if let city = geoLocCity, !city.isEmpty { parts.append(city) }
        if let admin = geoLocAdmin1, !admin.isEmpty { parts.append(admin) }
        if let country = geoLocCountry, !country.isEmpty { parts.append(country) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    enum CodingKeys: String, CodingKey {
        case accession, accessionVersion, organism, displayName
        case geoLocCountry, geoLocAdmin1, geoLocCity
        case sampleCollectionDate, submittedDate, releasedDate
        case length, subtype, clade, lineage
        case hostNameScientific, hostNameCommon
        case insdcAccessionBase, insdcAccessionFull
        case bioprojectAccession, biosampleAccession
        case ncbiSourceDb, ncbiVirusName, ncbiVirusTaxId
        case authors, groupName, dataUseTerms, versionStatus
        case sequencedByOrganization, sequencingInstrument
        case consensusSequenceSoftwareName, consensusSequenceSoftwareVersion
        case purposeOfSampling, purposeOfSequencing
        case depthOfCoverage, breadthOfCoverage, completeness
        case qualityControlDetermination
        case totalSnps, totalDeletedNucs, totalInsertedNucs, totalUnknownNucs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accession = try container.decode(String.self, forKey: .accession)
        accessionVersion = try container.decodeIfPresent(String.self, forKey: .accessionVersion)
        organism = try container.decodeIfPresent(String.self, forKey: .organism)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        geoLocCountry = try container.decodeIfPresent(String.self, forKey: .geoLocCountry)
        geoLocAdmin1 = try container.decodeIfPresent(String.self, forKey: .geoLocAdmin1)
        geoLocCity = try container.decodeIfPresent(String.self, forKey: .geoLocCity)
        sampleCollectionDate = try container.decodeIfPresent(String.self, forKey: .sampleCollectionDate)
        submittedDate = try container.decodeIfPresent(String.self, forKey: .submittedDate)
        releasedDate = try container.decodeIfPresent(String.self, forKey: .releasedDate)

        // Handle length as either int or string
        if let lengthInt = try? container.decodeIfPresent(Int.self, forKey: .length) {
            length = lengthInt
        } else if let lengthStr = try? container.decodeIfPresent(String.self, forKey: .length) {
            length = Int(lengthStr)
        } else {
            length = nil
        }

        subtype = try container.decodeIfPresent(String.self, forKey: .subtype)
        clade = try container.decodeIfPresent(String.self, forKey: .clade)
        lineage = try container.decodeIfPresent(String.self, forKey: .lineage)
        hostNameScientific = try container.decodeIfPresent(String.self, forKey: .hostNameScientific)
        hostNameCommon = try container.decodeIfPresent(String.self, forKey: .hostNameCommon)
        insdcAccessionBase = try container.decodeIfPresent(String.self, forKey: .insdcAccessionBase)
        insdcAccessionFull = try container.decodeIfPresent(String.self, forKey: .insdcAccessionFull)
        bioprojectAccession = try container.decodeIfPresent(String.self, forKey: .bioprojectAccession)
        biosampleAccession = try container.decodeIfPresent(String.self, forKey: .biosampleAccession)
        ncbiSourceDb = try container.decodeIfPresent(String.self, forKey: .ncbiSourceDb)
        ncbiVirusName = try container.decodeIfPresent(String.self, forKey: .ncbiVirusName)
        ncbiVirusTaxId = try container.decodeIfPresent(Int.self, forKey: .ncbiVirusTaxId)
        authors = try container.decodeIfPresent(String.self, forKey: .authors)
        groupName = try container.decodeIfPresent(String.self, forKey: .groupName)
        dataUseTerms = try container.decodeIfPresent(String.self, forKey: .dataUseTerms)
        versionStatus = try container.decodeIfPresent(String.self, forKey: .versionStatus)
        sequencedByOrganization = try container.decodeIfPresent(String.self, forKey: .sequencedByOrganization)
        sequencingInstrument = try container.decodeIfPresent(String.self, forKey: .sequencingInstrument)
        consensusSequenceSoftwareName = try container.decodeIfPresent(String.self, forKey: .consensusSequenceSoftwareName)
        consensusSequenceSoftwareVersion = try container.decodeIfPresent(String.self, forKey: .consensusSequenceSoftwareVersion)
        purposeOfSampling = try container.decodeIfPresent(String.self, forKey: .purposeOfSampling)
        purposeOfSequencing = try container.decodeIfPresent(String.self, forKey: .purposeOfSequencing)

        // Handle numeric fields that might come as strings
        if let v = try? container.decodeIfPresent(Double.self, forKey: .depthOfCoverage) {
            depthOfCoverage = v
        } else if let s = try? container.decodeIfPresent(String.self, forKey: .depthOfCoverage) {
            depthOfCoverage = Double(s)
        } else { depthOfCoverage = nil }

        if let v = try? container.decodeIfPresent(Double.self, forKey: .breadthOfCoverage) {
            breadthOfCoverage = v
        } else if let s = try? container.decodeIfPresent(String.self, forKey: .breadthOfCoverage) {
            breadthOfCoverage = Double(s)
        } else { breadthOfCoverage = nil }

        if let v = try? container.decodeIfPresent(Double.self, forKey: .completeness) {
            completeness = v
        } else if let s = try? container.decodeIfPresent(String.self, forKey: .completeness) {
            completeness = Double(s)
        } else { completeness = nil }

        qualityControlDetermination = try container.decodeIfPresent(String.self, forKey: .qualityControlDetermination)
        totalSnps = try container.decodeIfPresent(Int.self, forKey: .totalSnps)
        totalDeletedNucs = try container.decodeIfPresent(Int.self, forKey: .totalDeletedNucs)
        totalInsertedNucs = try container.decodeIfPresent(Int.self, forKey: .totalInsertedNucs)
        totalUnknownNucs = try container.decodeIfPresent(Int.self, forKey: .totalUnknownNucs)
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


