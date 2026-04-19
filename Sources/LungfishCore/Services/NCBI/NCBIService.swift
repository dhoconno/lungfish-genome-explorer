// NCBIService.swift - NCBI Entrez E-utilities integration
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: NCBI Integration Lead (Role 12)

import Foundation
import os.log

/// Logger for NCBI service operations
private let logger = Logger(subsystem: LogSubsystem.core, category: "NCBIService")

// MARK: - NCBI Service

/// Service for accessing NCBI databases via Entrez E-utilities.
///
/// This service provides programmatic access to NCBI's databases including
/// GenBank (nucleotide), protein, SRA, and more.
///
/// ## Usage
/// ```swift
/// let service = NCBIService()
///
/// // Search for sequences
/// let results = try await service.esearch(
///     database: .nucleotide,
///     term: "Ebola virus[Organism]",
///     retmax: 10
/// )
///
/// // Fetch sequences
/// let data = try await service.efetch(
///     database: .nucleotide,
///     ids: results,
///     format: .fasta
/// )
/// ```
///
/// ## Rate Limiting
/// NCBI allows 3 requests/second without an API key, or 10/second with one.
/// This service automatically throttles requests to comply.
public actor NCBIService: DatabaseService {

    // MARK: - Properties

    public nonisolated let name = "NCBI"
    public nonisolated let baseURL = URL(string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/")!

    private let httpClient: HTTPClient
    private let apiKey: String?
    private var lastRequestTime: Date?
    private let minRequestInterval: TimeInterval

    // MARK: - Initialization

    /// Creates a new NCBI service.
    ///
    /// - Parameters:
    ///   - apiKey: Optional NCBI API key for higher rate limits
    ///   - httpClient: HTTP client for making requests (defaults to URLSession)
    public init(apiKey: String? = nil, httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.apiKey = apiKey
        self.httpClient = httpClient
        // 3 requests/second without key, 10/second with key
        self.minRequestInterval = apiKey != nil ? 0.1 : 0.34
    }

    // MARK: - DatabaseService Protocol

    public func search(_ query: SearchQuery) async throws -> SearchResults {
        // Build NCBI search term
        var terms: [String] = []
        terms.append(query.term)

        if let organism = query.organism {
            terms.append("\(organism)[Organism]")
        }

        if let minLen = query.minLength {
            terms.append("\(minLen):*[Sequence Length]")
        }

        let term = terms.joined(separator: " AND ")

        logger.info("NCBIService.search: Final search term='\(term, privacy: .public)'")
        logger.info("NCBIService.search: limit=\(query.limit), offset=\(query.offset)")

        // Use esearchWithCount to get actual total count from NCBI
        let searchResult = try await esearchWithCount(
            database: .nucleotide,
            term: term,
            retmax: query.limit,
            retstart: query.offset
        )

        logger.info("NCBIService.search: esearch returned \(searchResult.totalCount) total, \(searchResult.ids.count) IDs")

        guard !searchResult.ids.isEmpty else {
            // Return empty but with the total count (may be 0)
            logger.info("NCBIService.search: No results found")
            return SearchResults(
                totalCount: searchResult.totalCount,
                records: [],
                hasMore: false,
                nextCursor: nil
            )
        }

        // Get summaries for the results
        let summaries = try await esummary(database: .nucleotide, ids: searchResult.ids)
        logger.info("NCBIService.search: Retrieved \(summaries.count) summaries")

        let records = summaries.map { summary in
            SearchResultRecord(
                id: summary.uid,
                accession: summary.accessionVersion ?? summary.uid,
                title: summary.title ?? "Unknown",
                organism: summary.organism,
                length: summary.length,
                date: summary.createDate,
                source: .ncbi
            )
        }

        // Use actual total count from NCBI, not just the returned count
        let hasMore = searchResult.totalCount > (query.offset + records.count)

        return SearchResults(
            totalCount: searchResult.totalCount,
            records: records,
            hasMore: hasMore,
            nextCursor: hasMore ? String(query.offset + records.count) : nil
        )
    }

    public func fetch(accession: String) async throws -> DatabaseRecord {
        // First search to get the UID
        let ids = try await esearch(
            database: .nucleotide,
            term: accession,
            retmax: 1
        )

        guard let uid = ids.first else {
            throw DatabaseServiceError.notFound(accession: accession)
        }

        // Fetch the GenBank record
        let data = try await efetch(
            database: .nucleotide,
            ids: [uid],
            format: .genbank
        )

        // Parse GenBank format
        guard let content = String(data: data, encoding: .utf8) else {
            throw DatabaseServiceError.parseError(message: "Invalid GenBank data encoding")
        }

        return try parseGenBankRecord(content, uid: uid)
    }

    /// Fetches raw GenBank format data for an accession.
    ///
    /// This method returns the complete GenBank file content without parsing,
    /// preserving all annotations, features, and metadata in the original format.
    ///
    /// - Parameter accession: The accession number to fetch
    /// - Returns: A tuple containing the raw GenBank content and the resolved accession
    /// - Throws: `DatabaseServiceError` if the fetch fails
    public func fetchRawGenBank(accession: String) async throws -> (content: String, accession: String) {
        // First search to get the UID
        let ids = try await esearch(
            database: .nucleotide,
            term: accession,
            retmax: 1
        )

        guard let uid = ids.first else {
            throw DatabaseServiceError.notFound(accession: accession)
        }

        // Fetch the GenBank record
        let data = try await efetch(
            database: .nucleotide,
            ids: [uid],
            format: .genbank
        )

        // Convert to string
        guard let content = String(data: data, encoding: .utf8) else {
            throw DatabaseServiceError.parseError(message: "Invalid GenBank data encoding")
        }

        // Extract the accession from the GenBank content for accurate filename
        let resolvedAccession = extractAccession(from: content) ?? accession

        return (content: content, accession: resolvedAccession)
    }

    /// Extracts the accession number from GenBank file content.
    private func extractAccession(from content: String) -> String? {
        let lines = content.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("ACCESSION") {
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count > 1 {
                    return parts[1]
                }
            }
            if line.hasPrefix("VERSION") {
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count > 1 {
                    // VERSION line contains accession.version (e.g., NC_002549.1)
                    return parts[1]
                }
            }
        }
        return nil
    }

    /// Fetches raw FASTA format data for an accession.
    ///
    /// This method returns the complete FASTA file content.
    ///
    /// - Parameter accession: The accession number to fetch
    /// - Returns: A tuple containing the raw FASTA content and the resolved accession
    /// - Throws: `DatabaseServiceError` if the fetch fails
    public func fetchRawFASTA(accession: String) async throws -> (content: String, accession: String) {
        // First search to get the UID
        let ids = try await esearch(
            database: .nucleotide,
            term: accession,
            retmax: 1
        )

        guard let uid = ids.first else {
            throw DatabaseServiceError.notFound(accession: accession)
        }

        // Fetch the FASTA record
        let data = try await efetch(
            database: .nucleotide,
            ids: [uid],
            format: .fasta
        )

        // Convert to string
        guard let content = String(data: data, encoding: .utf8) else {
            throw DatabaseServiceError.parseError(message: "Invalid FASTA data encoding")
        }

        // Extract the accession from FASTA header (first line after >)
        let resolvedAccession = extractAccessionFromFASTA(content) ?? accession

        return (content: content, accession: resolvedAccession)
    }

    /// Extracts the accession from a FASTA header line.
    private func extractAccessionFromFASTA(_ content: String) -> String? {
        guard let firstLine = content.components(separatedBy: "\n").first,
              firstLine.hasPrefix(">") else {
            return nil
        }
        // Header format is typically: >accession.version description
        let header = String(firstLine.dropFirst())
        let parts = header.components(separatedBy: .whitespaces)
        return parts.first
    }

    // MARK: - NCBI Datasets v2 Virus Search

    /// Searches the NCBI Datasets v2 virus database for a given taxon.
    ///
    /// Uses the Datasets v2 REST API which provides rich virus-specific metadata
    /// (host, location, completeness, pangolin classification) that Entrez doesn't expose.
    ///
    /// - Parameters:
    ///   - taxon: Taxonomy name or ID (e.g., "SARS-CoV-2", "Ebolavirus", "2697049")
    ///   - pageSize: Number of results per page (default 20)
    ///   - pageToken: Opaque cursor for pagination (from previous response's `nextPageToken`)
    ///   - refseqOnly: Restrict to RefSeq sequences
    ///   - annotatedOnly: Only return annotated sequences
    ///   - completeness: Filter by completeness: "COMPLETE" or "PARTIAL"
    ///   - host: Host organism filter (e.g., "Homo sapiens")
    ///   - geoLocation: Geographic location filter (e.g., "USA")
    ///   - releasedSince: Only return records released after this date (YYYY-MM-DD)
    /// - Returns: Search results with virus-enriched metadata
    public func searchVirusDatasets(
        taxon: String,
        pageSize: Int = 20,
        pageToken: String? = nil,
        refseqOnly: Bool = false,
        annotatedOnly: Bool = false,
        completeness: String? = nil,
        host: String? = nil,
        geoLocation: String? = nil,
        releasedSince: String? = nil
    ) async throws -> SearchResults {
        let encodedTaxon = taxon.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? taxon
        var urlString = "https://api.ncbi.nlm.nih.gov/datasets/v2/virus/taxon/\(encodedTaxon)/dataset_report?page_size=\(pageSize)"

        if let pageToken {
            if let encoded = pageToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                urlString += "&page_token=\(encoded)"
            }
        }
        if refseqOnly {
            urlString += "&filter.refseq_only=true"
        }
        if annotatedOnly {
            urlString += "&filter.annotated_only=true"
        }
        if let completeness, !completeness.isEmpty {
            urlString += "&filter.completeness=\(completeness)"
        }
        if let host, !host.isEmpty {
            if let encoded = host.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                urlString += "&filter.host=\(encoded)"
            }
        }
        if let geoLocation, !geoLocation.isEmpty {
            if let encoded = geoLocation.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                urlString += "&filter.geo_location=\(encoded)"
            }
        }
        if let releasedSince, !releasedSince.isEmpty {
            urlString += "&filter.released_since=\(releasedSince)"
        }

        guard let url = URL(string: urlString) else {
            throw DatabaseServiceError.invalidQuery(reason: "Invalid virus search URL")
        }

        logger.info("searchVirusDatasets: GET \(urlString, privacy: .public)")

        let data = try await makeRequest(url: url)
        let decoder = JSONDecoder()
        let report: VirusDatasetReport
        do {
            report = try decoder.decode(VirusDatasetReport.self, from: data)
        } catch let decodingError {
            let preview = String(data: data.prefix(2000), encoding: .utf8) ?? "(non-UTF8)"
            logger.error("searchVirusDatasets: Decoding failed: \(decodingError, privacy: .public)\nResponse preview: \(preview, privacy: .public)")
            throw decodingError
        }

        // Handle API-level errors (500, etc.)
        if let apiError = report.error {
            logger.error("searchVirusDatasets: API error: \(apiError, privacy: .public)")
            throw DatabaseServiceError.invalidQuery(reason: "NCBI API error: \(apiError)")
        }

        let records = report.reports.compactMap { virusReport -> SearchResultRecord? in
            guard let accession = virusReport.accession else { return nil }

            // Parse release date
            var releaseDate: Date?
            if let dateStr = virusReport.releaseDate {
                releaseDate = ISO8601DateFormatter().date(from: dateStr)
                    ?? VirusDatasetReport.looseDateFormatter.date(from: dateStr)
            }

            return SearchResultRecord(
                id: accession,
                accession: accession,
                title: virusReport.isolate?.name ?? virusReport.virus?.organismName ?? accession,
                organism: virusReport.virus?.organismName,
                length: virusReport.length,
                date: releaseDate,
                source: .ncbi,
                host: virusReport.host?.organismName,
                geoLocation: virusReport.location?.geographicLocation,
                collectionDate: virusReport.isolate?.collectionDate,
                completeness: virusReport.completeness,
                isolateName: virusReport.isolate?.name,
                sourceDatabase: virusReport.sourceDatabase,
                pangolinClassification: virusReport.virus?.pangolinClassification
            )
        }

        let hasMore = report.nextPageToken != nil
        return SearchResults(
            totalCount: report.totalCount ?? records.count,
            records: records,
            hasMore: hasMore,
            nextCursor: report.nextPageToken
        )
    }

    /// Searches the nucleotide (GenBank) database with optional RefSeq restriction.
    ///
    /// - Parameters:
    ///   - term: The search term
    ///   - retmax: Maximum number of results
    ///   - retstart: Starting offset for pagination
    ///   - refseqOnly: Whether to restrict results to RefSeq records only
    /// - Returns: Search result with IDs and total count
    public func searchNucleotide(
        term: String,
        retmax: Int = 20,
        retstart: Int = 0,
        refseqOnly: Bool = false
    ) async throws -> ESearchSearchResult {
        var nucleotideTerm = term
        if refseqOnly {
            nucleotideTerm = "(\(nucleotideTerm)) AND refseq[filter]"
        }
        logger.info("NCBIService.searchNucleotide: term='\(nucleotideTerm, privacy: .public)'")
        return try await esearchWithCount(
            database: .nucleotide,
            term: nucleotideTerm,
            retmax: retmax,
            retstart: retstart
        )
    }

    /// Searches the genome/assembly database.
    ///
    /// Note: The NCBI Genome database doesn't support direct efetch.
    /// Results should be linked to nuccore for sequence retrieval.
    ///
    /// - Parameters:
    ///   - term: The search term
    ///   - retmax: Maximum number of results
    ///   - retstart: Starting offset for pagination
    /// - Returns: Search result with IDs and total count
    public func searchGenome(
        term: String,
        retmax: Int = 20,
        retstart: Int = 0
    ) async throws -> ESearchSearchResult {
        // Search the assembly database for genome assemblies
        logger.info("NCBIService.searchGenome: term='\(term, privacy: .public)'")
        return try await esearchWithCount(
            database: .assembly,
            term: term,
            retmax: retmax,
            retstart: retstart
        )
    }

    /// Gets assembly summary information for assembly UIDs.
    ///
    /// - Parameter ids: Assembly UIDs from search
    /// - Returns: Array of assembly summaries
    public func assemblyEsummary(ids: [String]) async throws -> [NCBIAssemblySummary] {
        var components = URLComponents(url: baseURL.appendingPathComponent("esummary.fcgi"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "db", value: "assembly"),
            URLQueryItem(name: "id", value: ids.joined(separator: ",")),
            URLQueryItem(name: "retmode", value: "json")
        ]

        if let apiKey = apiKey {
            components.queryItems?.append(URLQueryItem(name: "api_key", value: apiKey))
        }

        logger.info("assemblyEsummary: Fetching \(ids.count) assembly summary(ies) for ids=\(ids.joined(separator: ","), privacy: .public)")
        let data = try await makeRequest(url: components.url!)

        // Parse assembly-specific response
        let response = try JSONDecoder().decode(AssemblyESummaryResponse.self, from: data)

        let summaries = ids.compactMap { id in
            response.result?[id]
        }
        logger.info("assemblyEsummary: Got \(summaries.count) summaries, ftpRefSeq=\(summaries.first?.ftpPathRefSeq ?? "nil", privacy: .public)")
        return summaries
    }

    // MARK: - Genome Download Methods

    /// Information about a genome file available for download.
    public struct GenomeFileInfo: Sendable {
        /// The HTTP URL for downloading the file
        public let url: URL
        /// The filename
        public let filename: String
        /// Estimated file size in bytes (from Content-Length header)
        public let estimatedSize: Int64?
        /// The assembly accession
        public let assemblyAccession: String
    }

    /// Gets information about the genomic FASTA file for an assembly.
    ///
    /// This method queries the FTP server (via HTTP) to find the genomic FASTA file
    /// and retrieve its size for progress tracking during download.
    ///
    /// - Parameter summary: The assembly summary containing FTP paths
    /// - Returns: Information about the downloadable genome file
    /// - Throws: `DatabaseServiceError` if the file cannot be found
    public func getGenomeFileInfo(for summary: NCBIAssemblySummary) async throws -> GenomeFileInfo {
        // Get the FTP path - prefer RefSeq, fall back to GenBank
        guard let ftpPath = summary.ftpPathRefSeq ?? summary.ftpPathGenBank else {
            throw DatabaseServiceError.notFound(accession: summary.assemblyAccession ?? summary.uid)
        }

        // Extract the assembly directory name from the FTP path (last component)
        guard let assemblyDirName = extractAssemblyDirName(from: ftpPath) else {
            throw DatabaseServiceError.parseError(message: "Invalid FTP path structure")
        }

        // Construct the genomic FASTA filename
        // Format: {assembly_name}_genomic.fna.gz
        let genomicFilename = "\(assemblyDirName)_genomic.fna.gz"

        // Convert FTP URL to HTTPS URL
        let httpPath = convertFTPToHTTP(ftpPath)

        let fileURLString = "\(httpPath)/\(genomicFilename)"
        guard let fileURL = URL(string: fileURLString) else {
            throw DatabaseServiceError.parseError(message: "Invalid genome file URL")
        }

        // Get file size using HEAD request
        var request = URLRequest(url: fileURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 30

        logger.info("getGenomeFileInfo: HEAD \(fileURL.absoluteString, privacy: .public)")
        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DatabaseServiceError.networkError(underlying: "Bad server response")
        }

        // Check if file exists
        guard httpResponse.statusCode == 200 else {
            throw DatabaseServiceError.notFound(accession: summary.assemblyAccession ?? summary.uid)
        }

        // Get file size from Content-Length header
        let fileSize = httpResponse.expectedContentLength > 0 ? httpResponse.expectedContentLength : nil

        return GenomeFileInfo(
            url: fileURL,
            filename: genomicFilename,
            estimatedSize: fileSize,
            assemblyAccession: summary.assemblyAccession ?? summary.uid
        )
    }

    /// Gets information about the GFF3 annotation file for an assembly.
    ///
    /// This method constructs the GFF3 annotation file URL from the assembly FTP path.
    /// The URL pattern is `{ftpPath}/{assemblyDirName}_genomic.gff.gz`. Not all assemblies
    /// have GFF3 annotations available, so this method returns `nil` if the file does not exist.
    ///
    /// - Parameter summary: The assembly summary containing FTP paths
    /// - Returns: Information about the downloadable annotation file, or `nil` if unavailable
    public func getAnnotationFileInfo(for summary: NCBIAssemblySummary) async throws -> GenomeFileInfo? {
        // Get the FTP path - prefer RefSeq, fall back to GenBank
        guard let ftpPath = summary.ftpPathRefSeq ?? summary.ftpPathGenBank else {
            return nil
        }

        // Extract the assembly directory name from the FTP path (last component)
        guard let assemblyDirName = extractAssemblyDirName(from: ftpPath) else {
            return nil
        }

        // Construct the GFF3 annotation filename
        // Format: {assembly_name}_genomic.gff.gz
        let gffFilename = "\(assemblyDirName)_genomic.gff.gz"

        // Convert FTP URL to HTTPS URL
        let httpPath = convertFTPToHTTP(ftpPath)

        let fileURLString = "\(httpPath)/\(gffFilename)"
        guard let fileURL = URL(string: fileURLString) else {
            logger.warning("getAnnotationFileInfo: Could not construct URL for \(gffFilename)")
            return nil
        }

        // Check if the GFF3 file exists using HEAD request
        var request = URLRequest(url: fileURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15

        do {
            let (_, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }

            // Return nil if file does not exist (404 or other non-200 status)
            guard httpResponse.statusCode == 200 else {
                logger.info("getAnnotationFileInfo: GFF3 not available for \(summary.assemblyAccession ?? summary.uid, privacy: .public) (HTTP \(httpResponse.statusCode))")
                return nil
            }

            // Get file size from Content-Length header
            let fileSize = httpResponse.expectedContentLength > 0 ? httpResponse.expectedContentLength : nil

            logger.info("getAnnotationFileInfo: Found GFF3 for \(summary.assemblyAccession ?? summary.uid, privacy: .public), size=\(fileSize ?? -1)")

            return GenomeFileInfo(
                url: fileURL,
                filename: gffFilename,
                estimatedSize: fileSize,
                assemblyAccession: summary.assemblyAccession ?? summary.uid
            )
        } catch {
            // Network errors are non-fatal for annotation lookup
            logger.warning("getAnnotationFileInfo: Failed to check GFF3 availability: \(error.localizedDescription)")
            return nil
        }
    }

    /// Gets information about the assembly report file for an assembly.
    ///
    /// The assembly report is a small (~50 KB) tab-delimited text file containing
    /// the authoritative mapping between chromosome naming conventions (RefSeq accession,
    /// GenBank accession, UCSC name, assigned molecule number, etc.). This enables
    /// reliable VCF-to-reference chromosome matching.
    ///
    /// - Parameter summary: The assembly summary containing FTP paths
    /// - Returns: Information about the downloadable assembly report, or `nil` if unavailable
    public func getAssemblyReportInfo(for summary: NCBIAssemblySummary) async throws -> GenomeFileInfo? {
        guard let ftpPath = summary.ftpPathRefSeq ?? summary.ftpPathGenBank else {
            return nil
        }

        guard let assemblyDirName = extractAssemblyDirName(from: ftpPath) else {
            return nil
        }

        // Format: {assembly_name}_assembly_report.txt
        let reportFilename = "\(assemblyDirName)_assembly_report.txt"
        let httpPath = convertFTPToHTTP(ftpPath)

        let fileURLString = "\(httpPath)/\(reportFilename)"
        guard let fileURL = URL(string: fileURLString) else {
            logger.warning("getAssemblyReportInfo: Could not construct URL for \(reportFilename)")
            return nil
        }

        var request = URLRequest(url: fileURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15

        do {
            let (_, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }

            guard httpResponse.statusCode == 200 else {
                logger.info("getAssemblyReportInfo: Assembly report not available for \(summary.assemblyAccession ?? summary.uid, privacy: .public) (HTTP \(httpResponse.statusCode))")
                return nil
            }

            let fileSize = httpResponse.expectedContentLength > 0 ? httpResponse.expectedContentLength : nil

            logger.info("getAssemblyReportInfo: Found assembly report for \(summary.assemblyAccession ?? summary.uid, privacy: .public), size=\(fileSize ?? -1)")

            return GenomeFileInfo(
                url: fileURL,
                filename: reportFilename,
                estimatedSize: fileSize,
                assemblyAccession: summary.assemblyAccession ?? summary.uid
            )
        } catch {
            logger.warning("getAssemblyReportInfo: Failed to check assembly report availability: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - NCBI Datasets API

    /// Result of downloading via the NCBI Datasets API.
    /// Contains paths to extracted FASTA and optional GFF3 files.
    public struct DatasetsDownloadResult: Sendable {
        /// Path to the extracted genomic FASTA file (.fna)
        public let fastaURL: URL
        /// Path to the extracted GFF3 annotation file, if available
        public let gffURL: URL?
    }

    /// Downloads genome data via the NCBI Datasets API as a fallback when FTP paths are unavailable.
    ///
    /// The Datasets API returns a ZIP archive containing FASTA and optionally GFF3 files.
    /// This method downloads the ZIP, extracts it, and locates the relevant files.
    ///
    /// - Parameters:
    ///   - accession: Assembly accession (e.g., "GCA_014858485.1")
    ///   - destination: Directory to extract files into
    ///   - progressHandler: Called periodically with (bytesDownloaded, totalBytes)
    /// - Returns: Paths to the extracted FASTA and optional GFF3 files
    /// - Throws: `DatabaseServiceError` if the download or extraction fails
    public func downloadViaDatasets(
        accession: String,
        destination: URL,
        progressHandler: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> DatasetsDownloadResult {
        // Construct Datasets API URL for FASTA + GFF3
        let urlString = "https://api.ncbi.nlm.nih.gov/datasets/v2/genome/accession/\(accession)/download?include_annotation_type=GENOME_FASTA,GENOME_GFF"
        guard let url = URL(string: urlString) else {
            throw DatabaseServiceError.parseError(message: "Invalid Datasets API URL for \(accession)")
        }

        logger.info("downloadViaDatasets: Downloading ZIP from Datasets API for \(accession, privacy: .public)")

        // Download the ZIP using continuation-based approach for progress
        let zipFileInfo = GenomeFileInfo(
            url: url,
            filename: "\(accession)_datasets.zip",
            estimatedSize: nil,
            assemblyAccession: accession
        )
        let zipDestination = destination.appendingPathComponent(zipFileInfo.filename)
        _ = try await downloadGenomeFile(zipFileInfo, to: zipDestination, progressHandler: progressHandler)

        // Extract the ZIP
        logger.info("downloadViaDatasets: Extracting ZIP archive")
        let extractDir = destination.appendingPathComponent("ncbi_dataset_extract", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", zipDestination.path, "-d", extractDir.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw DatabaseServiceError.parseError(message: "Failed to extract Datasets ZIP (exit \(process.terminationStatus))")
        }

        // Clean up the ZIP file
        try? FileManager.default.removeItem(at: zipDestination)

        // Locate FASTA file: ncbi_dataset/data/{accession}/*_genomic.fna
        let dataDir = extractDir.appendingPathComponent("ncbi_dataset/data/\(accession)", isDirectory: true)
        let fastaURL = try locateFile(in: dataDir, matching: "_genomic.fna")
            ?? locateFile(in: dataDir, matching: ".fna")

        guard let fastaURL else {
            throw DatabaseServiceError.parseError(message: "No FASTA file found in Datasets download for \(accession)")
        }
        logger.info("downloadViaDatasets: Found FASTA: \(fastaURL.lastPathComponent, privacy: .public)")

        // Locate GFF3 file (optional): ncbi_dataset/data/{accession}/genomic.gff
        let gffURL = try locateFile(in: dataDir, matching: ".gff")
            ?? locateFile(in: dataDir, matching: ".gff3")
        if let gffURL {
            logger.info("downloadViaDatasets: Found GFF3: \(gffURL.lastPathComponent, privacy: .public)")
        } else {
            logger.info("downloadViaDatasets: No GFF3 annotations in download")
        }

        return DatasetsDownloadResult(fastaURL: fastaURL, gffURL: gffURL)
    }

    /// Locates a file in a directory whose name contains the given suffix.
    private func locateFile(in directory: URL, matching suffix: String) throws -> URL? {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        return contents.first { $0.lastPathComponent.contains(suffix) }
    }

    /// Downloads a genome file with progress tracking.
    ///
    /// - Parameters:
    ///   - fileInfo: Information about the file to download
    ///   - destination: The destination URL for the downloaded file
    ///   - progressHandler: Called periodically with (bytesDownloaded, totalBytes)
    /// - Returns: The URL of the downloaded file
    /// - Throws: `DatabaseServiceError` if the download fails
    public func downloadGenomeFile(
        _ fileInfo: GenomeFileInfo,
        to destination: URL,
        progressHandler: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> URL {
        // Use continuation-based approach instead of async session.download(for:delegate:)
        // because the async API doesn't reliably forward didWriteData progress callbacks
        // to the session delegate.
        let delegate = ContinuationDownloadDelegate(
            totalBytes: fileInfo.estimatedSize,
            progressHandler: progressHandler
        )

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

        let request = URLRequest(url: fileInfo.url)

        let tempURL: URL = try await withCheckedThrowingContinuation { continuation in
            delegate.setContinuation(continuation)
            let task = session.downloadTask(with: request)
            task.resume()
        }

        session.invalidateAndCancel()

        // Move to destination
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: tempURL, to: destination)

        return destination
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

    // MARK: - E-utilities Methods

    /// Result of an NCBI esearch, including total count for pagination
    public struct ESearchSearchResult: Sendable {
        public let ids: [String]
        public let totalCount: Int
        public let retmax: Int
        public let retstart: Int
    }

    /// Searches an NCBI database and returns matching UIDs.
    ///
    /// - Parameters:
    ///   - database: The database to search
    ///   - term: The search term
    ///   - retmax: Maximum number of results
    ///   - retstart: Starting offset for pagination
    /// - Returns: Array of UIDs
    public func esearch(
        database: NCBIDatabase,
        term: String,
        retmax: Int = 20,
        retstart: Int = 0
    ) async throws -> [String] {
        let result = try await esearchWithCount(database: database, term: term, retmax: retmax, retstart: retstart)
        return result.ids
    }

    /// Searches an NCBI database and returns matching UIDs with total count.
    ///
    /// - Parameters:
    ///   - database: The database to search
    ///   - term: The search term
    ///   - retmax: Maximum number of results
    ///   - retstart: Starting offset for pagination
    /// - Returns: Search result with IDs and total count
    public func esearchWithCount(
        database: NCBIDatabase,
        term: String,
        retmax: Int = 20,
        retstart: Int = 0
    ) async throws -> ESearchSearchResult {
        var components = URLComponents(url: baseURL.appendingPathComponent("esearch.fcgi"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "db", value: database.rawValue),
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "retmax", value: String(retmax)),
            URLQueryItem(name: "retstart", value: String(retstart)),
            URLQueryItem(name: "retmode", value: "json"),
            URLQueryItem(name: "usehistory", value: "n")
        ]

        if let apiKey = apiKey {
            components.queryItems?.append(URLQueryItem(name: "api_key", value: apiKey))
        }

        logger.debug("NCBIService.esearchWithCount: URL=\(components.url?.absoluteString ?? "nil", privacy: .public)")

        let data = try await makeRequest(url: components.url!)

        // Log raw response for debugging (truncated)
        if let responseString = String(data: data, encoding: .utf8) {
            let truncated = String(responseString.prefix(500))
            logger.debug("NCBIService.esearchWithCount: Response (truncated)=\(truncated, privacy: .public)")
        }

        let response = try JSONDecoder().decode(ESearchResponse.self, from: data)

        if let error = response.esearchresult?.errorlist?.phrasesnotfound?.first {
            logger.warning("NCBIService.esearchWithCount: Phrase not found: \(error, privacy: .public)")
            throw DatabaseServiceError.invalidQuery(reason: "Term not found: \(error)")
        }

        let ids = response.esearchresult?.idlist ?? []
        let totalCount = Int(response.esearchresult?.count ?? "0") ?? 0

        logger.info("NCBIService.esearchWithCount: Found \(totalCount) total results, returning \(ids.count) IDs")

        return ESearchSearchResult(
            ids: ids,
            totalCount: totalCount,
            retmax: retmax,
            retstart: retstart
        )
    }

    /// Fetches records from an NCBI database.
    ///
    /// - Parameters:
    ///   - database: The database to fetch from
    ///   - ids: UIDs to fetch
    ///   - format: Output format
    /// - Returns: Raw data in the requested format
    public func efetch(
        database: NCBIDatabase,
        ids: [String],
        format: NCBIFormat
    ) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent("efetch.fcgi"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "db", value: database.rawValue),
            URLQueryItem(name: "id", value: ids.joined(separator: ",")),
            URLQueryItem(name: "rettype", value: format.rettype),
            URLQueryItem(name: "retmode", value: format.retmode)
        ]

        if let apiKey = apiKey {
            components.queryItems?.append(URLQueryItem(name: "api_key", value: apiKey))
        }

        return try await makeRequest(url: components.url!)
    }

    // MARK: - SRA Search

    /// Searches the SRA database via ESearch, returning UIDs and total count.
    public func sraESearch(term: String, retmax: Int = 200, retstart: Int = 0) async throws -> ESearchSearchResult {
        try await esearchWithCount(database: .sra, term: term, retmax: retmax, retstart: retstart)
    }

    /// Fetches SRR run accessions from SRA UIDs via EFetch runinfo CSV.
    public func sraEFetchRunAccessions(uids: [String]) async throws -> [String] {
        guard !uids.isEmpty else { return [] }

        var allAccessions: [String] = []
        let chunkSize = 200
        for chunkStart in stride(from: 0, to: uids.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, uids.count)
            let chunk = Array(uids[chunkStart..<chunkEnd])

            var components = URLComponents(url: baseURL.appendingPathComponent("efetch.fcgi"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "db", value: "sra"),
                URLQueryItem(name: "id", value: chunk.joined(separator: ",")),
                URLQueryItem(name: "rettype", value: "runinfo"),
                URLQueryItem(name: "retmode", value: "csv")
            ]
            if let apiKey = apiKey {
                components.queryItems?.append(URLQueryItem(name: "api_key", value: apiKey))
            }

            let data = try await makeRequest(url: components.url!)
            let csvText = String(data: data, encoding: .utf8) ?? ""
            allAccessions.append(contentsOf: Self.parseRunInfoCSV(csvText))
        }
        return allAccessions
    }

    /// Fetches detailed SRA run info rows via EFetch runinfo CSV.
    ///
    /// The `id` parameter accepted by NCBI EFetch works with either SRA UIDs
    /// returned by ESearch or run accessions such as `SRR12345678`.
    public func sraEFetchRunInfo(ids: [String]) async throws -> [SRARunInfo] {
        guard !ids.isEmpty else { return [] }

        var allRuns: [SRARunInfo] = []
        let chunkSize = 200
        for chunkStart in stride(from: 0, to: ids.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, ids.count)
            let chunk = Array(ids[chunkStart..<chunkEnd])

            var components = URLComponents(url: baseURL.appendingPathComponent("efetch.fcgi"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "db", value: "sra"),
                URLQueryItem(name: "id", value: chunk.joined(separator: ",")),
                URLQueryItem(name: "rettype", value: "runinfo"),
                URLQueryItem(name: "retmode", value: "csv")
            ]
            if let apiKey = apiKey {
                components.queryItems?.append(URLQueryItem(name: "api_key", value: apiKey))
            }

            let data = try await makeRequest(url: components.url!)
            let csvText = String(data: data, encoding: .utf8) ?? ""
            allRuns.append(contentsOf: Self.parseRunInfoRows(csvText))
        }
        return allRuns
    }

    /// Parses NCBI SRA EFetch runinfo CSV to extract run accessions.
    ///
    /// Only returns values that match SRA run accession patterns (SRR/ERR/DRR + digits).
    public static func parseRunInfoCSV(_ csv: String) -> [String] {
        let runPattern = /^[SED]RR\d+$/
        let lines = csv.components(separatedBy: .newlines)
        guard lines.count > 1 else { return [] }
        return lines.dropFirst().compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let run = trimmed.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !run.isEmpty, run.wholeMatch(of: runPattern) != nil else { return nil }
            return run
        }
    }

    static func parseRunInfoRows(_ csv: String) -> [SRARunInfo] {
        let lines = csv.components(separatedBy: "\n")
        guard !lines.isEmpty else { return [] }

        let firstLine = lines[0]
        let hasHeader = firstLine.hasPrefix("Run,")

        let runIdx = 0
        let releaseDateIdx = 1
        let spotsIdx = 3
        let basesIdx = 4
        let avgLengthIdx = 6
        let sizeMBIdx = 7
        let experimentIdx = 10
        let libraryStrategyIdx = 12
        let librarySourceIdx = 14
        let libraryLayoutIdx = 15
        let platformIdx = 18
        let studyIdx = 20
        let bioprojectIdx = 21
        let sampleIdx = 24
        let biosampleIdx = 25
        let scientificNameIdx = 28

        let dataLines = hasHeader ? Array(lines.dropFirst()) : lines

        return dataLines.compactMap { line -> SRARunInfo? in
            guard !line.isEmpty else { return nil }
            let fields = Self.parseRunInfoLine(line)
            guard fields.count > runIdx, !fields[runIdx].isEmpty else { return nil }
            let field: (Int) -> String? = { index in
                guard index >= 0 && index < fields.count else { return nil }
                return fields[index]
            }

            let run = SRARunInfo(
                accession: field(runIdx) ?? "",
                experiment: field(experimentIdx),
                sample: field(sampleIdx),
                study: field(studyIdx),
                bioproject: field(bioprojectIdx),
                biosample: field(biosampleIdx),
                organism: field(scientificNameIdx),
                platform: field(platformIdx),
                libraryStrategy: field(libraryStrategyIdx),
                librarySource: field(librarySourceIdx),
                libraryLayout: field(libraryLayoutIdx),
                spots: Int(field(spotsIdx) ?? ""),
                bases: Int(field(basesIdx) ?? ""),
                avgLength: Int(field(avgLengthIdx) ?? ""),
                size: Int(field(sizeMBIdx) ?? ""),
                releaseDate: Self.parseRunInfoDate(field(releaseDateIdx))
            )

            return run.accession.isEmpty ? nil : run
        }
    }

    private static func parseRunInfoLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current)
        return fields
    }

    private static func parseRunInfoDate(_ dateStr: String?) -> Date? {
        guard let str = dateStr, !str.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: str)
    }

    /// Retrieves document summaries for UIDs.
    ///
    /// - Parameters:
    ///   - database: The database
    ///   - ids: UIDs to get summaries for
    /// - Returns: Array of document summaries
    public func esummary(
        database: NCBIDatabase,
        ids: [String]
    ) async throws -> [NCBIDocumentSummary] {
        var components = URLComponents(url: baseURL.appendingPathComponent("esummary.fcgi"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "db", value: database.rawValue),
            URLQueryItem(name: "id", value: ids.joined(separator: ",")),
            URLQueryItem(name: "retmode", value: "json")
        ]

        if let apiKey = apiKey {
            components.queryItems?.append(URLQueryItem(name: "api_key", value: apiKey))
        }

        let data = try await makeRequest(url: components.url!)

        let response = try JSONDecoder().decode(ESummaryResponse.self, from: data)

        return ids.compactMap { id in
            response.result?[id]
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
        request.setValue("Lungfish Genome Explorer", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

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

    /// Converts an FTP path to an HTTP(S) path.
    ///
    /// - Parameter ftpPath: FTP path (e.g., "ftp://ftp.ncbi.nlm.nih.gov/genomes/...")
    /// - Returns: HTTP(S) path (e.g., "https://ftp.ncbi.nlm.nih.gov/genomes/...")
    private func convertFTPToHTTP(_ ftpPath: String) -> String {
        var httpPath = ftpPath
        if httpPath.hasPrefix("ftp://") {
            httpPath = httpPath.replacingOccurrences(of: "ftp://", with: "https://")
        } else if !httpPath.hasPrefix("https://") && !httpPath.hasPrefix("http://") {
            httpPath = "https://\(httpPath)"
        }
        return httpPath
    }

    /// Extracts the assembly directory name from an FTP path.
    ///
    /// - Parameter ftpPath: FTP path (e.g., "ftp://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/.../GCF_000001405.40_GRCh38.p14")
    /// - Returns: Assembly directory name (e.g., "GCF_000001405.40_GRCh38.p14"), or `nil` if invalid
    private func extractAssemblyDirName(from ftpPath: String) -> String? {
        let pathComponents = ftpPath.components(separatedBy: "/")
        guard let assemblyDirName = pathComponents.last, !assemblyDirName.isEmpty else {
            return nil
        }
        return assemblyDirName
    }

    private func parseGenBankRecord(_ content: String, uid: String) throws -> DatabaseRecord {
        // Basic GenBank parsing - extracts key metadata and sequence
        // Note: For full annotation preservation, use fetchRawGenBank() and save directly
        var accession = uid
        var version: String?
        var title = ""
        var organism: String?
        var sequence = ""
        var metadata: [String: String] = [:]
        var annotations: [SequenceAnnotation] = []

        let lines = content.components(separatedBy: "\n")
        var inSequence = false
        var inFeatures = false
        var currentFeature: (type: String, location: String, qualifiers: [String: String])?
        var currentQualifierKey: String?
        var currentQualifierValue: String = ""

        for line in lines {
            if line.hasPrefix("LOCUS") {
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count > 1 {
                    accession = parts[1]
                }
                // Extract molecule type if available
                if parts.count > 3 {
                    metadata["molecule_type"] = parts[3]
                }
            } else if line.hasPrefix("ACCESSION") {
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count > 1 {
                    accession = parts[1]
                }
            } else if line.hasPrefix("VERSION") {
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count > 1 {
                    version = parts[1]
                }
            } else if line.hasPrefix("DEFINITION") {
                title = String(line.dropFirst(12)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("  ORGANISM") {
                organism = String(line.dropFirst(12)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("KEYWORDS") {
                let keywords = String(line.dropFirst(12)).trimmingCharacters(in: .whitespaces)
                if keywords != "." {
                    metadata["keywords"] = keywords
                }
            } else if line.hasPrefix("SOURCE") {
                metadata["source"] = String(line.dropFirst(12)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("FEATURES") {
                inFeatures = true
            } else if line.hasPrefix("ORIGIN") {
                // Finish any pending feature
                if let feature = currentFeature {
                    if let annotation = createAnnotation(from: feature) {
                        annotations.append(annotation)
                    }
                }
                inFeatures = false
                inSequence = true
            } else if line.hasPrefix("//") {
                inSequence = false
                inFeatures = false
            } else if inSequence {
                // Parse sequence lines (numbered with spaces)
                let seqPart = line.components(separatedBy: .whitespaces).dropFirst().joined()
                sequence += seqPart.uppercased()
            } else if inFeatures {
                // Parse feature table entries
                if let featureInfo = parseFeatureLine(line) {
                    // Save previous feature
                    if let feature = currentFeature {
                        if let annotation = createAnnotation(from: feature) {
                            annotations.append(annotation)
                        }
                    }
                    currentFeature = featureInfo
                    currentQualifierKey = nil
                } else if let (key, value) = parseQualifierLine(line) {
                    currentQualifierKey = key
                    currentQualifierValue = value
                    currentFeature?.qualifiers[key] = value
                } else if line.hasPrefix("                    ") && currentQualifierKey != nil {
                    // Continuation of qualifier value
                    let continuation = line.trimmingCharacters(in: .whitespaces)
                    currentQualifierValue += " " + continuation
                    if let key = currentQualifierKey {
                        currentFeature?.qualifiers[key] = currentQualifierValue
                    }
                }
            }
        }

        return DatabaseRecord(
            id: uid,
            accession: accession,
            version: version,
            title: title,
            organism: organism,
            sequence: sequence,
            annotations: annotations,
            metadata: metadata,
            source: .ncbi
        )
    }

    /// Parses a feature line from the FEATURES section.
    /// Feature lines start at column 6 with a feature type, followed by location.
    private func parseFeatureLine(_ line: String) -> (type: String, location: String, qualifiers: [String: String])? {
        // Feature lines have the format: "     feature_type     location"
        // They start with exactly 5 spaces, then the feature type
        guard line.hasPrefix("     ") && !line.hasPrefix("      ") else {
            return nil
        }

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }

        let featureType = parts[0]
        let location = parts.dropFirst().joined(separator: "")

        return (type: featureType, location: location, qualifiers: [:])
    }

    /// Parses a qualifier line from within a feature.
    /// Qualifier lines start at column 22 with /key="value" or /key=value
    private func parseQualifierLine(_ line: String) -> (String, String)? {
        guard line.hasPrefix("                     /") else {
            return nil
        }

        let content = String(line.dropFirst(21)).trimmingCharacters(in: .whitespaces)
        guard content.hasPrefix("/") else { return nil }

        let withoutSlash = String(content.dropFirst())
        if let equalsIndex = withoutSlash.firstIndex(of: "=") {
            let key = String(withoutSlash[..<equalsIndex])
            var value = String(withoutSlash[withoutSlash.index(after: equalsIndex)...])
            // Remove surrounding quotes if present
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count > 1 {
                value = String(value.dropFirst().dropLast())
            }
            return (key, value)
        } else {
            // Flag qualifier without value (e.g., /pseudo)
            return (withoutSlash, "true")
        }
    }

    /// Creates a SequenceAnnotation from parsed feature data.
    private func createAnnotation(from feature: (type: String, location: String, qualifiers: [String: String])) -> SequenceAnnotation? {
        // Parse location to get start and end positions
        guard let (start, end, strand) = parseLocation(feature.location) else {
            return nil
        }

        // Map GenBank feature types to our annotation types
        let annotationType: AnnotationType
        switch feature.type.lowercased() {
        case "gene":
            annotationType = .gene
        case "cds":
            annotationType = .cds
        case "mrna":
            annotationType = .mRNA
        case "trna", "rrna":
            annotationType = .transcript
        case "exon":
            annotationType = .exon
        case "intron":
            annotationType = .intron
        case "promoter":
            annotationType = .promoter
        case "misc_feature":
            annotationType = .misc_feature
        case "source":
            annotationType = .source
        case "variation":
            annotationType = .variation
        case "region":
            annotationType = .region
        default:
            annotationType = .misc_feature
        }

        // Get the name/label from qualifiers
        let name = feature.qualifiers["gene"]
            ?? feature.qualifiers["product"]
            ?? feature.qualifiers["label"]
            ?? feature.qualifiers["note"]
            ?? feature.type

        // Convert qualifiers to AnnotationQualifier format
        var convertedQualifiers: [String: AnnotationQualifier] = [:]
        for (key, value) in feature.qualifiers {
            convertedQualifiers[key] = AnnotationQualifier(value)
        }

        return SequenceAnnotation(
            type: annotationType,
            name: name,
            start: start,
            end: end,
            strand: strand,
            qualifiers: convertedQualifiers
        )
    }

    /// Parses a GenBank location string to extract start, end, and strand.
    private func parseLocation(_ location: String) -> (start: Int, end: Int, strand: Strand)? {
        var loc = location
        var strand: Strand = .forward

        // Check for complement
        if loc.hasPrefix("complement(") && loc.hasSuffix(")") {
            strand = .reverse
            loc = String(loc.dropFirst(11).dropLast())
        }

        // Handle join() - take the outer bounds
        if loc.hasPrefix("join(") && loc.hasSuffix(")") {
            loc = String(loc.dropFirst(5).dropLast())
            // Get first start and last end from joined locations
            let parts = loc.components(separatedBy: ",")
            if let first = parts.first, let last = parts.last {
                if let firstRange = parseSimpleRange(first),
                   let lastRange = parseSimpleRange(last) {
                    return (start: firstRange.start, end: lastRange.end, strand: strand)
                }
            }
        }

        // Simple range: start..end
        if let range = parseSimpleRange(loc) {
            return (start: range.start, end: range.end, strand: strand)
        }

        return nil
    }

    /// Parses a simple range like "123..456" or "<123..>456"
    private func parseSimpleRange(_ range: String) -> (start: Int, end: Int)? {
        let cleaned = range.replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .trimmingCharacters(in: .whitespaces)

        let parts = cleaned.components(separatedBy: "..")
        guard parts.count == 2,
              let start = Int(parts[0]),
              let end = Int(parts[1]) else {
            // Try single position
            if let pos = Int(cleaned) {
                return (start: pos, end: pos)
            }
            return nil
        }

        return (start: start, end: end)
    }
}

// MARK: - NCBI Database

/// NCBI databases available through E-utilities.
public enum NCBIDatabase: String, Sendable, CaseIterable {
    case nucleotide
    case genome
    case assembly
    case protein
    case gene
    case sra
    case biosample
    case bioproject
    case taxonomy
    case pubmed
    case pmc

    /// Human-readable name.
    public var displayName: String {
        switch self {
        case .nucleotide: return "Nucleotide (GenBank)"
        case .genome: return "Genome"
        case .assembly: return "Assembly"
        case .protein: return "Protein"
        case .gene: return "Gene"
        case .sra: return "SRA (Sequence Read Archive)"
        case .biosample: return "BioSample"
        case .bioproject: return "BioProject"
        case .taxonomy: return "Taxonomy"
        case .pubmed: return "PubMed"
        case .pmc: return "PubMed Central"
        }
    }

    /// Whether this database supports direct efetch for sequence data.
    public var supportsEfetch: Bool {
        switch self {
        case .nucleotide, .protein, .gene:
            return true
        case .genome, .assembly:
            // Genome and Assembly databases don't support direct efetch;
            // sequences must be fetched via linked nuccore records
            return false
        default:
            return false
        }
    }

    /// The taxonomy filter to use when searching for viral sequences in nuccore.
    /// NCBI Virus uses taxid 10239 (Viruses)
    public static var virusTaxonomyFilter: String {
        "txid10239[Organism:exp]"
    }
}

// MARK: - NCBI Format

/// Output formats for NCBI EFetch.
public enum NCBIFormat: String, Sendable, CaseIterable, Identifiable {
    case fasta = "FASTA"
    case genbank = "GenBank"
    case genbankWithParts = "GenBank (with parts)"
    case xml = "XML"

    public var id: String { rawValue }

    /// Display name for UI
    public var displayName: String { rawValue }

    /// File extension for saved files
    public var fileExtension: String {
        switch self {
        case .fasta: return "fasta"
        case .genbank, .genbankWithParts: return "gb"
        case .xml: return "xml"
        }
    }

    var rettype: String {
        switch self {
        case .fasta: return "fasta"
        case .genbank, .genbankWithParts: return "gb"
        case .xml: return "native"
        }
    }

    var retmode: String {
        switch self {
        case .xml: return "xml"
        default: return "text"
        }
    }

    /// Formats available for user selection in UI
    public static var downloadFormats: [NCBIFormat] {
        [.genbank, .fasta]
    }
}

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
}

struct ESearchErrorList: Codable {
    let phrasesnotfound: [String]?
}

struct ESummaryResponse: Codable {
    let result: [String: NCBIDocumentSummary]?

    private enum CodingKeys: String, CodingKey {
        case result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // The result is nested inside the "result" key
        let resultContainer = try container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .result)
        var result: [String: NCBIDocumentSummary] = [:]

        for key in resultContainer.allKeys {
            // Skip the "uids" array
            if key.stringValue == "uids" { continue }
            if let summary = try? resultContainer.decode(NCBIDocumentSummary.self, forKey: key) {
                result[key.stringValue] = summary
            }
        }

        self.result = result.isEmpty ? nil : result
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
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // The result is nested inside the "result" key
        let resultContainer = try container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .result)
        var result: [String: NCBIAssemblySummary] = [:]

        for key in resultContainer.allKeys {
            // Skip the "uids" array
            if key.stringValue == "uids" { continue }
            if let summary = try? resultContainer.decode(NCBIAssemblySummary.self, forKey: key) {
                result[key.stringValue] = summary
            }
        }

        self.result = result.isEmpty ? nil : result
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

// MARK: - NCBIAssemblySummary Metadata Conversion

/// Formats a base pair count into a human-readable string (e.g., "56.4 Mb").
///
/// Module-level free function to avoid `@MainActor` isolation issues when called
/// from `@Sendable` contexts.
private func formatAssemblyBp(_ value: Int) -> String {
    if value >= 1_000_000_000 {
        return String(format: "%.1f Gb", Double(value) / 1_000_000_000)
    }
    if value >= 1_000_000 {
        return String(format: "%.1f Mb", Double(value) / 1_000_000)
    }
    if value >= 1_000 {
        return String(format: "%.1f Kb", Double(value) / 1_000)
    }
    return "\(value) bp"
}

extension NCBIAssemblySummary {

    /// Converts the assembly summary into categorized metadata groups for bundle storage.
    ///
    /// Groups:
    /// - **Assembly**: Name, accession, status, level, coverage, N50 statistics, length, chromosome count
    /// - **Taxonomy**: Organism, species, taxonomy ID
    /// - **Source**: Submitter, organization, BioSample, BioProject
    ///
    /// - Returns: Array of metadata groups with non-nil fields populated.
    public func toMetadataGroups() -> [MetadataGroup] {
        var groups: [MetadataGroup] = []

        // Assembly group
        var assemblyItems: [MetadataItem] = []
        if let v = assemblyName { assemblyItems.append(MetadataItem(label: "Assembly Name", value: v)) }
        if let v = assemblyAccession { assemblyItems.append(MetadataItem(label: "Accession", value: v)) }
        if let v = assemblyStatus { assemblyItems.append(MetadataItem(label: "Status", value: v)) }
        if let v = assemblyLevel { assemblyItems.append(MetadataItem(label: "Level", value: v)) }
        if let v = refseqCategory { assemblyItems.append(MetadataItem(label: "RefSeq Category", value: v)) }
        if let v = releaseType { assemblyItems.append(MetadataItem(label: "Release Type", value: v)) }
        if let v = coverage { assemblyItems.append(MetadataItem(label: "Coverage", value: "\(v)x")) }
        if let v = contigN50 { assemblyItems.append(MetadataItem(label: "Contig N50", value: formatAssemblyBp(v))) }
        if let v = scaffoldN50 { assemblyItems.append(MetadataItem(label: "Scaffold N50", value: formatAssemblyBp(v))) }
        if let v = totalSequenceLength { assemblyItems.append(MetadataItem(label: "Total Length", value: "\(v) bp")) }
        if let v = chromosomeCount { assemblyItems.append(MetadataItem(label: "Chromosomes", value: v)) }
        if !assemblyItems.isEmpty { groups.append(MetadataGroup(name: "Assembly", items: assemblyItems)) }

        // Taxonomy group
        var taxItems: [MetadataItem] = []
        if let v = organism { taxItems.append(MetadataItem(label: "Organism", value: v)) }
        if let v = speciesName, v != organism { taxItems.append(MetadataItem(label: "Species", value: v)) }
        if let v = taxid { taxItems.append(MetadataItem(label: "Taxonomy ID", value: String(v))) }
        if !taxItems.isEmpty { groups.append(MetadataGroup(name: "Taxonomy", items: taxItems)) }

        // Source group
        var sourceItems: [MetadataItem] = []
        if let v = submitter { sourceItems.append(MetadataItem(label: "Submitter", value: v)) }
        if let v = submitterOrganization { sourceItems.append(MetadataItem(label: "Organization", value: v)) }
        if let v = biosampleAccession { sourceItems.append(MetadataItem(label: "BioSample", value: v)) }
        if let v = bioprojectAccession { sourceItems.append(MetadataItem(label: "BioProject", value: v)) }
        if !sourceItems.isEmpty { groups.append(MetadataGroup(name: "Source", items: sourceItems)) }

        return groups
    }
}

// MARK: - NCBI Search Type

/// The type of NCBI search to perform.
public enum NCBISearchType: String, CaseIterable, Identifiable, Sendable {
    case nucleotide = "GenBank (Nucleotide)"
    case genome = "Genome (Assembly)"
    case virus = "Virus"

    public var id: String { rawValue }

    /// Human-readable display name
    public var displayName: String { rawValue }

    /// Icon for the search type
    public var icon: String {
        switch self {
        case .nucleotide: return "doc.text"
        case .genome: return "circle.hexagongrid"
        case .virus: return "allergens"
        }
    }

    /// Help text explaining this search type
    public var helpText: String {
        switch self {
        case .nucleotide:
            return "Search GenBank nucleotide sequences including genes, plasmids, and genomes"
        case .genome:
            return "Search complete genome assemblies from RefSeq and GenBank"
        case .virus:
            return "Search viral sequences from NCBI Virus database"
        }
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

// MARK: - VirusReport Metadata Conversion

extension VirusReport {

    /// Converts the virus report into categorized metadata groups for bundle storage.
    ///
    /// Groups:
    /// - **Virus**: Organism name, pangolin classification, taxonomy ID
    /// - **Host**: Host organism, host taxonomy ID
    /// - **Collection**: Isolate name, collection date, geographic location, region, purpose of sampling
    /// - **Record**: Accession, source database, completeness, sequence length, protein count, release/update dates
    /// - **Links**: BioSample, BioProject accessions
    ///
    /// - Returns: Array of metadata groups with non-nil fields populated.
    public func toMetadataGroups() -> [MetadataGroup] {
        var groups: [MetadataGroup] = []

        // Virus group
        var virusItems: [MetadataItem] = []
        if let v = virus?.organismName { virusItems.append(MetadataItem(label: "Organism", value: v)) }
        if let v = virus?.pangolinClassification { virusItems.append(MetadataItem(label: "Pangolin Classification", value: v)) }
        if let v = virus?.taxId { virusItems.append(MetadataItem(label: "Taxonomy ID", value: String(v))) }
        if !virusItems.isEmpty { groups.append(MetadataGroup(name: "Virus", items: virusItems)) }

        // Host group
        var hostItems: [MetadataItem] = []
        if let v = host?.organismName { hostItems.append(MetadataItem(label: "Host Organism", value: v)) }
        if let v = host?.taxId { hostItems.append(MetadataItem(label: "Host Taxonomy ID", value: String(v))) }
        if !hostItems.isEmpty { groups.append(MetadataGroup(name: "Host", items: hostItems)) }

        // Collection group
        var collectionItems: [MetadataItem] = []
        if let v = isolate?.name { collectionItems.append(MetadataItem(label: "Isolate", value: v)) }
        if let v = isolate?.collectionDate { collectionItems.append(MetadataItem(label: "Collection Date", value: v)) }
        if let v = location?.geographicLocation { collectionItems.append(MetadataItem(label: "Location", value: v)) }
        if let v = location?.geographicRegion { collectionItems.append(MetadataItem(label: "Geographic Region", value: v)) }
        if let v = purposeOfSampling { collectionItems.append(MetadataItem(label: "Purpose of Sampling", value: v)) }
        if !collectionItems.isEmpty { groups.append(MetadataGroup(name: "Collection", items: collectionItems)) }

        // Record group
        var recordItems: [MetadataItem] = []
        if let v = accession { recordItems.append(MetadataItem(label: "Accession", value: v)) }
        if let v = sourceDatabase { recordItems.append(MetadataItem(label: "Source Database", value: v)) }
        if let v = completeness { recordItems.append(MetadataItem(label: "Completeness", value: v)) }
        if let v = length { recordItems.append(MetadataItem(label: "Length", value: "\(v) bp")) }
        if let v = proteinCount { recordItems.append(MetadataItem(label: "Protein Count", value: String(v))) }
        if let v = releaseDate { recordItems.append(MetadataItem(label: "Release Date", value: v)) }
        if let v = updateDate { recordItems.append(MetadataItem(label: "Update Date", value: v)) }
        if !recordItems.isEmpty { groups.append(MetadataGroup(name: "Record", items: recordItems)) }

        // Links group
        var linkItems: [MetadataItem] = []
        if let v = biosample { linkItems.append(MetadataItem(label: "BioSample", value: v)) }
        if let bioprojects, !bioprojects.isEmpty {
            linkItems.append(MetadataItem(label: "BioProject", value: bioprojects.joined(separator: ", ")))
        }
        if !linkItems.isEmpty { groups.append(MetadataGroup(name: "Links", items: linkItems)) }

        return groups
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

// MARK: - Download Progress Delegate

/// A URLSession delegate that tracks download progress.
/// URLSession download delegate that bridges to async/await via a continuation.
///
/// Using `downloadTask(with:)` + continuation instead of the async `session.download(for:delegate:)`
/// API because the async API doesn't reliably forward `didWriteData` progress callbacks.
final class ContinuationDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let totalBytes: Int64?
    private let progressHandler: @Sendable (Int64, Int64?) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    init(totalBytes: Int64?, progressHandler: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.totalBytes = totalBytes
        self.progressHandler = progressHandler
    }

    func setContinuation(_ continuation: CheckedContinuation<URL, Error>) {
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expectedTotal = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : totalBytes
        progressHandler(totalBytesWritten, expectedTotal)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Copy to a temp location that survives after the delegate callback returns,
        // since URLSession deletes the file at `location` after this method returns.
        let tempCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + location.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: location, to: tempCopy)
        } catch {
            continuation?.resume(throwing: error)
            continuation = nil
            return
        }

        guard let response = downloadTask.response as? HTTPURLResponse,
              response.statusCode == 200 else {
            continuation?.resume(throwing: DatabaseServiceError.networkError(
                underlying: "Bad server response: \((downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1)"
            ))
            continuation = nil
            return
        }

        continuation?.resume(returning: tempCopy)
        continuation = nil
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
