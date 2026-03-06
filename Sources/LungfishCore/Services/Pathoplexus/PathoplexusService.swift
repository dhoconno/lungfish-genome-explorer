// PathoplexusService.swift - Pathoplexus viral sequence database integration
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Product Fit Expert (Role 21) + NCBI Integration Lead (Role 12)

import Foundation

// MARK: - Pathoplexus Service

/// Service for accessing the Pathoplexus viral pathogen genomic database.
///
/// Pathoplexus is an open-source database for sharing viral pathogen genomic
/// sequences with support for both open and time-limited data sharing.
///
/// ## Features
/// - Browse and search sequences by organism
/// - Filter by location, date, length, and mutations
/// - Download aligned or unaligned sequences
/// - Submit new sequences with metadata
///
/// ## Usage
/// ```swift
/// let service = PathoplexusService()
///
/// // List available organisms
/// let organisms = try await service.listOrganisms()
///
/// // Search for sequences
/// let filters = PathoplexusFilters(geoLocCountry: "USA")
/// let results = try await service.search(organism: "mpox", filters: filters)
///
/// // Fetch sequences as FASTA
/// for try await record in try await service.fetchSequences(organism: "mpox", filters: filters) {
///     print(record.accession)
/// }
/// ```
public actor PathoplexusService: DatabaseService {

    // MARK: - Properties

    public nonisolated let name = "Pathoplexus"
    public nonisolated let baseURL = URL(string: "https://lapis.pathoplexus.org/")!
    public nonisolated let backendURL = URL(string: "https://backend.pathoplexus.org/")!
    public nonisolated let authURL = URL(string: "https://authentication.pathoplexus.org/")!

    private let httpClient: HTTPClient
    private var lastRequestTime: Date?

    // MARK: - Initialization

    /// Creates a new Pathoplexus service.
    ///
    /// - Parameter httpClient: HTTP client for making requests
    public init(httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    // MARK: - DatabaseService Protocol

    public func search(_ query: SearchQuery) async throws -> SearchResults {
        // Default to mpox if no organism specified
        let organism = query.organism ?? "mpox"

        var filters = PathoplexusFilters()
        filters.geoLocCountry = query.location
        filters.lengthFrom = query.minLength
        filters.lengthTo = query.maxLength

        if let dateRange = query.dateRange {
            filters.sampleCollectionDateFrom = dateRange.lowerBound
            filters.sampleCollectionDateTo = dateRange.upperBound
        }

        // If the term looks like an accession, search by accession
        if query.term.contains("LOC_") || query.term.contains(".") {
            filters.accession = query.term
        }

        return try await search(organism: organism, filters: filters, limit: query.limit, offset: query.offset)
    }

    /// Fetches metadata for a specific accession, returning the full PathoplexusMetadata
    /// including INSDC accession fields. Used by the download logic to determine
    /// whether to fetch from GenBank or download FASTA-only.
    public func fetchMetadataForAccession(
        organism: String,
        accession: String
    ) async throws -> PathoplexusMetadata? {
        var filters = PathoplexusFilters()
        filters.accession = accession
        let results = try await fetchMetadata(organism: organism, filters: filters, limit: 1)
        return results.first
    }

    public func fetch(accession: String) async throws -> DatabaseRecord {
        // Parse organism from accession if possible (e.g., "LOC_MPOX_...")
        let organism = parseOrganismFromAccession(accession) ?? "mpox"

        var filters = PathoplexusFilters()
        filters.accession = accession

        // Get metadata
        let metadata = try await fetchMetadata(organism: organism, filters: filters)

        guard let meta = metadata.first else {
            throw DatabaseServiceError.notFound(accession: accession)
        }

        // Get sequence
        let sequenceFilters = filters
        let sequences = try await fetchUnalignedSequencesRaw(organism: organism, filters: sequenceFilters)

        // Parse FASTA
        let sequenceLines = sequences.components(separatedBy: "\n")
        var sequence = ""
        for line in sequenceLines {
            if !line.hasPrefix(">") {
                sequence += line.uppercased()
            }
        }

        return DatabaseRecord(
            id: accession,
            accession: meta.accession,
            version: meta.accessionVersion,
            title: "\(meta.organism ?? organism) sequence \(accession)",
            organism: meta.organism,
            sequence: sequence,
            metadata: [
                "geoLocCountry": meta.geoLocCountry ?? "",
                "sampleCollectionDate": meta.sampleCollectionDate ?? "",
                "submittingLab": meta.submittingLab ?? ""
            ],
            source: .pathoplexus,
            collectionDate: meta.collectionDate,
            location: meta.geoLocCountry
        )
    }

    public nonisolated func fetchBatch(accessions: [String]) async throws -> AsyncThrowingStream<DatabaseRecord, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    for accession in accessions {
                        let record = try await self.fetch(accession: accession)
                        continuation.yield(record)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Pathoplexus-Specific Methods

    /// Lists all available organisms in Pathoplexus.
    ///
    /// - Returns: Array of organisms
    public func listOrganisms() async throws -> [PathoplexusOrganism] {
        // Currently known organisms in Pathoplexus
        return [
            PathoplexusOrganism(id: "cchf", displayName: "Crimean-Congo hemorrhagic fever", segmented: true, segments: ["S", "M", "L"]),
            PathoplexusOrganism(id: "ebola-sudan", displayName: "Sudan ebolavirus", segmented: false, segments: nil),
            PathoplexusOrganism(id: "ebola-zaire", displayName: "Zaire ebolavirus", segmented: false, segments: nil),
            PathoplexusOrganism(id: "hmpv", displayName: "Human metapneumovirus", segmented: false, segments: nil),
            PathoplexusOrganism(id: "marburg", displayName: "Marburg virus", segmented: false, segments: nil),
            PathoplexusOrganism(id: "measles", displayName: "Measles virus", segmented: false, segments: nil),
            PathoplexusOrganism(id: "mpox", displayName: "Mpox virus", segmented: false, segments: nil),
            PathoplexusOrganism(id: "rsv-a", displayName: "RSV-A", segmented: false, segments: nil),
            PathoplexusOrganism(id: "rsv-b", displayName: "RSV-B", segmented: false, segments: nil),
            PathoplexusOrganism(id: "west-nile", displayName: "West Nile virus", segmented: false, segments: nil)
        ]
    }

    /// Searches for sequences in Pathoplexus.
    ///
    /// - Parameters:
    ///   - organism: The organism to search
    ///   - filters: Search filters
    ///   - limit: Maximum results
    ///   - offset: Pagination offset
    /// - Returns: Search results
    public func search(
        organism: String,
        filters: PathoplexusFilters = PathoplexusFilters(),
        limit: Int = 100,
        offset: Int = 0
    ) async throws -> SearchResults {
        // First get the count
        let count = try await getAggregatedCount(organism: organism, filters: filters)

        // Then get metadata
        let metadata = try await fetchMetadata(organism: organism, filters: filters, limit: limit, offset: offset)

        let records = metadata.map { meta in
            // Build a descriptive title
            var titleParts: [String] = []
            titleParts.append(meta.organism ?? organism)
            if let country = meta.geoLocCountry, !country.isEmpty {
                titleParts.append(country)
            }
            if let clade = meta.clade, !clade.isEmpty {
                titleParts.append("Clade: \(clade)")
            }
            let title = titleParts.joined(separator: " - ")

            // Build host display string
            let hostDisplay: String? = meta.hostNameScientific ?? meta.hostNameCommon

            // Determine source database tag (INSDC vs Pathoplexus-only)
            let sourceDB: String? = meta.hasINSDCAccession ? "INSDC" : nil

            return SearchResultRecord(
                id: meta.accession,
                accession: meta.accession,
                title: title,
                organism: meta.organism,
                length: meta.length,
                date: meta.collectionDate,
                source: .pathoplexus,
                host: hostDisplay,
                geoLocation: meta.geoLocCountry,
                collectionDate: meta.sampleCollectionDate,
                sourceDatabase: sourceDB,
                pangolinClassification: meta.lineage
            )
        }

        return SearchResults(
            totalCount: count,
            records: records,
            hasMore: offset + records.count < count,
            nextCursor: String(offset + records.count)
        )
    }

    /// Gets the count of sequences matching filters.
    ///
    /// - Parameters:
    ///   - organism: The organism
    ///   - filters: Search filters
    /// - Returns: Count of matching sequences
    public func getAggregatedCount(
        organism: String,
        filters: PathoplexusFilters = PathoplexusFilters()
    ) async throws -> Int {
        let url = buildLAPISURL(organism: organism, endpoint: "aggregated", filters: filters)
        let data = try await makeRequest(url: url)

        let response = try JSONDecoder().decode(LAPISAggregatedResponse.self, from: data)
        return response.data.first?.count ?? 0
    }

    /// Fetches sequence metadata.
    ///
    /// - Parameters:
    ///   - organism: The organism
    ///   - filters: Search filters
    ///   - limit: Maximum results
    ///   - offset: Pagination offset
    /// - Returns: Array of metadata records
    public func fetchMetadata(
        organism: String,
        filters: PathoplexusFilters = PathoplexusFilters(),
        limit: Int = 100,
        offset: Int = 0
    ) async throws -> [PathoplexusMetadata] {
        var url = buildLAPISURL(organism: organism, endpoint: "details", filters: filters)

        // Add pagination
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset))
        ]
        url = components.url!

        let data = try await makeRequest(url: url)

        let response = try JSONDecoder().decode(LAPISDetailsResponse.self, from: data)
        return response.data
    }

    /// Fetches aligned sequences in FASTA format.
    ///
    /// - Parameters:
    ///   - organism: The organism
    ///   - filters: Search filters
    ///   - segment: For segmented viruses, the segment to fetch
    /// - Returns: Async stream of FASTA records
    public func fetchSequences(
        organism: String,
        filters: PathoplexusFilters = PathoplexusFilters(),
        segment: String? = nil,
        aligned: Bool = false
    ) async throws -> AsyncThrowingStream<FASTARecord, Error> {
        let endpoint = aligned ? "alignedNucleotideSequences" : "unalignedNucleotideSequences"
        let url = buildLAPISURL(organism: organism, endpoint: endpoint, filters: filters, segment: segment)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let fasta = try await self.makeRequestString(url: url)
                    let records = self.parseFASTA(fasta)
                    for record in records {
                        continuation.yield(record)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private Methods

    private func fetchUnalignedSequencesRaw(
        organism: String,
        filters: PathoplexusFilters
    ) async throws -> String {
        let url = buildLAPISURL(organism: organism, endpoint: "unalignedNucleotideSequences", filters: filters)
        return try await makeRequestString(url: url)
    }

    private func buildLAPISURL(
        organism: String,
        endpoint: String,
        filters: PathoplexusFilters = PathoplexusFilters(),
        segment: String? = nil
    ) -> URL {
        var path = "\(organism)/sample/\(endpoint)"
        if let seg = segment {
            path = "\(organism)/sample/\(endpoint)/\(seg)"
        }

        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = []

        if let accession = filters.accession {
            queryItems.append(URLQueryItem(name: "accession", value: accession))
        }
        if let country = filters.geoLocCountry {
            queryItems.append(URLQueryItem(name: "geoLocCountry", value: country))
        }
        if let dateFrom = filters.sampleCollectionDateFrom {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            queryItems.append(URLQueryItem(name: "sampleCollectionDateFrom", value: formatter.string(from: dateFrom)))
        }
        if let dateTo = filters.sampleCollectionDateTo {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            queryItems.append(URLQueryItem(name: "sampleCollectionDateTo", value: formatter.string(from: dateTo)))
        }
        if let lengthFrom = filters.lengthFrom {
            queryItems.append(URLQueryItem(name: "lengthFrom", value: String(lengthFrom)))
        }
        if let lengthTo = filters.lengthTo {
            queryItems.append(URLQueryItem(name: "lengthTo", value: String(lengthTo)))
        }
        if let mutations = filters.nucleotideMutations, !mutations.isEmpty {
            queryItems.append(URLQueryItem(name: "nucleotideMutations", value: mutations.joined(separator: ",")))
        }
        if let mutations = filters.aminoAcidMutations, !mutations.isEmpty {
            queryItems.append(URLQueryItem(name: "aminoAcidMutations", value: mutations.joined(separator: ",")))
        }
        if let status = filters.versionStatus {
            queryItems.append(URLQueryItem(name: "versionStatus", value: status.rawValue))
        }
        if let clade = filters.clade, !clade.isEmpty {
            queryItems.append(URLQueryItem(name: "clade", value: clade))
        }
        if let lineage = filters.lineage, !lineage.isEmpty {
            queryItems.append(URLQueryItem(name: "lineage", value: lineage))
        }
        if let host = filters.hostNameScientific, !host.isEmpty {
            queryItems.append(URLQueryItem(name: "hostNameScientific", value: host))
        }
        if let terms = filters.dataUseTerms {
            queryItems.append(URLQueryItem(name: "dataUseTerms", value: terms.rawValue))
        }

        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        return components.url!
    }

    private func makeRequest(url: URL) async throws -> Data {
        // Rate limiting (be conservative)
        if let lastTime = lastRequestTime {
            let elapsed = Date().timeIntervalSince(lastTime)
            if elapsed < 0.1 {
                try await Task.sleep(nanoseconds: UInt64((0.1 - elapsed) * 1_000_000_000))
            }
        }
        lastRequestTime = Date()

        var request = URLRequest(url: url)
        request.setValue("Lungfish Genome Explorer", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60

        let (data, response) = try await httpClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DatabaseServiceError.networkError(underlying: "Invalid response type")
        }

        switch httpResponse.statusCode {
        case 200...299:
            return data
        case 400:
            throw DatabaseServiceError.invalidQuery(reason: "Bad request")
        case 404:
            throw DatabaseServiceError.notFound(accession: url.absoluteString)
        case 429:
            throw DatabaseServiceError.rateLimitExceeded
        case 500...599:
            throw DatabaseServiceError.serverError(message: "HTTP \(httpResponse.statusCode)")
        default:
            throw DatabaseServiceError.invalidResponse(statusCode: httpResponse.statusCode)
        }
    }

    private func makeRequestString(url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("Lungfish Genome Explorer", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        let (data, response) = try await httpClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DatabaseServiceError.networkError(underlying: "Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            throw DatabaseServiceError.invalidResponse(statusCode: httpResponse.statusCode)
        }

        guard let string = String(data: data, encoding: .utf8) else {
            throw DatabaseServiceError.parseError(message: "Invalid encoding")
        }

        return string
    }

    private func parseOrganismFromAccession(_ accession: String) -> String? {
        let parts = accession.uppercased().components(separatedBy: "_")
        guard parts.count >= 2 else { return nil }

        let mapping: [String: String] = [
            "MPOX": "mpox",
            "EBOLA": "ebola-zaire",
            "SUDAN": "ebola-sudan",
            "MARBURG": "marburg",
            "RSV": "rsv-a",
            "MEASLES": "measles",
            "HMPV": "hmpv",
            "WNV": "west-nile",
            "CCHF": "cchf"
        ]

        for part in parts {
            if let organism = mapping[part] {
                return organism
            }
        }

        return nil
    }

    private func parseFASTA(_ content: String) -> [FASTARecord] {
        var records: [FASTARecord] = []
        var currentHeader: String?
        var currentSequence = ""

        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix(">") {
                if let header = currentHeader, !currentSequence.isEmpty {
                    records.append(FASTARecord(header: header, sequence: currentSequence.uppercased()))
                }
                currentHeader = String(line.dropFirst())
                currentSequence = ""
            } else {
                currentSequence += line.trimmingCharacters(in: .whitespaces)
            }
        }

        if let header = currentHeader, !currentSequence.isEmpty {
            records.append(FASTARecord(header: header, sequence: currentSequence.uppercased()))
        }

        return records
    }
}

// MARK: - LAPIS Response Types

struct LAPISAggregatedResponse: Codable {
    let data: [LAPISAggregatedData]
}

struct LAPISAggregatedData: Codable {
    let count: Int
}

struct LAPISDetailsResponse: Codable {
    let data: [PathoplexusMetadata]
}

// MARK: - FASTA Record

/// A parsed FASTA record.
public struct FASTARecord: Sendable {
    /// The header line (without the > prefix)
    public let header: String

    /// The sequence
    public let sequence: String

    /// Parses the accession from the header.
    public var accession: String {
        header.components(separatedBy: .whitespaces).first ?? header
    }
}
