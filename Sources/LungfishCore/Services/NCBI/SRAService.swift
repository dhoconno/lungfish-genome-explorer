// SRAService.swift - NCBI Sequence Read Archive integration
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: NCBI Integration Lead (Role 12)

import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.core, category: "SRAService")

// MARK: - SRA Service

/// Service for accessing NCBI Sequence Read Archive (SRA).
///
/// This service provides search and download capabilities for SRA datasets.
/// Downloads require the SRA Toolkit to be installed (prefetch + fasterq-dump).
///
/// ## Usage
/// ```swift
/// let service = SRAService()
///
/// // Search for SRA runs
/// let results = try await service.search(term: "SARS-CoV-2 Illumina")
///
/// // Download FASTQ files
/// let files = try await service.downloadFASTQ(accession: "SRR11140748")
/// ```
public actor SRAService {

    // MARK: - Properties

    private nonisolated static let maxRunInfoFetchAttempts = 3
    private nonisolated static let initialRunInfoRetryDelayNanoseconds: UInt64 = 250_000_000
    private nonisolated static let retryableHTTPStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]
    private nonisolated static let retryableURLErrorCodes: Set<URLError.Code> = [
        .timedOut,
        .cannotFindHost,
        .cannotConnectToHost,
        .dnsLookupFailed,
        .networkConnectionLost,
        .notConnectedToInternet,
        .resourceUnavailable,
        .cannotLoadFromNetwork,
    ]

    private let ncbiService: NCBIService
    private let httpClient: HTTPClient
    private let homeDirectoryProvider: @Sendable () -> URL

    // MARK: - Initialization

    /// Creates a new SRA service.
    ///
    /// - Parameters:
    ///   - ncbiService: NCBI service for E-utilities access
    ///   - httpClient: HTTP client for direct API calls
    public init(
        ncbiService: NCBIService = NCBIService(),
        httpClient: HTTPClient = URLSessionHTTPClient(),
        homeDirectoryProvider: @escaping @Sendable () -> URL = {
            FileManager.default.homeDirectoryForCurrentUser
        }
    ) {
        self.ncbiService = ncbiService
        self.httpClient = httpClient
        self.homeDirectoryProvider = homeDirectoryProvider
    }

    // MARK: - Search

    /// Searches SRA for datasets matching the query.
    ///
    /// - Parameter query: Search query
    /// - Returns: Search results with SRA run information
    public func search(_ query: SearchQuery) async throws -> SRASearchResults {
        // Use NCBI ESearch with SRA database
        let ids = try await ncbiService.esearch(
            database: .sra,
            term: query.term,
            retmax: query.limit,
            retstart: query.offset
        )

        guard !ids.isEmpty else {
            return SRASearchResults(totalCount: 0, runs: [])
        }

        // Get run info via EFetch
        let runs = try await fetchRunInfo(ids: ids)

        return SRASearchResults(
            totalCount: ids.count,
            runs: runs,
            hasMore: runs.count == query.limit
        )
    }

    /// Fetches detailed run information for SRA IDs.
    private func fetchRunInfo(ids: [String]) async throws -> [SRARunInfo] {
        // Use NCBI EFetch to get run info
        let url = URL(string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi")!
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "db", value: "sra"),
            URLQueryItem(name: "id", value: ids.joined(separator: ",")),
            URLQueryItem(name: "rettype", value: "runinfo"),
            URLQueryItem(name: "retmode", value: "csv")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Lungfish Genome Explorer", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let data = try await fetchRunInfoData(request: request)

        guard let content = String(data: data, encoding: .utf8) else {
            throw SRAError.parseError("Invalid encoding")
        }

        return parseRunInfoCSV(content)
    }

    private func fetchRunInfoData(request: URLRequest) async throws -> Data {
        var attempt = 1
        var retryDelay = Self.initialRunInfoRetryDelayNanoseconds

        while true {
            do {
                let (data, response) = try await httpClient.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw SRAError.fetchFailed("Failed to fetch run info")
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    if Self.retryableHTTPStatusCodes.contains(httpResponse.statusCode),
                       attempt < Self.maxRunInfoFetchAttempts {
                        logger.warning(
                            "Transient SRA run info fetch failure (HTTP \(httpResponse.statusCode, privacy: .public)) on attempt \(attempt, privacy: .public); retrying"
                        )
                        try await Task.sleep(nanoseconds: retryDelay)
                        attempt += 1
                        retryDelay *= 2
                        continue
                    }

                    throw SRAError.fetchFailed("Failed to fetch run info")
                }

                return data
            } catch {
                if error is CancellationError {
                    throw error
                }

                if let urlError = error as? URLError,
                   Self.retryableURLErrorCodes.contains(urlError.code),
                   attempt < Self.maxRunInfoFetchAttempts {
                    logger.warning(
                        "Transient SRA run info transport failure (\(urlError.code.rawValue, privacy: .public)) on attempt \(attempt, privacy: .public); retrying"
                    )
                    try await Task.sleep(nanoseconds: retryDelay)
                    attempt += 1
                    retryDelay *= 2
                    continue
                }

                if let sraError = error as? SRAError {
                    throw sraError
                }

                throw SRAError.fetchFailed("Failed to fetch run info")
            }
        }
    }

    /// Parses CSV run info from NCBI.
    ///
    /// NCBI efetch returns CSV without headers. The known column order is:
    /// Run, ReleaseDate, LoadDate, spots, bases, spots_with_mates, avgLength, size_MB,
    /// AssemblyName, download_path, Experiment, LibraryName, LibraryStrategy, LibrarySelection,
    /// LibrarySource, LibraryLayout, InsertSize, InsertDev, Platform, Model, SRAStudy, BioProject,
    /// Study_Pubmed_id, ProjectID, Sample, BioSample, SampleType, TaxID, ScientificName, SampleName, ...
    private func parseRunInfoCSV(_ csv: String) -> [SRARunInfo] {
        let lines = csv.components(separatedBy: "\n")
        guard !lines.isEmpty else { return [] }

        // Check if first line looks like a header (starts with "Run,")
        let firstLine = lines[0]
        let hasHeader = firstLine.hasPrefix("Run,")

        // Column indices (0-based) for headerless CSV
        // These are based on NCBI's fixed output format
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
        _ = 19  // modelIdx - reserved for future use
        let studyIdx = 20
        let bioprojectIdx = 21
        let sampleIdx = 24
        let biosampleIdx = 25
        _ = 27  // taxIdIdx - reserved for future use
        let scientificNameIdx = 28

        var runs: [SRARunInfo] = []

        // If there's a header, skip it; otherwise process all lines
        let dataLines = hasHeader ? Array(lines.dropFirst()) : lines

        for line in dataLines where !line.isEmpty {
            let fields = parseCSVLine(line)
            guard fields.count > runIdx, !fields[runIdx].isEmpty else { continue }

            let run = SRARunInfo(
                accession: fields[safe: runIdx] ?? "",
                experiment: fields[safe: experimentIdx],
                sample: fields[safe: sampleIdx],
                study: fields[safe: studyIdx],
                bioproject: fields[safe: bioprojectIdx],
                biosample: fields[safe: biosampleIdx],
                organism: fields[safe: scientificNameIdx],
                platform: fields[safe: platformIdx],
                libraryStrategy: fields[safe: libraryStrategyIdx],
                librarySource: fields[safe: librarySourceIdx],
                libraryLayout: fields[safe: libraryLayoutIdx],
                spots: Int(fields[safe: spotsIdx] ?? ""),
                bases: Int(fields[safe: basesIdx] ?? ""),
                avgLength: Int(fields[safe: avgLengthIdx] ?? ""),
                size: Int(fields[safe: sizeMBIdx] ?? ""),
                releaseDate: parseDate(fields[safe: releaseDateIdx])
            )

            if !run.accession.isEmpty {
                runs.append(run)
            }
        }

        return runs
    }

    /// Parses a CSV line handling quoted fields.
    private func parseCSVLine(_ line: String) -> [String] {
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

    private func parseDate(_ dateStr: String?) -> Date? {
        guard let str = dateStr, !str.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: str)
    }

    // MARK: - Download

    /// Downloads FASTQ files for an SRA run.
    ///
    /// Requires SRA Toolkit (prefetch + fasterq-dump) to be installed.
    ///
    /// - Parameters:
    ///   - accession: SRA run accession (e.g., SRR11140748)
    ///   - outputDir: Directory for output files (defaults to temp)
    ///   - progress: Optional progress callback (0.0-1.0)
    /// - Returns: URLs to downloaded FASTQ files
    public func downloadFASTQ(
        accession: String,
        outputDir: URL? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [URL] {
        guard let toolkit = resolvedSRAToolkitExecutables() else {
            throw SRAError.toolkitNotFound
        }

        let outputDirectory = outputDir ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("sra_downloads")

        // Create output directory
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        logger.info("Downloading SRA run \(accession, privacy: .public) to \(outputDirectory.path, privacy: .public)")

        // Step 1: Prefetch the SRA file
        progress?(0.1)
        let prefetchResult = try await runCommand(
            toolkit.prefetch.path,
            arguments: [accession, "-O", outputDirectory.path]
        )

        if prefetchResult.exitCode != 0 {
            logger.error("prefetch failed: \(prefetchResult.stderr, privacy: .public)")
            throw SRAError.downloadFailed(prefetchResult.stderr)
        }

        progress?(0.5)

        // Step 2: Convert to FASTQ with fasterq-dump
        let sraFile = outputDirectory
            .appendingPathComponent(accession)
            .appendingPathComponent("\(accession).sra")
        let fasterqTempDirectory = try Self.createFasterqTempDirectory(for: outputDirectory)
        defer { try? FileManager.default.removeItem(at: fasterqTempDirectory) }

        let fasterqResult = try await runCommand(
            toolkit.fasterqDump.path,
            arguments: [
                sraFile.path,
                "-O", outputDirectory.path,
                "-t", fasterqTempDirectory.path,
                "--split-files",  // Split paired reads
                "--threads", "4"
            ]
        )

        if fasterqResult.exitCode != 0 {
            logger.error("fasterq-dump failed: \(fasterqResult.stderr, privacy: .public)")
            throw SRAError.conversionFailed(fasterqResult.stderr)
        }

        progress?(0.9)

        // Find the output FASTQ files
        let files = try FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        let fastqFiles = files.filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory != true else { return false }
            let lowercaseName = url.lastPathComponent.lowercased()
            return lowercaseName.hasSuffix(".fastq")
                || lowercaseName.hasSuffix(".fq")
                || lowercaseName.hasSuffix(".fastq.gz")
                || lowercaseName.hasSuffix(".fq.gz")
        }

        progress?(1.0)

        logger.info("Downloaded \(fastqFiles.count, privacy: .public) FASTQ files for \(accession, privacy: .public)")

        return fastqFiles
    }

    /// Downloads FASTQ via ENA (alternative to SRA Toolkit).
    ///
    /// This method downloads directly from ENA's FTP/HTTP servers,
    /// which doesn't require the SRA Toolkit.
    ///
    /// - Parameters:
    ///   - accession: SRA/ENA run accession
    ///   - outputDir: Output directory
    ///   - progress: Progress callback
    /// - Returns: URLs to downloaded files
    public func downloadFASTQFromENA(
        accession: String,
        outputDir: URL? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [URL] {
        let outputDirectory = outputDir ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("sra_downloads")

        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        // Prefer ENA Portal-reported FASTQ URLs (authoritative for run layout/path).
        var candidateURLs: [URL] = []
        do {
            let enaService = ENAService(httpClient: httpClient)
            let records = try await enaService.searchReads(term: accession, limit: 1)
            if let record = records.first {
                let portalURLs = await enaService.fastqHTTPURLs(for: record)
                if !portalURLs.isEmpty {
                    candidateURLs = portalURLs
                    logger.info("Resolved \(portalURLs.count, privacy: .public) FASTQ URL(s) for \(accession, privacy: .public) via ENA portal")
                }
            }
        } catch {
            logger.warning("ENA portal URL resolution failed for \(accession, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        // Fallback: construct known ENA FTP path variants.
        if candidateURLs.isEmpty {
            // Format examples:
            // - SRR11140748 -> /vol1/fastq/SRR111/048/SRR11140748/SRR11140748_1.fastq.gz
            // - SRR390728   -> /vol1/fastq/SRR390/SRR390728/SRR390728.fastq.gz
            let prefix = String(accession.prefix(6))
            let middle = accession.count > 9 ? "/\(String(accession.suffix(3)))" : ""
            let baseURL = "https://ftp.sra.ebi.ac.uk/vol1/fastq/\(prefix)\(middle)/\(accession)"
            candidateURLs = ["_1.fastq.gz", "_2.fastq.gz", ".fastq.gz"].compactMap {
                URL(string: "\(baseURL)/\(accession)\($0)")
            }
            logger.warning("Falling back to heuristic ENA URL construction for \(accession, privacy: .public)")
        }

        var downloadedFiles: [URL] = []
        var attemptedURLs: [String] = []
        let totalCandidates = max(candidateURLs.count, 1)
        for (index, fileURL) in candidateURLs.enumerated() {
            let filename = fileURL.lastPathComponent.isEmpty
                ? "\(accession)_\(index + 1).fastq.gz"
                : fileURL.lastPathComponent
            let localPath = outputDirectory.appendingPathComponent(filename)
            attemptedURLs.append(fileURL.absoluteString)

            do {
                logger.info("Attempting to download from ENA: \(fileURL.absoluteString, privacy: .public)")

                var request = URLRequest(url: fileURL)
                request.setValue("Lungfish Genome Explorer", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 600

                let (data, response) = try await httpClient.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    continue
                }

                try data.write(to: localPath)
                downloadedFiles.append(localPath)
                progress?(Double(index + 1) / Double(totalCandidates))

                logger.info("Downloaded: \(localPath.lastPathComponent, privacy: .public)")
            } catch {
                logger.warning("ENA FASTQ download failed for \(fileURL.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
        }

        if downloadedFiles.isEmpty {
            let attemptedPreview = attemptedURLs.prefix(3).joined(separator: ", ")
            throw SRAError.downloadFailed(
                "Could not download FASTQ files from ENA for \(accession). Attempted URLs: \(attemptedPreview)"
            )
        }

        progress?(1.0)

        return downloadedFiles
    }

    // MARK: - SRA Toolkit Detection

    internal static func managedExecutableURL(
        executableName: String,
        homeDirectory: URL
    ) -> URL {
        ManagedStorageConfigStore(homeDirectory: homeDirectory)
            .currentLocation()
            .condaRootURL
            .appendingPathComponent("envs", isDirectory: true)
            .appendingPathComponent("sra-tools", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(executableName)
    }

    internal static func createFasterqTempDirectory(for outputDirectory: URL) throws -> URL {
        let fm = FileManager.default
        let baseDirectory: URL
        if let projectRoot = findProjectRoot(containing: outputDirectory) {
            baseDirectory = projectRoot.appendingPathComponent(".tmp", isDirectory: true)
        } else {
            baseDirectory = outputDirectory
        }

        try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let tempDirectory = baseDirectory.appendingPathComponent(
            "fasterq-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: tempDirectory, withIntermediateDirectories: false)
        return tempDirectory
    }

    internal static func findProjectRoot(containing url: URL) -> URL? {
        let fm = FileManager.default
        var current = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: current.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            current = current.deletingLastPathComponent()
        }

        while true {
            if current.pathExtension.lowercased() == "lungfish" {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.standardizedFileURL == current {
                return nil
            }
            current = parent
        }
    }

    private func resolvedSRAToolkitExecutables() -> (prefetch: URL, fasterqDump: URL)? {
        let homeDirectory = homeDirectoryProvider()
        let prefetchURL = Self.managedExecutableURL(
            executableName: "prefetch",
            homeDirectory: homeDirectory
        )
        let fasterqDumpURL = Self.managedExecutableURL(
            executableName: "fasterq-dump",
            homeDirectory: homeDirectory
        )

        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: prefetchURL.path),
              fileManager.isExecutableFile(atPath: fasterqDumpURL.path) else {
            logger.warning("SRA Toolkit not found in managed environment")
            return nil
        }

        return (prefetch: prefetchURL, fasterqDump: fasterqDumpURL)
    }

    /// Checks if SRA Toolkit is available.
    public var isSRAToolkitAvailable: Bool {
        resolvedSRAToolkitExecutables() != nil
    }

    // MARK: - Process Execution

    private struct CommandResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private func runCommand(_ path: String, arguments: [String]) async throws -> CommandResult {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                    let result = CommandResult(
                        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                        stderr: String(data: stderrData, encoding: .utf8) ?? "",
                        exitCode: process.terminationStatus
                    )

                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - SRA Search Results

/// Results from an SRA search.
public struct SRASearchResults: Sendable {
    /// Total count of matching runs
    public let totalCount: Int

    /// SRA run information
    public let runs: [SRARunInfo]

    /// Whether more results are available
    public let hasMore: Bool

    public init(totalCount: Int, runs: [SRARunInfo], hasMore: Bool = false) {
        self.totalCount = totalCount
        self.runs = runs
        self.hasMore = hasMore
    }
}

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

// MARK: - SRA Errors

/// Errors from SRA operations.
public enum SRAError: Error, LocalizedError {
    case toolkitNotFound
    case downloadFailed(String)
    case conversionFailed(String)
    case fetchFailed(String)
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .toolkitNotFound:
            return "SRA Toolkit not found in the managed Lungfish tool environment."
        case .downloadFailed(let message):
            return "Download failed: \(message)"
        case .conversionFailed(let message):
            return "FASTQ conversion failed: \(message)"
        case .fetchFailed(let message):
            return "Failed to fetch SRA info: \(message)"
        case .parseError(let message):
            return "Parse error: \(message)"
        }
    }
}

// MARK: - Array Extension

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0 && index < count else { return nil }
        return self[index]
    }
}
