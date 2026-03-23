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

    /// Minimum interval between job submissions (NCBI guideline: 10 seconds).
    private let minSubmitInterval: TimeInterval = 10.0

    /// Interval between status polls (NCBI guideline: at least 15 seconds).
    private let pollInterval: TimeInterval = 15.0

    /// Default maximum time to wait for a BLAST job to complete.
    private let defaultTimeout: TimeInterval = 600.0 // 10 minutes

    /// Identity threshold for a "verified" verdict (percentage).
    nonisolated let verifiedIdentityThreshold: Double = 90.0

    /// Query coverage threshold for a "verified" verdict (percentage).
    nonisolated let verifiedCoverageThreshold: Double = 80.0

    // MARK: - State

    /// The HTTP client used for requests (injectable for testing).
    private let httpClient: HTTPClient

    /// Timestamp of the last BLAST submission (for rate limiting).
    private var lastSubmitTime: Date?

    // MARK: - Initialization

    /// Creates a new BLAST service.
    ///
    /// - Parameter httpClient: HTTP client for making requests (defaults to URLSession).
    public init(httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    // MARK: - Request Building

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
        // Scan Kraken2 output for matching read IDs
        var matchingReadIds = Set<String>()
        if let data = try? Data(contentsOf: classificationOutputURL),
           let text = String(data: data, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let cols = line.split(separator: "\t", maxSplits: 3)
                guard cols.count >= 3, cols[0] == "C" else { continue }
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

        guard !matchingReadIds.isEmpty else {
            throw BlastServiceError.noSequences
        }

        // Extract sequences from FASTQ
        var allSequences: [(id: String, sequence: String)] = []
        if let handle = FileHandle(forReadingAtPath: sourceURL.path) {
            defer { handle.closeFile() }
            var lineBuffer: [String] = []
            var residual = ""
            let bufferSize = 4_194_304

            while true {
                let chunk = handle.readData(ofLength: bufferSize)
                if chunk.isEmpty { break }
                guard let text = String(data: chunk, encoding: .utf8) else { continue }
                let combined = residual + text
                residual = ""
                var lines = combined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                if !combined.hasSuffix("\n") && !lines.isEmpty {
                    residual = lines.removeLast()
                }
                for line in lines {
                    lineBuffer.append(line)
                    if lineBuffer.count == 4 {
                        if lineBuffer[0].hasPrefix("@") {
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
        }

        // Subsample
        let strategy = SubsampleStrategy.mixed(longest: min(5, readCount / 4), random: readCount - min(5, readCount / 4))
        let subsampled = subsampleReads(from: allSequences, strategy: strategy)

        return BlastVerificationRequest(
            taxonName: taxonName,
            taxId: taxId,
            sequences: subsampled,
            entrezQuery: "txid\(taxId)[Organism:exp]"
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
            megablast: request.program == "blastn"
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

        let readResults = assignVerdicts(
            searchResults: searchResults,
            eValueThreshold: request.eValueThreshold
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
    /// - Returns: The job submission response with RID and RTOE
    /// - Throws: ``BlastServiceError`` on submission failure
    public func submit(
        query: String,
        program: String,
        database: String,
        entrezQuery: String?,
        evalue: Double,
        maxTargetSeqs: Int,
        megablast: Bool
    ) async throws -> BlastJobSubmission {
        // Enforce rate limit
        try await enforceSubmitRateLimit()

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

        let body = formEncode(params)

        var request = URLRequest(url: blastBaseURL)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await httpClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BlastServiceError.submissionFailed(message: "Non-HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "(non-UTF8)"
            throw BlastServiceError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        lastSubmitTime = Date()

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

        let (data, response) = try await httpClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw BlastServiceError.httpError(statusCode: statusCode, body: "Status check failed")
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

        let (data, response) = try await httpClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BlastServiceError.httpError(statusCode: statusCode, body: body)
        }

        return try parseJSON2Results(data)
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
    private func pollForResults(
        rid: String,
        initialWait: Int,
        timeout: TimeInterval,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> [BlastSearchResult] {
        let startTime = Date()

        // Wait the initial RTOE before first poll
        let initialDelay = max(Double(initialWait), pollInterval)
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

            case .waiting:
                try await Task.sleep(for: .seconds(pollInterval))

            case .error(let message):
                throw BlastServiceError.jobFailed(rid: rid, message: message)

            case .unknown:
                // RID may not be recognized yet; retry
                logger.warning("BLAST status unknown for RID=\(rid, privacy: .public), retrying...")
                try await Task.sleep(for: .seconds(pollInterval))
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
    /// - Parameters:
    ///   - searchResults: Parsed BLAST search results
    ///   - eValueThreshold: E-value threshold for significance
    /// - Returns: Array of per-read verification results
    nonisolated func assignVerdicts(
        searchResults: [BlastSearchResult],
        eValueThreshold: Double
    ) -> [BlastReadResult] {
        searchResults.map { result in
            assignVerdict(for: result, eValueThreshold: eValueThreshold)
        }
    }

    /// Assigns a verdict for a single query result.
    private nonisolated func assignVerdict(
        for result: BlastSearchResult,
        eValueThreshold: Double
    ) -> BlastReadResult {
        // Find the best HSP across all hits
        guard let topHit = result.hits.first,
              let bestHSP = topHit.hsps.first else {
            // No hits at all
            return BlastReadResult(id: result.queryId, verdict: .unverified)
        }

        let pctIdentity = bestHSP.percentIdentity
        let coverage = bestHSP.queryCoverage(queryLength: result.queryLength)
        let eValue = bestHSP.evalue

        // Determine verdict
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

        return BlastReadResult(
            id: result.queryId,
            verdict: verdict,
            topHitOrganism: topHit.organism ?? topHit.title,
            topHitAccession: topHit.accession,
            percentIdentity: pctIdentity,
            queryCoverage: coverage,
            eValue: eValue,
            alignmentLength: bestHSP.alignLength,
            bitScore: bestHSP.bitScore
        )
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
            return .waiting
        default:
            return .error(message: "BLAST status: \(status)")
        }
    }

    /// Parses BLAST JSON2 results into search result models.
    ///
    /// The JSON2 format has this structure:
    /// ```json
    /// {
    ///   "BlastOutput2": [
    ///     {
    ///       "report": {
    ///         "results": {
    ///           "search": {
    ///             "query_title": "read1",
    ///             "query_len": 150,
    ///             "hits": [...]
    ///           }
    ///         }
    ///       }
    ///     }
    ///   ]
    /// }
    /// ```
    ///
    /// - Parameter data: Raw JSON data
    /// - Returns: Array of parsed search results
    /// - Throws: ``BlastServiceError/resultParsingFailed`` on parse failure
    nonisolated func parseJSON2Results(_ data: Data) throws -> [BlastSearchResult] {
        // The BLAST API sometimes wraps JSON inside HTML. Try to extract
        // the JSON portion if the data starts with HTML.
        let jsonData = try extractJSONFromResponse(data)

        guard let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw BlastServiceError.resultParsingFailed(message: "Response is not a JSON object")
        }

        guard let blastOutput2 = json["BlastOutput2"] as? [[String: Any]] else {
            throw BlastServiceError.resultParsingFailed(message: "Missing BlastOutput2 array")
        }

        return try blastOutput2.compactMap { entry in
            try parseBlastOutput2Entry(entry)
        }
    }

    /// Parses a single BlastOutput2 entry.
    private nonisolated func parseBlastOutput2Entry(_ entry: [String: Any]) throws -> BlastSearchResult? {
        guard let report = entry["report"] as? [String: Any],
              let results = report["results"] as? [String: Any],
              let search = results["search"] as? [String: Any] else {
            return nil
        }

        let queryTitle = search["query_title"] as? String ?? "unknown"
        let queryLen = search["query_len"] as? Int ?? 0
        let hitsArray = search["hits"] as? [[String: Any]] ?? []

        let hits: [BlastHit] = hitsArray.compactMap { hitDict in
            parseHit(hitDict)
        }

        return BlastSearchResult(queryId: queryTitle, queryLength: queryLen, hits: hits)
    }

    /// Parses a single hit from the JSON2 hits array.
    private nonisolated func parseHit(_ hitDict: [String: Any]) -> BlastHit? {
        let descriptions = hitDict["description"] as? [[String: Any]] ?? []
        guard let firstDesc = descriptions.first else { return nil }

        let accession = firstDesc["accession"] as? String ?? ""
        let title = firstDesc["title"] as? String ?? ""
        let organism = firstDesc["sciname"] as? String

        let hspsArray = hitDict["hsps"] as? [[String: Any]] ?? []
        let hsps: [BlastHSP] = hspsArray.compactMap { hspDict in
            parseHSP(hspDict)
        }

        guard !hsps.isEmpty else { return nil }

        return BlastHit(accession: accession, title: title, organism: organism, hsps: hsps)
    }

    /// Parses a single HSP from the JSON2 hsps array.
    private nonisolated func parseHSP(_ hspDict: [String: Any]) -> BlastHSP? {
        guard let bitScore = hspDict["bit_score"] as? Double,
              let evalue = hspDict["evalue"] as? Double,
              let identity = hspDict["identity"] as? Int,
              let alignLen = hspDict["align_len"] as? Int,
              let queryFrom = hspDict["query_from"] as? Int,
              let queryTo = hspDict["query_to"] as? Int else {
            return nil
        }

        return BlastHSP(
            bitScore: bitScore,
            evalue: evalue,
            identity: identity,
            alignLength: alignLen,
            queryFrom: queryFrom,
            queryTo: queryTo
        )
    }

    // MARK: - Helpers

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

    /// Extracts JSON from a response that may be wrapped in HTML.
    ///
    /// The BLAST API sometimes returns JSON inside an HTML wrapper.
    /// This method tries direct JSON parsing first, then falls back to
    /// extracting JSON content from HTML.
    ///
    /// - Parameter data: Raw response data
    /// - Returns: JSON data suitable for parsing
    private nonisolated func extractJSONFromResponse(_ data: Data) throws -> Data {
        // Try trimming whitespace first -- the data may just have leading spaces/newlines
        guard let body = String(data: data, encoding: .utf8) else {
            throw BlastServiceError.resultParsingFailed(message: "Non-UTF8 response")
        }

        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)

        // If it starts with '{' or '[', it's already JSON (possibly with whitespace removed)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if let result = trimmed.data(using: .utf8) {
                return result
            }
        }

        // Look for "BlastOutput2" and walk backwards to find the opening brace.
        // This handles both compact ({"BlastOutput2") and pretty-printed
        // ({\n  "BlastOutput2") JSON embedded in HTML.
        if let markerRange = body.range(of: "\"BlastOutput2\"") {
            // Walk backwards from the marker to find the opening '{'
            var openBraceIndex = markerRange.lowerBound
            var found = false
            while openBraceIndex > body.startIndex {
                openBraceIndex = body.index(before: openBraceIndex)
                if body[openBraceIndex] == "{" {
                    found = true
                    break
                }
            }

            if found {
                // Walk forward from the opening brace to find the balanced closing brace
                let substring = body[openBraceIndex...]
                var depth = 0
                var endIndex = substring.startIndex
                for idx in substring.indices {
                    let ch = substring[idx]
                    if ch == "{" { depth += 1 }
                    else if ch == "}" {
                        depth -= 1
                        if depth == 0 {
                            endIndex = substring.index(after: idx)
                            break
                        }
                    }
                }
                let jsonString = String(substring[substring.startIndex..<endIndex])
                if let result = jsonString.data(using: .utf8) {
                    return result
                }
            }
        }

        throw BlastServiceError.resultParsingFailed(
            message: "Could not find JSON in response (\(data.count) bytes)"
        )
    }

    /// Form-encodes a list of key-value pairs.
    ///
    /// - Parameter params: Key-value pairs to encode
    /// - Returns: A URL-encoded form string
    private nonisolated func formEncode(_ params: [(String, String)]) -> String {
        params.map { key, value in
            let escapedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let escapedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(escapedKey)=\(escapedValue)"
        }.joined(separator: "&")
    }

    /// Enforces the minimum interval between BLAST submissions.
    ///
    /// If the last submission was too recent, this method sleeps until
    /// the minimum interval has elapsed.
    private func enforceSubmitRateLimit() async throws {
        if let lastTime = lastSubmitTime {
            let elapsed = Date().timeIntervalSince(lastTime)
            if elapsed < minSubmitInterval {
                let waitTime = minSubmitInterval - elapsed
                logger.debug("Rate limiting: waiting \(waitTime, privacy: .public)s before next submission")
                try await Task.sleep(for: .seconds(waitTime))
            }
        }
    }
}

// MARK: - Subsampling

extension BlastService {

    /// Subsamples reads for BLAST verification.
    ///
    /// Given a set of read IDs and their sequences, selects a representative
    /// subset according to the specified strategy:
    ///
    /// - `.longestFirst(count:)`: Selects the N longest reads
    /// - `.random(count:)`: Selects N reads at random
    /// - `.mixed(longest:random:)`: Selects the top N longest, then fills
    ///   remaining slots with random reads from the rest
    ///
    /// When fewer reads are available than requested, all reads are returned.
    ///
    /// - Parameters:
    ///   - reads: All available reads as (id, sequence) pairs
    ///   - strategy: The subsampling strategy to use
    ///   - seed: Random seed for reproducibility (defaults to 0)
    /// - Returns: The subsampled reads as (id, sequence) pairs
    public nonisolated func subsampleReads(
        from reads: [(id: String, sequence: String)],
        strategy: SubsampleStrategy,
        seed: UInt64 = 0
    ) -> [(id: String, sequence: String)] {
        guard !reads.isEmpty else { return [] }

        let totalRequested = strategy.totalCount
        guard reads.count > totalRequested else {
            // Fewer reads than requested -- return all
            return reads
        }

        switch strategy {
        case .longestFirst(let count):
            return selectLongest(from: reads, count: count)

        case .random(let count):
            return selectRandom(from: reads, count: count, seed: seed)

        case .mixed(let longest, let random):
            return selectMixed(from: reads, longest: longest, random: random, seed: seed)
        }
    }

    /// Selects the N longest reads.
    private nonisolated func selectLongest(
        from reads: [(id: String, sequence: String)],
        count: Int
    ) -> [(id: String, sequence: String)] {
        let sorted = reads.sorted { $0.sequence.count > $1.sequence.count }
        return Array(sorted.prefix(count))
    }

    /// Selects N reads at random using a seeded generator.
    private nonisolated func selectRandom(
        from reads: [(id: String, sequence: String)],
        count: Int,
        seed: UInt64
    ) -> [(id: String, sequence: String)] {
        var rng = SeededRandomNumberGenerator(seed: seed)
        let shuffled = reads.shuffled(using: &rng)
        return Array(shuffled.prefix(count))
    }

    /// Selects top-N longest + random from the rest.
    private nonisolated func selectMixed(
        from reads: [(id: String, sequence: String)],
        longest: Int,
        random: Int,
        seed: UInt64
    ) -> [(id: String, sequence: String)] {
        let sorted = reads.sorted { $0.sequence.count > $1.sequence.count }
        let longestReads = Array(sorted.prefix(longest))
        let longestIds = Set(longestReads.map(\.id))

        // Remaining reads (excluding the longest-selected ones)
        let remaining = reads.filter { !longestIds.contains($0.id) }

        let randomReads: [(id: String, sequence: String)]
        if remaining.count <= random {
            randomReads = remaining
        } else {
            var rng = SeededRandomNumberGenerator(seed: seed)
            let shuffled = remaining.shuffled(using: &rng)
            randomReads = Array(shuffled.prefix(random))
        }

        return longestReads + randomReads
    }
}

// MARK: - Seeded Random Number Generator

/// A deterministic random number generator for reproducible subsampling.
///
/// Uses a simple xorshift64 algorithm seeded with a fixed value.
/// This ensures that the same reads are selected for the same taxon
/// across repeated runs.
struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    /// Creates a seeded RNG.
    ///
    /// - Parameter seed: The seed value. A seed of 0 is remapped to 1
    ///   to avoid the degenerate xorshift state.
    init(seed: UInt64) {
        // xorshift64 requires non-zero state
        self.state = seed == 0 ? 1 : seed
    }

    mutating func next() -> UInt64 {
        // xorshift64 algorithm
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
