// NCBIResponseModels.swift - NCBI Entrez E-utilities integration
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: NCBI Integration Lead (Role 12)

import Foundation

// MARK: - Response Types

struct ESearchResponse: Codable {
    let esearchresult: ESearchResult?
}

struct ESearchResult: Codable {
    let count: String?
    let retmax: String?
    let retstart: String?
    let idlist: [String]?
    let errorlist: ESearchErrorList?
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case count
        case retmax
        case retstart
        case idlist
        case errorlist
        case error = "ERROR"
    }
}

struct ESearchErrorList: Codable {
    let phrasesnotfound: [String]?
}

/// Decodes the NCBI ESummary/ESearch style `{ "result": { "uids": [...], "<uid>": {...} } }`
/// envelope into a `[uid: value]` dictionary, skipping the `uids` index array and
/// silently dropping entries that fail to decode. Returns nil when no entries decode.
enum NCBIKeyedResultDecoder {
    private enum EnvelopeKey: String, CodingKey { case result }

    static func decode<V: Decodable>(_ decoder: Decoder) throws -> [String: V]? {
        let container = try decoder.container(keyedBy: EnvelopeKey.self)

        // The result is nested inside the "result" key
        let resultContainer = try container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .result)
        var result: [String: V] = [:]

        for key in resultContainer.allKeys {
            // Skip the "uids" array
            if key.stringValue == "uids" { continue }
            if let value = try? resultContainer.decode(V.self, forKey: key) {
                result[key.stringValue] = value
            }
        }

        return result.isEmpty ? nil : result
    }
}

struct ESummaryResponse: Codable {
    let result: [String: NCBIDocumentSummary]?

    private enum CodingKeys: String, CodingKey {
        case result
    }

    init(from decoder: Decoder) throws {
        result = try NCBIKeyedResultDecoder.decode(decoder)
    }
}

struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Document summary from NCBI ESummary.
public struct NCBIDocumentSummary: Codable, Sendable {
    public let uid: String
    public let caption: String?
    public let title: String?
    public let accessionVersion: String?
    public let organism: String?
    public let taxid: Int?
    public let slen: Int?
    public let createDate: Date?

    /// Scientific name from taxonomy esummary responses.
    /// Only populated when querying the taxonomy database.
    public let scientificName: String?

    public var length: Int? { slen }

    enum CodingKeys: String, CodingKey {
        case uid
        case caption
        case title
        case accessionVersion = "accessionversion"
        case organism
        case taxid
        case slen
        case createDate = "createdate"
        case scientificName = "ScientificName"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = try container.decode(String.self, forKey: .uid)
        caption = try container.decodeIfPresent(String.self, forKey: .caption)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        accessionVersion = try container.decodeIfPresent(String.self, forKey: .accessionVersion)
        organism = try container.decodeIfPresent(String.self, forKey: .organism)
        taxid = try container.decodeIfPresent(Int.self, forKey: .taxid)
        slen = try container.decodeIfPresent(Int.self, forKey: .slen)
        scientificName = try container.decodeIfPresent(String.self, forKey: .scientificName)

        // Parse date string
        if let dateStr = try container.decodeIfPresent(String.self, forKey: .createDate) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy/MM/dd"
            createDate = formatter.date(from: dateStr)
        } else {
            createDate = nil
        }
    }
}

// MARK: - Assembly Summary Response

struct AssemblyESummaryResponse: Codable {
    let result: [String: NCBIAssemblySummary]?

    private enum CodingKeys: String, CodingKey {
        case result
    }

    init(from decoder: Decoder) throws {
        result = try NCBIKeyedResultDecoder.decode(decoder)
    }
}

/// Assembly summary from NCBI ESummary for assembly database.
///
/// Contains core assembly metadata plus enriched fields for metadata export.
/// All new fields use `decodeIfPresent` for backward compatibility with older API responses.
public struct NCBIAssemblySummary: Codable, Sendable {
    public let uid: String
    public let assemblyAccession: String?
    public let assemblyName: String?
    public let organism: String?
    public let taxid: Int?
    public let speciesName: String?
    public let ftpPathRefSeq: String?
    public let ftpPathGenBank: String?
    public let submitter: String?
    public let coverage: String?
    public let contigN50: Int?
    public let scaffoldN50: Int?

    // Enriched metadata fields from NCBI ESummary
    /// Assembly status (e.g., "Complete Genome", "Scaffold").
    public let assemblyStatus: String?
    /// Assembly level (e.g., "Chromosome", "Scaffold", "Contig").
    public let assemblyLevel: String?
    /// RefSeq category (e.g., "representative genome", "reference genome").
    public let refseqCategory: String?
    /// BioSample accession (e.g., "SAMN02436634").
    public let biosampleAccession: String?
    /// BioProject accession (e.g., "PRJNA168").
    public let bioprojectAccession: String?
    /// Total ungapped sequence length in base pairs.
    public let totalSequenceLength: String?
    /// Number of chromosomes in the assembly.
    public let chromosomeCount: String?
    /// Release type ("Major" or "Patch").
    public let releaseType: String?
    /// Organization that submitted the assembly.
    public let submitterOrganization: String?

    enum CodingKeys: String, CodingKey {
        case uid
        case assemblyAccession = "assemblyaccession"
        case assemblyName = "assemblyname"
        case organism
        case taxid
        case speciesName = "speciesname"
        case ftpPathRefSeq = "ftppath_refseq"
        case ftpPathGenBank = "ftppath_genbank"
        case submitter
        case coverage
        case contigN50 = "contig_n50"
        case scaffoldN50 = "scaffold_n50"
        case assemblyStatus = "assemblystatus"
        case assemblyLevel = "assemblylevel"
        case refseqCategory = "refseq_category"
        case biosampleAccession = "biosampleaccn"
        case bioprojectAccession = "bioprojectaccn"
        case totalSequenceLength = "total_length"
        case chromosomeCount = "chromosome_count"
        case releaseType = "releasetype"
        case submitterOrganization = "submitterorganization"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = try container.decode(String.self, forKey: .uid)
        assemblyAccession = try container.decodeIfPresent(String.self, forKey: .assemblyAccession)
        assemblyName = try container.decodeIfPresent(String.self, forKey: .assemblyName)
        organism = try container.decodeIfPresent(String.self, forKey: .organism)
        speciesName = try container.decodeIfPresent(String.self, forKey: .speciesName)
        ftpPathRefSeq = try container.decodeIfPresent(String.self, forKey: .ftpPathRefSeq).flatMap { $0.isEmpty ? nil : $0 }
        ftpPathGenBank = try container.decodeIfPresent(String.self, forKey: .ftpPathGenBank).flatMap { $0.isEmpty ? nil : $0 }
        submitter = try container.decodeIfPresent(String.self, forKey: .submitter)
        coverage = try container.decodeIfPresent(String.self, forKey: .coverage)

        // Handle taxid as either Int or String
        if let taxidInt = try? container.decodeIfPresent(Int.self, forKey: .taxid) {
            taxid = taxidInt
        } else if let taxidStr = try? container.decodeIfPresent(String.self, forKey: .taxid) {
            taxid = Int(taxidStr)
        } else {
            taxid = nil
        }

        // Handle contig_n50 as either Int or String
        if let n50Int = try? container.decodeIfPresent(Int.self, forKey: .contigN50) {
            contigN50 = n50Int
        } else if let n50Str = try? container.decodeIfPresent(String.self, forKey: .contigN50) {
            contigN50 = Int(n50Str)
        } else {
            contigN50 = nil
        }

        // Handle scaffold_n50 as either Int or String
        if let scaffoldInt = try? container.decodeIfPresent(Int.self, forKey: .scaffoldN50) {
            scaffoldN50 = scaffoldInt
        } else if let scaffoldStr = try? container.decodeIfPresent(String.self, forKey: .scaffoldN50) {
            scaffoldN50 = Int(scaffoldStr)
        } else {
            scaffoldN50 = nil
        }

        // Enriched metadata fields (all optional strings)
        assemblyStatus = try container.decodeIfPresent(String.self, forKey: .assemblyStatus)
        assemblyLevel = try container.decodeIfPresent(String.self, forKey: .assemblyLevel)
        refseqCategory = try container.decodeIfPresent(String.self, forKey: .refseqCategory)
        biosampleAccession = try container.decodeIfPresent(String.self, forKey: .biosampleAccession)
        bioprojectAccession = try container.decodeIfPresent(String.self, forKey: .bioprojectAccession)
        totalSequenceLength = try container.decodeIfPresent(String.self, forKey: .totalSequenceLength)
        chromosomeCount = try container.decodeIfPresent(String.self, forKey: .chromosomeCount)
        releaseType = try container.decodeIfPresent(String.self, forKey: .releaseType)
        submitterOrganization = try container.decodeIfPresent(String.self, forKey: .submitterOrganization)
    }
}

// MARK: - Datasets v2 Virus Response Models

/// Top-level response from the NCBI Datasets v2 virus dataset report endpoint.
public struct VirusDatasetReport: Codable, Sendable {
    public let reports: [VirusReport]
    public let totalCount: Int?
    public let nextPageToken: String?
    /// API error message (returned instead of reports when the request fails server-side).
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case reports
        case totalCount = "total_count"
        case nextPageToken = "next_page_token"
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.reports = (try? container.decode([VirusReport].self, forKey: .reports)) ?? []
        self.totalCount = try? container.decode(Int.self, forKey: .totalCount)
        self.nextPageToken = try? container.decode(String.self, forKey: .nextPageToken)
        self.error = try? container.decode(String.self, forKey: .error)
    }

    /// Fallback date formatter for dates without timezone info.
    static let looseDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

/// A single virus report from the Datasets v2 API.
public struct VirusReport: Codable, Sendable {
    public let accession: String?
    public let isAnnotated: Bool?
    public let isolate: VirusIsolate?
    public let sourceDatabase: String?
    public let proteinCount: Int?
    public let host: VirusHost?
    public let virus: VirusInfo?
    public let location: VirusLocation?
    public let completeness: String?
    public let length: Int?
    public let releaseDate: String?
    public let updateDate: String?
    public let biosample: String?
    public let bioprojects: [String]?
    public let purposeOfSampling: String?

    enum CodingKeys: String, CodingKey {
        case accession
        case isAnnotated = "is_annotated"
        case isolate
        case sourceDatabase = "source_database"
        case proteinCount = "protein_count"
        case host, virus, location, completeness, length
        case releaseDate = "release_date"
        case updateDate = "update_date"
        case biosample, bioprojects
        case purposeOfSampling = "purpose_of_sampling"
    }
}

/// Virus isolate information.
public struct VirusIsolate: Codable, Sendable {
    public let name: String?
    public let source: String?
    public let collectionDate: String?

    enum CodingKeys: String, CodingKey {
        case name, source
        case collectionDate = "collection_date"
    }
}

/// Virus host information.
public struct VirusHost: Codable, Sendable {
    public let taxId: Int?
    public let organismName: String?

    enum CodingKeys: String, CodingKey {
        case taxId = "tax_id"
        case organismName = "organism_name"
    }
}

/// Virus taxonomic information.
public struct VirusInfo: Codable, Sendable {
    public let taxId: Int?
    public let organismName: String?
    public let pangolinClassification: String?

    enum CodingKeys: String, CodingKey {
        case taxId = "tax_id"
        case organismName = "organism_name"
        case pangolinClassification = "pangolin_classification"
    }
}

/// Geographic location information.
public struct VirusLocation: Codable, Sendable {
    public let geographicLocation: String?
    public let geographicRegion: String?
    public let usaState: String?

    enum CodingKeys: String, CodingKey {
        case geographicLocation = "geographic_location"
        case geographicRegion = "geographic_region"
        case usaState = "usa_state"
    }
}
