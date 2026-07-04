// BlastService.swift - NCBI BLAST URL API client
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

/// Logger for BLAST service operations.
private let logger = Logger(subsystem: LogSubsystem.core, category: "BlastService")

// MARK: - BlastService

/// Actor-isolated client for the NCBI BLAST URL API.
///
/// ``BlastService`` provides a complete interface for submitting nucleotide
/// sequences to the NCBI BLAST service, polling for completion, and parsing
/// results in JSON2 format.
///
/// ## Rate Limiting
///
/// The actor enforces NCBI rate limits internally:
/// - Minimum 10 seconds between submissions
/// - Minimum 15 seconds between polls for the same RID
/// - Includes `tool=lungfish` identifier in all requests
///
/// ## Usage
///
/// ```swift
/// let service = BlastService.shared
///
/// let request = BlastVerificationRequest(
///     taxonName: "Oxbow virus",
///     taxId: 2560178,
///     sequences: [("read1", "ATGCGATCGA...")]
/// )
///
/// let result = try await service.verify(request: request, progress: { fraction, message in
///     print("\(Int(fraction * 100))%: \(message)")
/// })
///
/// print("Confidence: \(result.confidence)")
/// ```
public actor BlastService {

    /// Shared singleton instance.
    public static let shared = BlastService()

    // MARK: - Constants

    /// Base URL for the NCBI BLAST CGI endpoint.
    nonisolated let blastBaseURL = URL(string: "https://blast.ncbi.nlm.nih.gov/blast/Blast.cgi")!

    /// Tool identifier sent with all BLAST requests (NCBI policy).
    private let toolName = "lungfish"

    /// Email placeholder sent with BLAST requests (NCBI policy).
    private let toolEmail = "lungfish-app@users.noreply.github.com"

    /// Minimum interval between status polls (NCBI guideline: at least 10 seconds).
    private let minPollInterval: TimeInterval = 10.0

    /// Default maximum time to wait for a BLAST job to complete.
    private let defaultTimeout: TimeInterval = 600.0 // 10 minutes

    /// Maximum attempts for transient network/transport failures.
    private let maxNetworkRetryAttempts = 3

    /// Initial retry backoff delay (seconds).
    private let initialRetryBackoff: TimeInterval = 1.0

    /// Maximum retry backoff delay (seconds).
    private let maxRetryBackoff: TimeInterval = 8.0

    /// Identity threshold for a "verified" verdict (percentage).
    nonisolated let verifiedIdentityThreshold: Double = 90.0

    /// Query coverage threshold for a "verified" verdict (percentage).
    nonisolated let verifiedCoverageThreshold: Double = 80.0

    // MARK: - State

    /// The HTTP client used for requests (injectable for testing).
    private let httpClient: HTTPClient

    /// Local NCBI BLAST etiquette limits.
    private let rateLimits: BlastRateLimitConfiguration

    /// Timestamp of the last BLAST submission (for rate limiting).
    private var lastSubmitTime: Date?

    /// Number of currently active NCBI BLAST submission requests.
    private var activeSubmissionCount = 0

    /// Rolling one-hour sequence submission ledger.
    private var submittedSequenceEvents: [(date: Date, count: Int)] = []

    // MARK: - Initialization

    /// Creates a new BLAST service.
    ///
    /// - Parameters:
    ///   - httpClient: HTTP client for making requests (defaults to URLSession).
    ///   - rateLimits: Local submission limits for NCBI BLAST etiquette.
    public init(
        httpClient: HTTPClient = URLSessionHTTPClient(),
        rateLimits: BlastRateLimitConfiguration = .ncbiDefault
    ) {
        self.httpClient = httpClient
        self.rateLimits = rateLimits
    }

    // MARK: - Request Building

    /// Builds a BLAST verification request using pre-fetched read IDs.
    ///
    /// Use this overload when read IDs have already been looked up via
    /// ``KrakenIndexDatabase`` for O(k) indexed access instead of O(n)
    /// linear scanning.
    ///
    /// - Parameters:
    ///   - taxonName: Display name of the taxon
    ///   - taxId: NCBI taxonomy ID
    ///   - matchingReadIds: Pre-fetched read IDs for the target taxon(s)
    ///   - sourceURL: Path to source FASTQ file
    ///   - readCount: Number of reads to subsample (default 20)
    /// - Returns: A ready-to-submit BlastVerificationRequest
    public func buildVerificationRequestFromReadIds(
        taxonName: String,
        taxId: Int,
        matchingReadIds: Set<String>,
        sourceURL: URL,
        readCount: Int = 20
    ) async throws -> BlastVerificationRequest {
        logger.info("buildVerificationRequestFromReadIds: taxon=\(taxonName, privacy: .public) taxId=\(taxId, privacy: .public) matchingReadIds=\(matchingReadIds.count, privacy: .public) readCount=\(readCount, privacy: .public)")
        logger.info("buildVerificationRequestFromReadIds: sourceURL=\(sourceURL.path, privacy: .public)")

        guard !matchingReadIds.isEmpty else {
            logger.error("buildVerificationRequestFromReadIds: no matching read IDs provided")
            throw BlastServiceError.noSequences
        }

        return try await extractSequencesAndBuild(
            taxonName: taxonName,
            taxId: taxId,
            matchingReadIds: matchingReadIds,
            sourceURL: sourceURL,
            readCount: readCount
        )
    }

    /// Builds a BLAST verification request by subsampling reads from classification output.
    ///
    /// This is a convenience method that handles:
    /// 1. Scanning the Kraken2 per-read output for matching read IDs
    /// 2. Extracting sequences from the source FASTQ
    /// 3. Subsampling to the requested count
    /// 4. Building the BlastVerificationRequest
    ///
    /// - Parameters:
    ///   - taxonName: Display name of the taxon
    ///   - taxId: NCBI taxonomy ID
    ///   - targetTaxIds: All tax IDs to match (including descendants)
    ///   - classificationOutputURL: Path to Kraken2 per-read output
    ///   - sourceURL: Path to source FASTQ file
    ///   - readCount: Number of reads to subsample (default 20)
    /// - Returns: A ready-to-submit BlastVerificationRequest
    public func buildVerificationRequest(
        taxonName: String,
        taxId: Int,
        targetTaxIds: Set<Int>,
        classificationOutputURL: URL,
        sourceURL: URL,
        readCount: Int = 20
    ) async throws -> BlastVerificationRequest {
        logger.info("buildVerificationRequest: taxon=\(taxonName, privacy: .public) taxId=\(taxId, privacy: .public) targetTaxIds=\(targetTaxIds.count, privacy: .public) readCount=\(readCount, privacy: .public)")
        logger.info("buildVerificationRequest: classificationOutput=\(classificationOutputURL.path, privacy: .public)")
        logger.info("buildVerificationRequest: sourceURL=\(sourceURL.path, privacy: .public)")

        // Scan Kraken2 output for matching read IDs
        var matchingReadIds = Set<String>()
        let classificationExists = FileManager.default.fileExists(atPath: classificationOutputURL.path)
        logger.info("buildVerificationRequest: classification file exists=\(classificationExists, privacy: .public)")

        if classificationExists {
            let scanResult = try scanKrakenClassificationOutput(
                classificationOutputURL,
                targetTaxIds: targetTaxIds
            )
            matchingReadIds = scanResult.matchingReadIds
            logger.info("buildVerificationRequest: scanned \(scanResult.totalClassified, privacy: .public) classified reads, \(matchingReadIds.count, privacy: .public) match target taxIds")
        } else {
            logger.error("buildVerificationRequest: classification output file not found at \(classificationOutputURL.path, privacy: .public)")
        }

        guard !matchingReadIds.isEmpty else {
            logger.error("buildVerificationRequest: no matching read IDs found — cannot proceed with BLAST")
            throw BlastServiceError.noSequences
        }

        return try await extractSequencesAndBuild(
            taxonName: taxonName,
            taxId: taxId,
            matchingReadIds: matchingReadIds,
            sourceURL: sourceURL,
            readCount: readCount
        )
    }

    private func scanKrakenClassificationOutput(
        _ classificationOutputURL: URL,
        targetTaxIds: Set<Int>
    ) throws -> (matchingReadIds: Set<String>, totalClassified: Int) {
        let isGzip = classificationOutputURL.pathExtension.lowercased() == "gz"
        let fileHandle: FileHandle
        let gzipProcess: Process?
        let gzipStderr: Pipe?

        if isGzip {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            process.arguments = ["-dc", classificationOutputURL.path]
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            fileHandle = stdout.fileHandleForReading
            gzipProcess = process
            gzipStderr = stderr
        } else {
            guard let handle = FileHandle(forReadingAtPath: classificationOutputURL.path) else {
                throw BlastServiceError.noSequences
            }
            fileHandle = handle
            gzipProcess = nil
            gzipStderr = nil
        }

        var matchingReadIds = Set<String>()
        var totalClassified = 0
        var residual = Data()
        let bufferSize = 1_048_576

        while true {
            let chunk = fileHandle.readData(ofLength: bufferSize)
            if chunk.isEmpty { break }

            var data = residual + chunk
            residual = Data()

            if let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
                if lastNewline < data.endIndex - 1 {
                    residual = data[(lastNewline + 1)...]
                    data = data[...lastNewline]
                }
            } else {
                residual = data
                continue
            }

            if let text = String(data: data, encoding: .utf8) {
                collectKrakenBlastReadIds(
                    from: text,
                    targetTaxIds: targetTaxIds,
                    matchingReadIds: &matchingReadIds,
                    totalClassified: &totalClassified
                )
            }
        }

        if !residual.isEmpty, let text = String(data: residual, encoding: .utf8) {
            collectKrakenBlastReadIds(
                from: text,
                targetTaxIds: targetTaxIds,
                matchingReadIds: &matchingReadIds,
                totalClassified: &totalClassified
            )
        }

        fileHandle.closeFile()
        if let gzipProcess {
            gzipProcess.waitUntilExit()
            guard gzipProcess.terminationStatus == 0 else {
                throw Self.gzipFailure(
                    path: classificationOutputURL.path,
                    status: gzipProcess.terminationStatus,
                    stderr: gzipStderr
                )
            }
        }

        return (matchingReadIds, totalClassified)
    }

    private func collectKrakenBlastReadIds(
        from text: String,
        targetTaxIds: Set<Int>,
        matchingReadIds: inout Set<String>,
        totalClassified: inout Int
    ) {
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: "\t", maxSplits: 3)
            guard cols.count >= 3, cols[0] == "C" else { continue }
            totalClassified += 1
            if let tid = Int(cols[2].trimmingCharacters(in: .whitespaces)),
               targetTaxIds.contains(tid) {
                var readId = String(cols[1].trimmingCharacters(in: .whitespaces))
                if readId.hasSuffix("/1") || readId.hasSuffix("/2") {
                    readId = String(readId.dropLast(2))
                }
                matchingReadIds.insert(readId)
            }
        }
    }

    /// Shared implementation: extracts sequences from FASTQ, subsamples, and builds the request.
    private func extractSequencesAndBuild(
        taxonName: String,
        taxId: Int,
        matchingReadIds: Set<String>,
        sourceURL: URL,
        readCount: Int
    ) async throws -> BlastVerificationRequest {

        // Extract sequences from FASTQ (handles both raw and gzip-compressed files)
        let sourceExists = FileManager.default.fileExists(atPath: sourceURL.path)
        let isGzip = sourceURL.pathExtension.lowercased() == "gz"
        logger.info("buildVerificationRequest: source FASTQ exists=\(sourceExists, privacy: .public) gzip=\(isGzip, privacy: .public)")

        // Extract sequences from FASTQ, with retry for gzip subprocess failures.
        // The gzip subprocess can be killed by macOS XPC interruptions, so we
        // retry once before giving up.
        let allSequences = try extractMatchingSequences(
            from: sourceURL,
            matchingReadIds: matchingReadIds,
            isGzip: isGzip
        )

        logger.info("extractSequencesAndBuild: extracted \(allSequences.count, privacy: .public) sequences from FASTQ (matched \(matchingReadIds.count, privacy: .public) read IDs)")

        guard !allSequences.isEmpty else {
            logger.error("extractSequencesAndBuild: found \(matchingReadIds.count, privacy: .public) matching read IDs but 0 sequences in FASTQ — source file may be missing or read IDs may not match")
            throw BlastServiceError.noSequences
        }

        // Subsample
        let strategy = SubsampleStrategy.mixed(longest: min(5, readCount / 4), random: readCount - min(5, readCount / 4))
        let subsampled = subsampleReads(from: allSequences, strategy: strategy)

        logger.info("buildVerificationRequest: subsampled to \(subsampled.count, privacy: .public) reads")

        return BlastVerificationRequest(
            taxonName: taxonName,
            taxId: taxId,
            sequences: subsampled,
            entrezQuery: nil
        )
    }

    // MARK: - High-Level API

    /// Submits reads for BLAST verification against a specific taxon.
    ///
    /// This is the primary entry point for the verification pipeline. It:
    /// 1. Formats sequences as multi-FASTA
    /// 2. Submits to NCBI BLAST
    /// 3. Polls for completion
    /// 4. Parses results
    /// 5. Assigns verdicts to each read
    ///
    /// - Parameters:
    ///   - request: The verification request with sequences and parameters
    ///   - progress: Optional callback for progress updates (fraction 0-1, message)
    /// - Returns: The verification result with per-read verdicts and summary
    /// - Throws: ``BlastServiceError`` if submission, polling, or parsing fails
    public func verify(
        request: BlastVerificationRequest,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> BlastVerificationResult {
        guard !request.sequences.isEmpty else {
            throw BlastServiceError.noSequences
        }

        let submittedAt = Date()
        let fasta = request.toMultiFASTA()
        let extraParameters = try BlastVerificationRequest.parseBlastURLAPIExtraParameters(request.extraArgs)

        // Phase 1: Submit
        progress?(0.15, "Submitting \(request.sequences.count) reads to NCBI BLAST...")
        logger.info("Submitting BLAST job: \(request.sequences.count, privacy: .public) reads, taxon=\(request.taxonName, privacy: .public) (txid\(request.taxId, privacy: .public))")

        let submission = try await submit(
            query: fasta,
            program: request.program,
            database: request.database,
            entrezQuery: request.entrezQuery,
            evalue: request.eValueThreshold,
            maxTargetSeqs: request.maxTargetSeqs,
            megablast: request.program == "blastn",
            sequenceCount: request.sequences.count,
            extraParameters: extraParameters,
            maxConcurrentSubmissions: request.maxConcurrentSubmissions
        )

        logger.info("BLAST job submitted: RID=\(submission.rid, privacy: .public), RTOE=\(submission.rtoe, privacy: .public)s")

        // Phase 2: Poll for results
        progress?(0.20, "BLAST job submitted (RID: \(submission.rid)). Waiting for results...")

        let searchResults = try await pollForResults(
            rid: submission.rid,
            initialWait: submission.rtoe,
            timeout: defaultTimeout,
            progress: progress
        )

        // Phase 3: Assign verdicts
        progress?(0.90, "Parsing BLAST results...")

        // Build a sequence map from the request for querySequence population
        let sequenceMap = Dictionary(
            request.sequences.map { ($0.id, $0.sequence) },
            uniquingKeysWith: { first, _ in first }
        )

        let readResults = assignVerdicts(
            searchResults: searchResults,
            eValueThreshold: request.eValueThreshold,
            sequenceMap: sequenceMap,
            queriedTaxonName: request.taxonName
        )

        let completedAt = Date()
        progress?(1.0, "BLAST verification complete")

        logger.info("BLAST verification complete: \(readResults.filter { $0.verdict == .verified }.count, privacy: .public)/\(readResults.count, privacy: .public) verified")

        return BlastVerificationResult(
            taxonName: request.taxonName,
            taxId: request.taxId,
            readResults: readResults,
            submittedAt: submittedAt,
            completedAt: completedAt,
            rid: submission.rid,
            blastProgram: request.program,
            database: request.database
        )
    }

    // MARK: - FASTQ Sequence Extraction

    /// Extracts matching sequences from a FASTQ file (raw or gzip-compressed).
    ///
    /// For gzip files, pipes through `/usr/bin/gzip -dc`. If the subprocess
    /// fails (e.g., killed by macOS XPC interruptions), retries once with a
    /// brief delay. This addresses intermittent failures observed when the
    /// system terminates background subprocesses during network activity.
    ///
    /// - Parameters:
    ///   - sourceURL: Path to the FASTQ file (raw or .gz)
    ///   - matchingReadIds: Set of read IDs to extract
    ///   - isGzip: Whether the file is gzip-compressed
    /// - Returns: Array of (id, sequence) pairs
    private func extractMatchingSequences(
        from sourceURL: URL,
        matchingReadIds: Set<String>,
        isGzip: Bool
    ) throws -> [(id: String, sequence: String)] {
        let maxAttempts = isGzip ? 2 : 1  // Retry only for gzip (subprocess can fail)

        for attempt in 1...maxAttempts {
            let sequences: [(id: String, sequence: String)]
            do {
                sequences = try extractMatchingSequencesOnce(
                    from: sourceURL,
                    matchingReadIds: matchingReadIds,
                    isGzip: isGzip
                )
            } catch {
                if isGzip, attempt < maxAttempts {
                    logger.warning("extractMatchingSequences: gzip attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public); retrying...")
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }
                throw error
            }

            if !sequences.isEmpty || !isGzip {
                return sequences
            }

            // Gzip subprocess returned 0 sequences — likely killed by OS.
            // Retry once after a brief delay.
            if attempt < maxAttempts {
                logger.warning("extractMatchingSequences: gzip returned 0 sequences on attempt \(attempt, privacy: .public), retrying...")
                Thread.sleep(forTimeInterval: 0.5)
            }
        }

        return []
    }

    /// Single-attempt sequence extraction from a FASTQ file.
    private func extractMatchingSequencesOnce(
        from sourceURL: URL,
        matchingReadIds: Set<String>,
        isGzip: Bool
    ) throws -> [(id: String, sequence: String)] {
        var allSequences: [(id: String, sequence: String)] = []
        let handle: FileHandle?
        var gzipProcess: Process?
        var gzipStderr: Pipe?

        if isGzip {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            proc.arguments = ["-dc", sourceURL.path]
            let pipe = Pipe()
            let stderr = Pipe()
            proc.standardOutput = pipe
            proc.standardError = stderr
            do {
                try proc.run()
            } catch {
                logger.error("extractMatchingSequences: failed to launch gzip: \(error.localizedDescription, privacy: .public)")
                throw BlastServiceError.noSequences
            }
            handle = pipe.fileHandleForReading
            gzipProcess = proc
            gzipStderr = stderr
        } else {
            handle = FileHandle(forReadingAtPath: sourceURL.path)
            gzipProcess = nil
            gzipStderr = nil
        }

        if let handle {
            defer {
                handle.closeFile()
            }
            var lineBuffer: [String] = []
            var residual = ""
            let bufferSize = 4_194_304
            var totalBytesRead = 0
            var totalRecords = 0
            var chunksRead = 0
            var utf8Failures = 0

            while true {
                let chunk = handle.readData(ofLength: bufferSize)
                if chunk.isEmpty { break }
                chunksRead += 1
                totalBytesRead += chunk.count
                guard let text = String(data: chunk, encoding: .utf8) else {
                    utf8Failures += 1
                    continue
                }
                let combined = residual + text
                residual = ""
                var lines = combined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                if !combined.hasSuffix("\n") && !lines.isEmpty {
                    residual = lines.removeLast()
                }
                for line in lines {
                    // Skip empty strings (produced by split when chunk ends
                    // with \n). These break the 4-line FASTQ record alignment.
                    if line.isEmpty { continue }
                    lineBuffer.append(line)
                    if lineBuffer.count == 4 {
                        if lineBuffer[0].hasPrefix("@") {
                            totalRecords += 1
                            var readId = String(lineBuffer[0].dropFirst())
                                .split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                            if readId.hasSuffix("/1") || readId.hasSuffix("/2") {
                                readId = String(readId.dropLast(2))
                            }
                            if matchingReadIds.contains(readId) {
                                allSequences.append((id: readId, sequence: lineBuffer[1]))
                            }
                        }
                        lineBuffer.removeAll(keepingCapacity: true)
                    }
                }
            }

            // Check gzip exit status
            if let proc = gzipProcess {
                proc.waitUntilExit()
                let status = proc.terminationStatus
                logger.info("extractMatchingSequences: gzip exited with status \(status, privacy: .public), read \(chunksRead, privacy: .public) chunks (\(totalBytesRead, privacy: .public) bytes), \(totalRecords, privacy: .public) FASTQ records, \(utf8Failures, privacy: .public) UTF8 failures, \(allSequences.count, privacy: .public) matched")
                guard status == 0 else {
                    throw Self.gzipFailure(
                        path: sourceURL.path,
                        status: status,
                        stderr: gzipStderr
                    )
                }
            } else {
                logger.info("extractMatchingSequences: read \(chunksRead, privacy: .public) chunks (\(totalBytesRead, privacy: .public) bytes), \(totalRecords, privacy: .public) FASTQ records, \(allSequences.count, privacy: .public) matched")
            }
        }

        return allSequences
    }

    // MARK: - Submit (CMD=Put)

    /// Submits a BLAST job to NCBI.
    ///
    /// Sends a POST request with CMD=Put to the BLAST CGI endpoint.
    /// Parses the response for the Request ID (RID) and estimated
    /// time of execution (RTOE).
    ///
    /// - Parameters:
    ///   - query: Multi-FASTA query string
    ///   - program: BLAST program (e.g., "blastn")
    ///   - database: Target database (e.g., "nt")
    ///   - entrezQuery: Optional Entrez query filter
    ///   - evalue: E-value threshold
    ///   - maxTargetSeqs: Maximum target sequences per query
    ///   - megablast: Whether to use megablast algorithm
    ///   - maxConcurrentSubmissions: Maximum in-flight BLAST submissions for this process.
    /// - Returns: The job submission response with RID and RTOE
    /// - Throws: ``BlastServiceError`` on submission failure
    public func submit(
        query: String,
        program: String,
        database: String,
        entrezQuery: String?,
        evalue: Double,
        maxTargetSeqs: Int,
        megablast: Bool,
        sequenceCount: Int = 1,
        extraParameters: [String: String] = [:],
        maxConcurrentSubmissions: Int = 1
    ) async throws -> BlastJobSubmission {
        try await acquireSubmissionSlot(maxConcurrentSubmissions: maxConcurrentSubmissions)
        defer { activeSubmissionCount = max(0, activeSubmissionCount - 1) }

        try await enforceSubmitRateLimit(sequenceCount: sequenceCount)
        let submissionStartedAt = Date()
        lastSubmitTime = submissionStartedAt
        recordSubmission(sequenceCount: sequenceCount, at: submissionStartedAt)

        // Build form-encoded body
        var params: [(String, String)] = [
            ("CMD", "Put"),
            ("PROGRAM", program),
            ("DATABASE", database),
            ("QUERY", query),
            ("EXPECT", String(evalue)),
            ("HITLIST_SIZE", String(maxTargetSeqs)),
            ("MAX_NUM_SEQ", String(maxTargetSeqs)),
            ("FORMAT_TYPE", "JSON2"),
            ("WORD_SIZE", "28"),
            ("TOOL", toolName),
            ("EMAIL", toolEmail),
        ]

        if megablast {
            params.append(("MEGABLAST", "on"))
        }

        if let entrezQuery {
            params.append(("ENTREZ_QUERY", entrezQuery))
        }

        for key in extraParameters.keys.sorted() {
            guard let value = extraParameters[key] else { continue }
            params.removeAll { $0.0.caseInsensitiveCompare(key) == .orderedSame }
            params.append((key, value))
        }

        let body = formEncode(params)

        var request = URLRequest(url: blastBaseURL)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (data, _) = try await requestWithTransportRetry(operation: "submit BLAST job") {
            let (data, response) = try await httpClient.data(for: request)
            let httpResponse = try Self.validateHTTPResponse(
                data,
                response,
                nonHTTPMessage: "Non-HTTP response",
                failureBodyFallback: "(non-UTF8)"
            )
            return (data, httpResponse)
        }

        let responseBody = String(data: data, encoding: .utf8) ?? ""
        return try parseSubmissionResponse(responseBody)
    }

    // MARK: - Poll (CMD=Get)

    /// Checks the status of a BLAST job.
    ///
    /// Sends a GET request with CMD=Get to check whether results are ready.
    /// The NCBI API returns HTML with status markers in a QBlastInfo block.
    ///
    /// - Parameter rid: The Request ID to check
    /// - Returns: The job status
    /// - Throws: ``BlastServiceError`` on HTTP errors
    public func checkStatus(rid: String) async throws -> BlastJobStatus {
        var components = URLComponents(url: blastBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "CMD", value: "Get"),
            URLQueryItem(name: "RID", value: rid),
            URLQueryItem(name: "FORMAT_OBJECT", value: "SearchInfo"),
            URLQueryItem(name: "TOOL", value: toolName),
            URLQueryItem(name: "EMAIL", value: toolEmail),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"

        let (data, _) = try await requestWithTransportRetry(operation: "poll BLAST status (\(rid))") {
            let (data, response) = try await httpClient.data(for: request)
            let httpResponse = try Self.validateHTTPResponse(
                data,
                response,
                nonHTTPMessage: "Status check returned non-HTTP response",
                failureBodyFallback: "Status check failed"
            )
            return (data, httpResponse)
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        return parseStatusResponse(body)
    }

    /// Retrieves BLAST results in JSON2 format.
    ///
    /// - Parameter rid: The Request ID whose results to retrieve
    /// - Returns: Parsed search results for each query sequence
    /// - Throws: ``BlastServiceError`` on HTTP or parsing errors
    public func getResults(rid: String) async throws -> [BlastSearchResult] {
        var components = URLComponents(url: blastBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "CMD", value: "Get"),
            URLQueryItem(name: "RID", value: rid),
            URLQueryItem(name: "FORMAT_TYPE", value: "JSON2"),
            URLQueryItem(name: "FORMAT_OBJECT", value: "Alignment"),
            URLQueryItem(name: "TOOL", value: toolName),
            URLQueryItem(name: "EMAIL", value: toolEmail),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"

        let (data, httpResponse) = try await requestWithTransportRetry(operation: "fetch BLAST results (\(rid))") {
            let (data, response) = try await httpClient.data(for: request)
            let httpResponse = try Self.validateHTTPResponse(
                data,
                response,
                nonHTTPMessage: "Result fetch returned non-HTTP response",
                failureBodyFallback: ""
            )
            return (data, httpResponse)
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
        logger.info("getResults: received \(data.count, privacy: .public) bytes, Content-Type=\(contentType, privacy: .public)")

        // Save raw BLAST response for debugging. Written to the same temp
        // directory the OS cleans up automatically.
        let debugDir = FileManager.default.temporaryDirectory.appendingPathComponent("lungfish-blast-debug")
        try? FileManager.default.createDirectory(at: debugDir, withIntermediateDirectories: true)
        let rawFile = debugDir.appendingPathComponent("\(rid)-raw-response")
        try? data.write(to: rawFile)
        logger.info("getResults: saved raw response to \(rawFile.path, privacy: .public)")

        // NCBI sometimes returns BLAST JSON2 results as a ZIP archive.
        // Detect ZIP magic bytes (PK\x03\x04) and decompress before parsing.
        let resultData: Data
        if data.count >= 4, data[0] == 0x50, data[1] == 0x4B, data[2] == 0x03, data[3] == 0x04 {
            logger.info("getResults: response is a ZIP archive, decompressing")
            resultData = try decompressZIPResponse(data)
        } else {
            resultData = data
        }

        // Save extracted/decompressed content for debugging
        let jsonFile = debugDir.appendingPathComponent("\(rid)-extracted.json")
        try? resultData.write(to: jsonFile)
        logger.info("getResults: saved extracted content to \(jsonFile.path, privacy: .public)")

        return try parseJSON2Results(resultData)
    }

    // MARK: - Poll Loop

    /// Polls for BLAST results until they are ready or timeout is reached.
    ///
    /// - Parameters:
    ///   - rid: The Request ID to poll
    ///   - initialWait: RTOE from submission (seconds to wait before first poll)
    ///   - timeout: Maximum time to wait
    ///   - progress: Progress callback
    /// - Returns: Parsed search results
    /// - Throws: ``BlastServiceError`` on timeout or job failure
    /// Returns the adaptive poll interval for the given attempt number.
    ///
    /// Jobs most often complete shortly after RTOE, so the first few polls
    /// use the NCBI minimum (10 s). After 3 attempts we widen to 15 s, and
    /// after 10 attempts to 30 s to reduce load on long-running searches.
    private func adaptivePollInterval(attempt: Int) -> TimeInterval {
        switch attempt {
        case 1...3:  return 10.0   // aggressive — jobs often finish near RTOE
        case 4...10: return 15.0   // standard
        default:     return 30.0   // back off for long-running jobs
        }
    }

    private func pollForResults(
        rid: String,
        initialWait: Int,
        timeout: TimeInterval,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> [BlastSearchResult] {
        let startTime = Date()

        // Wait the initial RTOE before first poll (minimum 10s per NCBI policy)
        let initialDelay = max(Double(initialWait), minPollInterval)
        logger.info("Waiting \(Int(initialDelay), privacy: .public)s before first poll (RTOE=\(initialWait, privacy: .public)s)")
        try await Task.sleep(for: .seconds(initialDelay))

        var pollCount = 0
        while true {
            try Task.checkCancellation()

            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed >= timeout {
                throw BlastServiceError.timeout(rid: rid, elapsed: elapsed)
            }

            pollCount += 1
            let progressFraction = 0.20 + min(0.70, (elapsed / timeout) * 0.70)
            progress?(progressFraction, "Polling BLAST results (attempt \(pollCount))...")

            logger.debug("Polling BLAST status for RID=\(rid, privacy: .public) (attempt \(pollCount, privacy: .public), elapsed=\(Int(elapsed), privacy: .public)s)")

            let status = try await checkStatus(rid: rid)

            switch status {
            case .ready:
                logger.info("BLAST job \(rid, privacy: .public) is ready after \(Int(elapsed), privacy: .public)s")
                return try await getResults(rid: rid)

            case .waiting(let queuePosition):
                if let queuePosition {
                    progress?(progressFraction, "BLAST job \(rid) is waiting at upstream queue position \(queuePosition).")
                }
                let interval = adaptivePollInterval(attempt: pollCount)
                try await Task.sleep(for: .seconds(interval))

            case .error(let message):
                throw BlastServiceError.jobFailed(rid: rid, message: message)

            case .unknown:
                // RID may not be recognized yet; retry
                logger.warning("BLAST status unknown for RID=\(rid, privacy: .public), retrying...")
                let interval = adaptivePollInterval(attempt: pollCount)
                try await Task.sleep(for: .seconds(interval))
            }
        }
    }

    // MARK: - Verdict Assignment

    /// Assigns a verification verdict to each read based on BLAST results.
    ///
    /// For each query, the top hit's identity, coverage, and E-value are
    /// compared against thresholds:
    /// - **Verified**: >= 90% identity AND >= 80% query coverage AND E-value <= threshold
    /// - **Ambiguous**: Hit found but thresholds not fully met
    /// - **Unverified**: No hits found within the taxon
    ///
    /// Also builds up to 5 ``BlastHitSummary`` entries per read, computes
    /// LCA genus disagreement, and attaches the original query sequence.
    ///
    /// - Parameters:
    ///   - searchResults: Parsed BLAST search results
    ///   - eValueThreshold: E-value threshold for significance
    ///   - sequenceMap: Mapping from read ID to original query sequence (default: empty)
    /// - Returns: Array of per-read verification results
    nonisolated func assignVerdicts(
        searchResults: [BlastSearchResult],
        eValueThreshold: Double,
        sequenceMap: [String: String] = [:],
        queriedTaxonName: String = ""
    ) -> [BlastReadResult] {
        searchResults.map { result in
            assignVerdict(
                for: result,
                eValueThreshold: eValueThreshold,
                sequenceMap: sequenceMap,
                queriedTaxonName: queriedTaxonName
            )
        }
    }

    /// Assigns a verdict for a single query result.
    ///
    /// In addition to alignment-quality thresholds, this now computes whether
    /// the top hit organism matches the queried (Kraken2-classified) taxon at
    /// the genus level or by name containment.
    private nonisolated func assignVerdict(
        for result: BlastSearchResult,
        eValueThreshold: Double,
        sequenceMap: [String: String],
        queriedTaxonName: String
    ) -> BlastReadResult {
        // Find the best HSP across all hits
        guard let topHit = result.hits.first,
              let bestHSP = topHit.hsps.first else {
            // No hits at all
            return BlastReadResult(
                id: result.queryId,
                verdict: .unverified,
                querySequence: sequenceMap[result.queryId]
            )
        }

        let pctIdentity = bestHSP.percentIdentity
        let coverage = bestHSP.queryCoverage(queryLength: result.queryLength)
        let eValue = bestHSP.evalue

        // Determine verdict based on alignment quality
        let verdict: BlastVerdict
        if eValue <= eValueThreshold
            && pctIdentity >= verifiedIdentityThreshold
            && coverage >= verifiedCoverageThreshold {
            verdict = .verified
        } else if !result.hits.isEmpty {
            verdict = .ambiguous
        } else {
            verdict = .unverified
        }

        // Build up to 5 hit summaries sorted by best HSP e-value
        let topHits = buildHitSummaries(
            hits: result.hits,
            queryLength: result.queryLength,
            maxCount: 5
        )

        // Compute LCA genus disagreement across the top hits
        let hasLCADisagreement = computeGenusDisagreement(hits: topHits)

        // Determine whether the top hit matches the queried taxon
        let hitOrganism = topHit.organism ?? topHit.title
        let matchesQueriedTaxon = Self.organismMatchesTaxon(
            hitOrganism: hitOrganism,
            queriedTaxonName: queriedTaxonName
        )

        return BlastReadResult(
            id: result.queryId,
            verdict: verdict,
            topHitOrganism: hitOrganism,
            topHitAccession: topHit.accession,
            percentIdentity: pctIdentity,
            queryCoverage: coverage,
            eValue: eValue,
            alignmentLength: bestHSP.alignLength,
            bitScore: bestHSP.bitScore,
            topHits: topHits,
            querySequence: sequenceMap[result.queryId],
            hasLCADisagreement: hasLCADisagreement,
            matchesQueriedTaxon: matchesQueriedTaxon
        )
    }

    /// Builds an array of ``BlastHitSummary`` from up to `maxCount` hits.
    ///
    /// Each summary uses the best HSP (first) from its hit for statistics.
    ///
    /// - Parameters:
    ///   - hits: All hits for one query
    ///   - queryLength: Length of the query sequence
    ///   - maxCount: Maximum number of summaries to produce
    /// - Returns: Array of hit summaries sorted by E-value (ascending)
    private nonisolated func buildHitSummaries(
        hits: [BlastHit],
        queryLength: Int,
        maxCount: Int
    ) -> [BlastHitSummary] {
        let limitedHits = hits.prefix(maxCount)
        return limitedHits.enumerated().compactMap { rank, hit in
            guard let bestHSP = hit.hsps.first else { return nil }
            return BlastHitSummary(
                rank: rank + 1,
                accession: hit.accession,
                organism: hit.organism,
                taxId: hit.taxId,
                percentIdentity: bestHSP.percentIdentity,
                queryCoverage: bestHSP.queryCoverage(queryLength: queryLength),
                eValue: bestHSP.evalue,
                bitScore: bestHSP.bitScore,
                alignmentLength: bestHSP.alignLength
            )
        }
    }

    /// Determines whether the top hits disagree at genus level.
    ///
    /// Extracts the first word of each organism name (the genus) and checks
    /// whether multiple distinct genera are represented. A count > 1 indicates
    /// LCA disagreement.
    ///
    /// - Parameter hits: Hit summaries to inspect
    /// - Returns: `true` if multiple genera are present among the hits
    nonisolated func computeGenusDisagreement(hits: [BlastHitSummary]) -> Bool {
        let genera = Set(hits.compactMap { $0.organism?.split(separator: " ").first.map(String.init) })
        return genera.count > 1
    }

    /// Determines whether a BLAST hit organism matches the queried taxon.
    ///
    /// Uses a two-tier matching strategy:
    /// 1. **Genus match** (for binomial names): the first word of the hit organism
    ///    matches the first word of the queried taxon (case-insensitive).
    ///    Example: "Escherichia coli K-12" matches queried "Escherichia coli".
    /// 2. **Containment match** (for virus names that are not binomial): the hit
    ///    organism contains the queried taxon name or vice versa (case-insensitive).
    ///    Example: "Oxbow virus isolate ABC" matches queried "Oxbow virus".
    ///
    /// - Parameters:
    ///   - hitOrganism: The organism name from the BLAST hit.
    ///   - queriedTaxonName: The taxon name from the Kraken2 classification.
    /// - Returns: `true` if the organisms are considered a match.
    static nonisolated func organismMatchesTaxon(
        hitOrganism: String,
        queriedTaxonName: String
    ) -> Bool {
        guard !hitOrganism.isEmpty, !queriedTaxonName.isEmpty else { return false }

        let hitLower = hitOrganism.lowercased()
        let queriedLower = queriedTaxonName.lowercased()

        // Strategy 1: Genus-level match (first word of binomial name)
        let hitGenus = hitLower.split(separator: " ").first.map(String.init) ?? hitLower
        let queriedGenus = queriedLower.split(separator: " ").first.map(String.init) ?? queriedLower

        if hitGenus == queriedGenus && !hitGenus.isEmpty {
            return true
        }

        // Strategy 2: Containment match (handles virus names like "Oxbow virus")
        if hitLower.contains(queriedLower) || queriedLower.contains(hitLower) {
            return true
        }

        return false
    }

    // MARK: - Response Parsing

    /// Parses the BLAST submission response to extract RID and RTOE.
    ///
    /// The NCBI submission response contains a QBlastInfo block:
    /// ```
    /// <!--QBlastInfoBegin
    ///     RID = XXXX
    ///     RTOE = 30
    /// QBlastInfoEnd-->
    /// ```
    ///
    /// - Parameter body: The response body text
    /// - Returns: The parsed submission response
    /// - Throws: ``BlastServiceError/ridParsingFailed`` if RID cannot be found
    func parseSubmissionResponse(_ body: String) throws -> BlastJobSubmission {
        // Look for RID in QBlastInfo block
        guard let rid = extractQBlastValue(from: body, key: "RID") else {
            throw BlastServiceError.ridParsingFailed(responseBody: String(body.prefix(500)))
        }

        let rtoe = extractQBlastValue(from: body, key: "RTOE").flatMap(Int.init) ?? 30

        return BlastJobSubmission(rid: rid, rtoe: rtoe)
    }

    /// Parses the BLAST status response.
    ///
    /// The status response contains a QBlastInfo block with a Status field:
    /// - `Status=WAITING` - job is still running
    /// - `Status=READY` - results are available
    /// - `Status=FAILED` - job encountered an error
    ///
    /// - Parameter body: The response body text
    /// - Returns: The parsed job status
    func parseStatusResponse(_ body: String) -> BlastJobStatus {
        guard let status = extractQBlastValue(from: body, key: "Status") else {
            return .unknown
        }

        switch status.uppercased() {
        case "READY":
            return .ready
        case "WAITING":
            return .waiting(queuePosition: extractQBlastValue(from: body, key: "ThereAre").flatMap(Int.init))
        default:
            return .error(message: "BLAST status: \(status)")
        }
    }

    // MARK: - ZIP Decompression

    /// Decompresses a ZIP archive response from NCBI BLAST.
    ///
    /// NCBI returns multi-query BLAST JSON2 results as a ZIP archive containing:
    /// - A manifest JSON with `{"BlastJSON": [{"File": "RID_1.json"}, ...]}` listing per-query files
    /// - Individual JSON files per query, each containing a `BlastOutput2` array with one entry
    ///
    /// This method extracts the ZIP to a temp directory, reads the manifest,
    /// parses each per-query JSON file, and reassembles them into a single
    /// `{"BlastOutput2": [...]}` JSON object matching the non-ZIP format.
    ///
    /// - Parameter zipData: Raw ZIP archive data
    /// - Returns: Combined JSON data with all query results
    /// - Throws: ``BlastServiceError/resultParsingFailed`` if extraction fails
    private func decompressZIPResponse(_ zipData: Data) throws -> Data {
        let tempBase = FileManager.default.temporaryDirectory
        let extractDir = tempBase.appendingPathComponent("blast-zip-\(UUID().uuidString)")
        let tempZIP = tempBase.appendingPathComponent("blast-\(UUID().uuidString).zip")

        defer {
            try? FileManager.default.removeItem(at: tempZIP)
            try? FileManager.default.removeItem(at: extractDir)
        }

        try zipData.write(to: tempZIP, options: .atomic)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        // Extract ZIP to a temp directory (not -p which concatenates)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", tempZIP.path, "-d", extractDir.path]
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw BlastServiceError.resultParsingFailed(
                message: "Failed to launch unzip: \(error.localizedDescription)"
            )
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw BlastServiceError.resultParsingFailed(
                message: "ZIP extraction failed (exit \(process.terminationStatus))"
            )
        }

        // List extracted files
        let extractedFiles = (try? FileManager.default.contentsOfDirectory(
            at: extractDir, includingPropertiesForKeys: nil
        )) ?? []
        logger.info("decompressZIPResponse: extracted \(extractedFiles.count, privacy: .public) files from ZIP")

        // Find per-query JSON files (named RID_N.json, contain BlastOutput2)
        // Skip the manifest file (which contains BlastJSON, not BlastOutput2)
        var combinedEntries: [[String: Any]] = []

        for file in extractedFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard file.pathExtension == "json" else { continue }
            guard let fileData = try? Data(contentsOf: file) else { continue }

            // Try to parse as JSON
            guard let json = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any] else {
                continue
            }

            // Skip the manifest (has "BlastJSON" key, not "BlastOutput2")
            if json["BlastJSON"] != nil {
                logger.debug("decompressZIPResponse: skipping manifest \(file.lastPathComponent, privacy: .public)")
                continue
            }

            // Per-query files have "BlastOutput2" — either as an array
            // (standard JSON2 format) or as a single object (split ZIP format).
            if let entries = json["BlastOutput2"] as? [[String: Any]] {
                combinedEntries.append(contentsOf: entries)
                logger.debug("decompressZIPResponse: parsed \(file.lastPathComponent, privacy: .public) with \(entries.count, privacy: .public) entries (array)")
            } else if let entry = json["BlastOutput2"] as? [String: Any] {
                combinedEntries.append(entry)
                logger.debug("decompressZIPResponse: parsed \(file.lastPathComponent, privacy: .public) with 1 entry (object)")
            }
        }

        guard !combinedEntries.isEmpty else {
            throw BlastServiceError.resultParsingFailed(
                message: "No BlastOutput2 entries found in \(extractedFiles.count) extracted files"
            )
        }

        // Reassemble into the standard format: {"BlastOutput2": [...all entries...]}
        let combined: [String: Any] = ["BlastOutput2": combinedEntries]
        let combinedData = try JSONSerialization.data(withJSONObject: combined)

        logger.info("decompressZIPResponse: combined \(combinedEntries.count, privacy: .public) query results from ZIP archive")
        return combinedData
    }

    // MARK: - Helpers

    /// HTTP error that should be retried with backoff.
    private struct RetryableHTTPError: Error {
        let statusCode: Int
        let body: String
    }

    /// HTTP status codes that are commonly transient and safe to retry.
    private nonisolated static let retryableHTTPStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]

    /// URL transport error codes that are commonly transient.
    private nonisolated static let retryableURLErrorCodes: Set<URLError.Code> = [
        .timedOut,
        .cannotFindHost,
        .cannotConnectToHost,
        .dnsLookupFailed,
        .networkConnectionLost,
        .notConnectedToInternet,
        .resourceUnavailable,
        .internationalRoamingOff,
        .callIsActive,
        .dataNotAllowed,
        .cannotLoadFromNetwork,
    ]

    /// Executes a network request with retry/backoff for transient transport failures.
    ///
    /// Non-transient errors are surfaced immediately. After retry exhaustion,
    /// transport failures are normalized to ``BlastServiceError/networkFailed(message:)``.
    private func requestWithTransportRetry<T>(
        operation: String,
        body: () async throws -> T
    ) async throws -> T {
        var attempt = 1
        var delay = initialRetryBackoff

        while true {
            do {
                return try await body()
            } catch {
                if error is CancellationError {
                    throw error
                }

                let shouldRetry = attempt < maxNetworkRetryAttempts && isRetryableTransportError(error)
                if shouldRetry {
                    let failureSummary = (error as NSError).localizedDescription
                    logger.warning(
                        "\(operation, privacy: .public) attempt \(attempt, privacy: .public) failed: \(failureSummary, privacy: .public). Retrying in \(delay, privacy: .public)s"
                    )
                    try await Task.sleep(for: .seconds(delay))
                    attempt += 1
                    delay = min(delay * 2, maxRetryBackoff)
                    continue
                }

                throw normalizeTransportError(error, operation: operation, attempts: attempt)
            }
        }
    }

    /// Validates an HTTP response from a BLAST network call.
    ///
    /// Casts the response to ``HTTPURLResponse`` and branches on the status
    /// code: 200 succeeds, retryable status codes surface a
    /// ``RetryableHTTPError``, and all other codes throw
    /// ``BlastServiceError/httpError(statusCode:body:)``.
    ///
    /// - Parameters:
    ///   - data: The response body used to build error messages.
    ///   - response: The raw ``URLResponse`` to validate.
    ///   - nonHTTPMessage: Message used when the response is not an HTTP response.
    ///   - failureBodyFallback: Fallback string used when the body is not valid UTF-8.
    /// - Returns: The validated ``HTTPURLResponse`` on a 200 status.
    private nonisolated static func validateHTTPResponse(
        _ data: Data,
        _ response: URLResponse,
        nonHTTPMessage: String,
        failureBodyFallback: String
    ) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BlastServiceError.submissionFailed(message: nonHTTPMessage)
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? failureBodyFallback
            if retryableHTTPStatusCodes.contains(httpResponse.statusCode) {
                throw RetryableHTTPError(statusCode: httpResponse.statusCode, body: body)
            }
            throw BlastServiceError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        return httpResponse
    }

    private nonisolated func isRetryableTransportError(_ error: Error) -> Bool {
        if error is RetryableHTTPError {
            return true
        }
        guard let code = extractURLErrorCode(from: error) else {
            return false
        }
        return Self.retryableURLErrorCodes.contains(code)
    }

    private nonisolated func normalizeTransportError(
        _ error: Error,
        operation: String,
        attempts: Int
    ) -> Error {
        if let blastError = error as? BlastServiceError {
            return blastError
        }

        if let retryableHTTP = error as? RetryableHTTPError {
            return BlastServiceError.httpError(statusCode: retryableHTTP.statusCode, body: retryableHTTP.body)
        }

        let nsError = error as NSError
        if let code = extractURLErrorCode(from: error) {
            return BlastServiceError.networkFailed(
                message: "\(operation) failed after \(attempts) attempt(s): \(nsError.localizedDescription) (NSURLError \(code.rawValue))"
            )
        }

        return BlastServiceError.networkFailed(
            message: "\(operation) failed after \(attempts) attempt(s): \(nsError.localizedDescription)"
        )
    }

    private nonisolated func extractURLErrorCode(from error: Error) -> URLError.Code? {
        if let urlError = error as? URLError {
            return urlError.code
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return URLError.Code(rawValue: nsError.code)
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSURLErrorDomain {
            return URLError.Code(rawValue: underlying.code)
        }

        return nil
    }

    /// Extracts a value from the QBlastInfo block in an NCBI HTML response.
    ///
    /// The QBlastInfo block has the format:
    /// ```
    /// <!--QBlastInfoBegin
    ///     KEY = VALUE
    /// QBlastInfoEnd-->
    /// ```
    ///
    /// - Parameters:
    ///   - body: The response body
    ///   - key: The key to extract (e.g., "RID", "RTOE", "Status")
    /// - Returns: The extracted value, or nil if not found
    private nonisolated func extractQBlastValue(from body: String, key: String) -> String? {
        // Look for the pattern: KEY = VALUE (with optional whitespace)
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: key))\\s*=\\s*(.+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(
                  in: body,
                  options: [],
                  range: NSRange(body.startIndex..., in: body)
              ),
              let valueRange = Range(match.range(at: 1), in: body) else {
            return nil
        }

        return body[valueRange].trimmingCharacters(in: .whitespaces)
    }

    private nonisolated static func gzipFailure(
        path: String,
        status: Int32,
        stderr: Pipe?
    ) -> BlastServiceError {
        let stderrText = stderr
            .flatMap { String(data: $0.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var message = "gzip decompression failed for \(path) with exit status \(status)"
        if let stderrText, !stderrText.isEmpty {
            message += ": \(stderrText)"
        }
        return .inputReadFailed(message: message)
    }

    /// Form-encodes a list of key-value pairs.
    ///
    /// - Parameter params: Key-value pairs to encode
    /// - Returns: A URL-encoded form string
    private nonisolated func formEncode(_ params: [(String, String)]) -> String {
        params.map { key, value in
            let escapedKey = Self.formEscape(key)
            let escapedValue = Self.formEscape(value)
            return "\(escapedKey)=\(escapedValue)"
        }.joined(separator: "&")
    }

    private nonisolated static func formEscape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: formAllowedCharacters) ?? value
    }

    private nonisolated static let formAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return allowed
    }()

    /// Enforces the minimum interval between BLAST submissions.
    ///
    /// If the last submission was too recent, this method sleeps until
    /// the minimum interval has elapsed.
    private func enforceSubmitRateLimit(sequenceCount: Int) async throws {
        try enforceHourlySequenceLimit(sequenceCount: sequenceCount, now: Date())

        if let lastTime = lastSubmitTime {
            let elapsed = Date().timeIntervalSince(lastTime)
            if elapsed < rateLimits.minSubmitInterval {
                let waitTime = rateLimits.minSubmitInterval - elapsed
                logger.debug("Rate limiting: waiting \(waitTime, privacy: .public)s before next submission")
                try await Task.sleep(for: .seconds(waitTime))
            }
        }
    }

    private func enforceHourlySequenceLimit(sequenceCount: Int, now: Date) throws {
        submittedSequenceEvents.removeAll { now.timeIntervalSince($0.date) >= 3600 }

        let used = submittedSequenceEvents.reduce(0) { $0 + $1.count }
        guard used + sequenceCount <= rateLimits.maxSequencesPerHour else {
            let retryAfter = submittedSequenceEvents.first
                .map { max(1, 3600 - now.timeIntervalSince($0.date)) }
                ?? 3600
            throw BlastServiceError.rateLimitExceeded(retryAfter: retryAfter)
        }
    }

    private func recordSubmission(sequenceCount: Int, at date: Date) {
        submittedSequenceEvents.append((date: date, count: max(0, sequenceCount)))
    }

    private func acquireSubmissionSlot(maxConcurrentSubmissions: Int) async throws {
        let limit = max(1, maxConcurrentSubmissions)
        while activeSubmissionCount >= limit {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(rateLimits.submissionSlotPollInterval))
        }
        activeSubmissionCount += 1
    }
}
