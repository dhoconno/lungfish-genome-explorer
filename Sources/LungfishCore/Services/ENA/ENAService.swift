// ENAService.swift - European Nucleotide Archive integration
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: ENA Integration Specialist (Role 13)

import Foundation

// MARK: - ENA Service

/// Service for accessing the European Nucleotide Archive.
///
/// This service provides programmatic access to ENA's sequence and read data
/// via the Portal API and Browser API. It is particularly useful for:
/// - Searching for SRA/read data with direct FASTQ download URLs
/// - Downloading FASTQ files without SRA toolkit conversion
///
/// ## Usage
/// ```swift
/// let service = ENAService()
///
/// // Search for SRA reads
/// let results = try await service.searchReads(term: "SARS-CoV-2")
///
/// // Get FASTQ download URLs
/// for read in results.records {
///     if let urls = read.fastqURLs {
///         print("FASTQ: \(urls)")
///     }
/// }
/// ```
///
/// ## Rate Limiting
/// ENA allows 50 requests/second. This service throttles accordingly.
public actor ENAService: DatabaseService {

    // MARK: - Properties

    public nonisolated let name = "ENA"
    public nonisolated let baseURL = URL(string: "https://www.ebi.ac.uk/ena/browser/api/")!
    private let portalURL = URL(string: "https://www.ebi.ac.uk/ena/portal/api/")!

    private let httpClient: HTTPClient
    private var lastRequestTime: Date?
    private let minRequestInterval: TimeInterval = 0.02  // 50 requests/second

    // MARK: - Initialization

    /// Creates a new ENA service.
    ///
    /// - Parameter httpClient: HTTP client for making requests
    public init(httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    // MARK: - DatabaseService Protocol

    public func search(_ query: SearchQuery) async throws -> SearchResults {
        var queryParts: [String] = []

        if !query.term.isEmpty {
            queryParts.append("description=\"*\(query.term)*\"")
        }

        if let organism = query.organism {
            queryParts.append("tax_tree(\"\(organism)\")")
        }

        if let minLen = query.minLength {
            queryParts.append("base_count>=\(minLen)")
        }

        if let maxLen = query.maxLength {
            queryParts.append("base_count<=\(maxLen)")
        }

        let queryString = queryParts.isEmpty ? "*" : queryParts.joined(separator: " AND ")

        var components = URLComponents(url: portalURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "query", value: queryString),
            URLQueryItem(name: "result", value: "sequence"),
            URLQueryItem(name: "fields", value: "accession,description,tax_id,scientific_name,base_count,first_public"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: String(query.limit)),
            URLQueryItem(name: "offset", value: String(query.offset))
        ]

        let data = try await makeRequest(url: components.url!)

        let records = try JSONDecoder().decode([ENASearchRecord].self, from: data)

        let searchResults = records.map { record in
            SearchResultRecord(
                id: record.accession,
                accession: record.accession,
                title: record.description ?? "No description",
                organism: record.scientificName,
                length: record.baseCount,
                date: record.firstPublic,
                source: .ena
            )
        }

        return SearchResults(
            totalCount: searchResults.count,
            records: searchResults,
            hasMore: searchResults.count == query.limit,
            nextCursor: String(query.offset + searchResults.count)
        )
    }

    public func fetch(accession: String) async throws -> DatabaseRecord {
        // Fetch FASTA
        let fastaData = try await fetchFASTA(accession: accession)

        // Parse FASTA header and sequence
        let lines = fastaData.components(separatedBy: "\n")
        guard let headerLine = lines.first, headerLine.hasPrefix(">") else {
            throw DatabaseServiceError.parseError(message: "Invalid FASTA format")
        }

        let header = String(headerLine.dropFirst())
        let sequence = lines.dropFirst().joined().uppercased()

        // Parse header for metadata
        let headerParts = header.components(separatedBy: " ")
        let accessionPart = headerParts.first ?? accession
        let title = headerParts.dropFirst().joined(separator: " ")

        return DatabaseRecord(
            id: accession,
            accession: accessionPart,
            title: title.isEmpty ? accession : title,
            sequence: sequence,
            source: .ena
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

    // MARK: - ENA-Specific Methods

    /// Fetches a sequence in FASTA format.
    ///
    /// - Parameter accession: The accession number
    /// - Returns: FASTA-formatted sequence
    public func fetchFASTA(accession: String) async throws -> String {
        let url = baseURL.appendingPathComponent("fasta/\(accession)")
        let data = try await makeRequest(url: url)

        guard let fasta = String(data: data, encoding: .utf8) else {
            throw DatabaseServiceError.parseError(message: "Invalid FASTA encoding")
        }

        return fasta
    }

    /// Fetches a sequence in EMBL format.
    ///
    /// - Parameter accession: The accession number
    /// - Returns: EMBL-formatted sequence
    public func fetchEMBL(accession: String) async throws -> String {
        let url = baseURL.appendingPathComponent("embl/\(accession)")
        let data = try await makeRequest(url: url)

        guard let embl = String(data: data, encoding: .utf8) else {
            throw DatabaseServiceError.parseError(message: "Invalid EMBL encoding")
        }

        return embl
    }

    /// Fetches sequence metadata as XML.
    ///
    /// - Parameter accession: The accession number
    /// - Returns: XML metadata
    public func fetchXML(accession: String) async throws -> String {
        let url = baseURL.appendingPathComponent("xml/\(accession)")
        let data = try await makeRequest(url: url)

        guard let xml = String(data: data, encoding: .utf8) else {
            throw DatabaseServiceError.parseError(message: "Invalid XML encoding")
        }

        return xml
    }

    // MARK: - SRA/Read Data Methods

    /// Searches for SRA read run data with FASTQ download URLs.
    ///
    /// This is the primary method for finding sequencing read data that can be
    /// downloaded directly as FASTQ files without needing the SRA toolkit.
    ///
    /// - Parameters:
    ///   - term: Search term (accession, study ID, or description)
    ///   - limit: Maximum results to return
    ///   - offset: Starting offset for pagination
    /// - Returns: Search results with FASTQ URLs included
    public func searchReads(term: String, limit: Int = 100, offset: Int = 0) async throws -> [ENAReadRecord] {
        var components = URLComponents(url: portalURL.appendingPathComponent("filereport"), resolvingAgainstBaseURL: false)!

        // Use filereport endpoint for faster, cached access with FASTQ URLs
        components.queryItems = [
            URLQueryItem(name: "accession", value: term),
            URLQueryItem(name: "result", value: "read_run"),
            URLQueryItem(name: "fields", value: "run_accession,experiment_accession,sample_accession,study_accession,experiment_title,library_layout,library_source,library_strategy,instrument_platform,base_count,read_count,fastq_ftp,fastq_bytes,fastq_md5,first_public"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset))
        ]

        let data = try await makeRequest(url: components.url!)

        // Handle empty response (no results)
        if data.isEmpty {
            return []
        }

        // Try to decode as array, handle potential empty array
        do {
            return try JSONDecoder().decode([ENAReadRecord].self, from: data)
        } catch {
            // Check if it's an error response
            if let errorText = String(data: data, encoding: .utf8),
               errorText.contains("No results") || errorText.contains("error") {
                return []
            }
            throw DatabaseServiceError.parseError(message: "Failed to parse read data: \(error.localizedDescription)")
        }
    }

    /// Searches for read runs by study/project accession.
    ///
    /// - Parameters:
    ///   - study: Study accession (PRJNA*, PRJEB*, SRP*, ERP*)
    ///   - limit: Maximum results
    /// - Returns: Array of read records
    public func searchReadsByStudy(study: String, limit: Int = 100) async throws -> [ENAReadRecord] {
        var components = URLComponents(url: portalURL.appendingPathComponent("filereport"), resolvingAgainstBaseURL: false)!

        components.queryItems = [
            URLQueryItem(name: "accession", value: study),
            URLQueryItem(name: "result", value: "read_run"),
            URLQueryItem(name: "fields", value: "run_accession,experiment_accession,sample_accession,study_accession,experiment_title,library_layout,library_source,library_strategy,instrument_platform,base_count,read_count,fastq_ftp,fastq_bytes,fastq_md5,first_public"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        let data = try await makeRequest(url: components.url!)

        if data.isEmpty {
            return []
        }

        do {
            return try JSONDecoder().decode([ENAReadRecord].self, from: data)
        } catch {
            if let errorText = String(data: data, encoding: .utf8),
               errorText.contains("No results") {
                return []
            }
            throw DatabaseServiceError.parseError(message: "Failed to parse read data: \(error.localizedDescription)")
        }
    }

    /// Gets the direct HTTPS URLs for FASTQ download.
    ///
    /// ENA provides FTP URLs by default; this converts them to HTTPS for download.
    ///
    /// - Parameter record: The read record containing FTP paths
    /// - Returns: HTTPS URLs for FASTQ files
    public func fastqHTTPURLs(for record: ENAReadRecord) -> [URL] {
        guard let ftpPaths = record.fastqFTP else { return [] }

        return ftpPaths.components(separatedBy: ";").compactMap { ftpPath in
            // Convert FTP path to HTTPS URL (HTTPS required by App Transport Security)
            // ftp.sra.ebi.ac.uk/vol1/fastq/... -> https://ftp.sra.ebi.ac.uk/vol1/fastq/...
            let httpPath = "https://\(ftpPath)"
            return URL(string: httpPath)
        }
    }

    // MARK: - Private Methods

    private func makeRequest(url: URL) async throws -> Data {
        // Rate limiting
        if let lastTime = lastRequestTime {
            let elapsed = Date().timeIntervalSince(lastTime)
            if elapsed < minRequestInterval {
                try await Task.sleep(nanoseconds: UInt64((minRequestInterval - elapsed) * 1_000_000_000))
            }
        }
        lastRequestTime = Date()

        var request = URLRequest(url: url)
        request.setValue("Lungfish Genome Browser", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let (data, response) = try await httpClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DatabaseServiceError.networkError(underlying: "Invalid response type")
        }

        switch httpResponse.statusCode {
        case 200...299:
            return data
        case 400:
            let body = String(data: data, encoding: .utf8) ?? ""
            let detail = body.isEmpty ? url.absoluteString : "\(body.prefix(200)) (URL: \(url.absoluteString))"
            throw DatabaseServiceError.invalidQuery(reason: detail)
        case 404:
            throw DatabaseServiceError.notFound(accession: url.lastPathComponent)
        case 429:
            throw DatabaseServiceError.rateLimitExceeded
        case 500...599:
            let body = String(data: data, encoding: .utf8) ?? ""
            let detail = body.isEmpty ? "HTTP \(httpResponse.statusCode)" : "HTTP \(httpResponse.statusCode): \(body.prefix(200))"
            throw DatabaseServiceError.serverError(message: detail)
        default:
            throw DatabaseServiceError.invalidResponse(statusCode: httpResponse.statusCode)
        }
    }
}

// MARK: - ENA Search Record

/// A record from ENA Portal API search.
struct ENASearchRecord: Codable {
    let accession: String
    let description: String?
    let taxId: Int?
    let scientificName: String?
    let baseCount: Int?
    let firstPublic: Date?

    enum CodingKeys: String, CodingKey {
        case accession
        case description
        case taxId = "tax_id"
        case scientificName = "scientific_name"
        case baseCount = "base_count"
        case firstPublic = "first_public"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accession = try container.decode(String.self, forKey: .accession)
        description = try container.decodeIfPresent(String.self, forKey: .description)

        // Handle both string and int for tax_id
        if let taxIdInt = try? container.decodeIfPresent(Int.self, forKey: .taxId) {
            taxId = taxIdInt
        } else if let taxIdStr = try? container.decodeIfPresent(String.self, forKey: .taxId) {
            taxId = Int(taxIdStr)
        } else {
            taxId = nil
        }

        scientificName = try container.decodeIfPresent(String.self, forKey: .scientificName)

        // Handle both string and int for base_count
        if let countInt = try? container.decodeIfPresent(Int.self, forKey: .baseCount) {
            baseCount = countInt
        } else if let countStr = try? container.decodeIfPresent(String.self, forKey: .baseCount) {
            baseCount = Int(countStr)
        } else {
            baseCount = nil
        }

        // Parse date
        if let dateStr = try container.decodeIfPresent(String.self, forKey: .firstPublic) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            firstPublic = formatter.date(from: dateStr)
        } else {
            firstPublic = nil
        }
    }
}

// MARK: - ENA Read Record

/// A record from ENA Portal API for read/SRA data with FASTQ URLs.
public struct ENAReadRecord: Codable, Sendable {
    public let runAccession: String
    public let experimentAccession: String?
    public let sampleAccession: String?
    public let studyAccession: String?
    public let experimentTitle: String?
    public let libraryLayout: String?  // SINGLE or PAIRED
    public let librarySource: String?  // GENOMIC, TRANSCRIPTOMIC, etc.
    public let libraryStrategy: String?  // WGS, RNA-Seq, etc.
    public let instrumentPlatform: String?  // ILLUMINA, etc.
    public let baseCount: Int?
    public let readCount: Int?
    public let fastqFTP: String?  // Semicolon-separated FTP paths
    public let fastqBytes: String?  // Semicolon-separated file sizes
    public let fastqMD5: String?  // Semicolon-separated MD5 checksums
    public let firstPublic: Date?

    enum CodingKeys: String, CodingKey {
        case runAccession = "run_accession"
        case experimentAccession = "experiment_accession"
        case sampleAccession = "sample_accession"
        case studyAccession = "study_accession"
        case experimentTitle = "experiment_title"
        case libraryLayout = "library_layout"
        case librarySource = "library_source"
        case libraryStrategy = "library_strategy"
        case instrumentPlatform = "instrument_platform"
        case baseCount = "base_count"
        case readCount = "read_count"
        case fastqFTP = "fastq_ftp"
        case fastqBytes = "fastq_bytes"
        case fastqMD5 = "fastq_md5"
        case firstPublic = "first_public"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runAccession = try container.decode(String.self, forKey: .runAccession)
        experimentAccession = try container.decodeIfPresent(String.self, forKey: .experimentAccession)
        sampleAccession = try container.decodeIfPresent(String.self, forKey: .sampleAccession)
        studyAccession = try container.decodeIfPresent(String.self, forKey: .studyAccession)
        experimentTitle = try container.decodeIfPresent(String.self, forKey: .experimentTitle)
        libraryLayout = try container.decodeIfPresent(String.self, forKey: .libraryLayout)
        librarySource = try container.decodeIfPresent(String.self, forKey: .librarySource)
        libraryStrategy = try container.decodeIfPresent(String.self, forKey: .libraryStrategy)
        instrumentPlatform = try container.decodeIfPresent(String.self, forKey: .instrumentPlatform)
        fastqFTP = try container.decodeIfPresent(String.self, forKey: .fastqFTP)
        fastqBytes = try container.decodeIfPresent(String.self, forKey: .fastqBytes)
        fastqMD5 = try container.decodeIfPresent(String.self, forKey: .fastqMD5)

        // Handle base_count as either Int or String
        if let countInt = try? container.decodeIfPresent(Int.self, forKey: .baseCount) {
            baseCount = countInt
        } else if let countStr = try? container.decodeIfPresent(String.self, forKey: .baseCount) {
            baseCount = Int(countStr)
        } else {
            baseCount = nil
        }

        // Handle read_count as either Int or String
        if let countInt = try? container.decodeIfPresent(Int.self, forKey: .readCount) {
            readCount = countInt
        } else if let countStr = try? container.decodeIfPresent(String.self, forKey: .readCount) {
            readCount = Int(countStr)
        } else {
            readCount = nil
        }

        // Parse date
        if let dateStr = try container.decodeIfPresent(String.self, forKey: .firstPublic) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            firstPublic = formatter.date(from: dateStr)
        } else {
            firstPublic = nil
        }
    }

    /// Whether this is paired-end sequencing data.
    public var isPaired: Bool {
        libraryLayout?.uppercased() == "PAIRED"
    }

    /// Total file size in bytes (sum of all FASTQ files).
    public var totalFileSizeBytes: Int? {
        guard let bytesStr = fastqBytes else { return nil }
        let sizes = bytesStr.components(separatedBy: ";").compactMap { Int($0) }
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }

    /// Formatted total file size (e.g., "125.3 MB").
    public var formattedFileSize: String? {
        guard let bytes = totalFileSizeBytes else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// HTTPS URLs for FASTQ download (converted from FTP).
    public var fastqHTTPURLs: [URL] {
        guard let ftpPaths = fastqFTP else { return [] }
        return ftpPaths.components(separatedBy: ";").compactMap { ftpPath in
            let httpPath = "https://\(ftpPath)"
            return URL(string: httpPath)
        }
    }
}
