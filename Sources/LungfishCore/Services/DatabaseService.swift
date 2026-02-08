// DatabaseService.swift - Base protocols for database integration
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Swift Architecture Lead (Role 01)

import Foundation

// MARK: - Database Service Protocol

/// Base protocol for all genomic database services.
///
/// This protocol defines the common interface for interacting with
/// biological sequence databases like NCBI, ENA, and Pathoplexus.
///
/// ## Conformance
/// Services should implement this protocol to enable unified access
/// to sequences from multiple databases through a consistent API.
public protocol DatabaseService: Sendable {
    /// The name of the database service.
    var name: String { get }

    /// The base URL for the service API.
    var baseURL: URL { get }

    /// Searches the database with the given query.
    ///
    /// - Parameter query: The search parameters
    /// - Returns: Search results containing matching records
    /// - Throws: `DatabaseServiceError` if the search fails
    func search(_ query: SearchQuery) async throws -> SearchResults

    /// Fetches a single record by accession number.
    ///
    /// - Parameter accession: The accession number to fetch
    /// - Returns: The database record
    /// - Throws: `DatabaseServiceError` if the fetch fails
    func fetch(accession: String) async throws -> DatabaseRecord

    /// Fetches multiple records as an async stream.
    ///
    /// - Parameter accessions: The accession numbers to fetch
    /// - Returns: An async stream of database records
    func fetchBatch(accessions: [String]) async throws -> AsyncThrowingStream<DatabaseRecord, Error>
}

// MARK: - Search Query

/// A unified search query that works across database services.
///
/// This struct provides a common interface for specifying search
/// parameters that can be translated to service-specific queries.
public struct SearchQuery: Sendable, Equatable {
    /// The search term (free text or accession)
    public var term: String

    /// Filter by organism name
    public var organism: String?

    /// Filter by collection date range
    public var dateRange: ClosedRange<Date>?

    /// Filter by geographic location
    public var location: String?

    /// Minimum sequence length
    public var minLength: Int?

    /// Maximum sequence length
    public var maxLength: Int?

    /// Maximum number of results to return
    public var limit: Int

    /// Starting offset for pagination
    public var offset: Int

    /// Creates a new search query.
    public init(
        term: String,
        organism: String? = nil,
        dateRange: ClosedRange<Date>? = nil,
        location: String? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        limit: Int = 100,
        offset: Int = 0
    ) {
        self.term = term
        self.organism = organism
        self.dateRange = dateRange
        self.location = location
        self.minLength = minLength
        self.maxLength = maxLength
        self.limit = limit
        self.offset = offset
    }
}

// MARK: - Search Results

/// Results from a database search operation.
public struct SearchResults: Sendable {
    /// Total number of matching records
    public let totalCount: Int

    /// Records returned in this batch
    public let records: [SearchResultRecord]

    /// Whether more results are available
    public let hasMore: Bool

    /// Cursor for fetching the next batch
    public let nextCursor: String?

    public init(
        totalCount: Int,
        records: [SearchResultRecord],
        hasMore: Bool = false,
        nextCursor: String? = nil
    ) {
        self.totalCount = totalCount
        self.records = records
        self.hasMore = hasMore
        self.nextCursor = nextCursor
    }

    /// Empty search results.
    public static let empty = SearchResults(totalCount: 0, records: [])
}

// MARK: - Search Result Record

/// A single record from search results.
///
/// This provides a summary of the record; use `fetch(accession:)` to
/// retrieve the complete record with sequence data.
public struct SearchResultRecord: Sendable, Identifiable, Equatable {
    /// Unique identifier for this record
    public let id: String

    /// Accession number
    public let accession: String

    /// Record title or description
    public let title: String

    /// Organism name
    public let organism: String?

    /// Sequence length
    public let length: Int?

    /// Collection or submission date
    public let date: Date?

    /// Source database
    public let source: DatabaseSource

    // MARK: - Virus-Specific Metadata

    /// Host organism (e.g., "Homo sapiens"). Populated by Datasets v2 virus searches.
    public let host: String?

    /// Geographic location (e.g., "USA: Minnesota"). Populated by Datasets v2 virus searches.
    public let geoLocation: String?

    /// Collection date as a string (e.g., "2026-01-20"). Populated by Datasets v2 virus searches.
    public let collectionDate: String?

    /// Sequence completeness (e.g., "COMPLETE", "PARTIAL"). Populated by Datasets v2 virus searches.
    public let completeness: String?

    /// Isolate name (e.g., "SARS-CoV-2/human/USA/MN-MDH-49571/2026").
    public let isolateName: String?

    /// Source database name (e.g., "GenBank", "RefSeq").
    public let sourceDatabase: String?

    /// Pangolin lineage classification (e.g., "XFG.14.1.1").
    public let pangolinClassification: String?

    public init(
        id: String,
        accession: String,
        title: String,
        organism: String? = nil,
        length: Int? = nil,
        date: Date? = nil,
        source: DatabaseSource,
        host: String? = nil,
        geoLocation: String? = nil,
        collectionDate: String? = nil,
        completeness: String? = nil,
        isolateName: String? = nil,
        sourceDatabase: String? = nil,
        pangolinClassification: String? = nil
    ) {
        self.id = id
        self.accession = accession
        self.title = title
        self.organism = organism
        self.length = length
        self.date = date
        self.source = source
        self.host = host
        self.geoLocation = geoLocation
        self.collectionDate = collectionDate
        self.completeness = completeness
        self.isolateName = isolateName
        self.sourceDatabase = sourceDatabase
        self.pangolinClassification = pangolinClassification
    }
}

// MARK: - Database Record

/// A complete record from a database including sequence data.
public struct DatabaseRecord: Sendable, Identifiable {
    /// Unique identifier
    public let id: String

    /// Accession number
    public let accession: String

    /// Version of the record
    public let version: String?

    /// Record title or definition
    public let title: String

    /// Organism name
    public let organism: String?

    /// Taxonomy ID
    public let taxonId: Int?

    /// The nucleotide or protein sequence
    public let sequence: String

    /// Sequence length
    public var length: Int { sequence.count }

    /// Annotations/features
    public let annotations: [SequenceAnnotation]

    /// Additional metadata
    public let metadata: [String: String]

    /// Source database
    public let source: DatabaseSource

    /// Collection date
    public let collectionDate: Date?

    /// Geographic location
    public let location: String?

    public init(
        id: String,
        accession: String,
        version: String? = nil,
        title: String,
        organism: String? = nil,
        taxonId: Int? = nil,
        sequence: String,
        annotations: [SequenceAnnotation] = [],
        metadata: [String: String] = [:],
        source: DatabaseSource,
        collectionDate: Date? = nil,
        location: String? = nil
    ) {
        self.id = id
        self.accession = accession
        self.version = version
        self.title = title
        self.organism = organism
        self.taxonId = taxonId
        self.sequence = sequence
        self.annotations = annotations
        self.metadata = metadata
        self.source = source
        self.collectionDate = collectionDate
        self.location = location
    }
}

// MARK: - Database Source

/// Identifies the source database for a record.
public enum DatabaseSource: String, Sendable, Codable, CaseIterable {
    case ncbi = "NCBI"
    case ena = "ENA"
    case ddbj = "DDBJ"
    case pathoplexus = "Pathoplexus"
    case local = "Local"

    /// Human-readable name for the database.
    public var displayName: String {
        switch self {
        case .ncbi: return "NCBI GenBank"
        case .ena: return "European Nucleotide Archive"
        case .ddbj: return "DNA Data Bank of Japan"
        case .pathoplexus: return "Pathoplexus"
        case .local: return "Local Database"
        }
    }

    /// URL to the database home page.
    public var homeURL: URL? {
        switch self {
        case .ncbi: return URL(string: "https://www.ncbi.nlm.nih.gov/")
        case .ena: return URL(string: "https://www.ebi.ac.uk/ena/browser/")
        case .ddbj: return URL(string: "https://www.ddbj.nig.ac.jp/")
        case .pathoplexus: return URL(string: "https://pathoplexus.org/")
        case .local: return nil
        }
    }
}

// MARK: - Database Service Error

/// Errors that can occur during database service operations.
public enum DatabaseServiceError: Error, LocalizedError, Sendable {
    case networkError(underlying: String)
    case invalidResponse(statusCode: Int)
    case parseError(message: String)
    case notFound(accession: String)
    case rateLimitExceeded
    case authenticationRequired
    case authenticationFailed(message: String)
    case invalidQuery(reason: String)
    case serverError(message: String)
    case timeout
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .networkError(let underlying):
            return "Network error: \(underlying)"
        case .invalidResponse(let statusCode):
            return "Invalid response from server (HTTP \(statusCode))"
        case .parseError(let message):
            return "Failed to parse response: \(message)"
        case .notFound(let accession):
            return "Record not found: \(accession)"
        case .rateLimitExceeded:
            return "Rate limit exceeded. Please wait before making more requests."
        case .authenticationRequired:
            return "Authentication required for this operation"
        case .authenticationFailed(let message):
            return "Authentication failed: \(message)"
        case .invalidQuery(let reason):
            return "Invalid query: \(reason)"
        case .serverError(let message):
            return "Server error: \(message)"
        case .timeout:
            return "Request timed out"
        case .cancelled:
            return "Request was cancelled"
        }
    }
}

// MARK: - HTTP Client Protocol

/// Protocol for making HTTP requests.
///
/// This allows injection of mock clients for testing.
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// Default HTTP client using URLSession.
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
