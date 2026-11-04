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
/// ## Limits
///
/// LGE keeps to limits of its own:
/// - ``BlastContactGate`` spaces every contact from this Mac, across processes
/// - The ledger counts each POST against an hourly limit, and ``BlastSearchPolicy`` sets how often a search is checked
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
    ///
    /// Its hourly submission ledger lives under the managed storage root
    /// (`<root>/blast/submission-ledger.json`), so quitting the app or
    /// running the CLI does not reset LGE's own limit of 50 reads an hour. A
    /// debug build pointed at a stand-in keeps it in the run's stand-in state
    /// folder (``BlastStandInState``), and never under the root.
    public static let shared: BlastService = {
        let environment = ProcessInfo.processInfo.environment
        return BlastService(
            submissionLedger: FileBlastSubmissionLedger.managedStorageDefault(environment: environment),
            searchShared: BlastSearchShared.managedStorageDefault(environment: environment),
            environment: environment
        )
    }()

    // MARK: - Constants

    /// The BLAST CGI endpoint, NCBI's unless a debug build's environment names a stand-in.
    nonisolated let blastBaseURL: URL

    /// Tool identifier sent with all BLAST requests (NCBI policy).
    let toolName = "lungfish"

    /// Email placeholder sent with BLAST requests (NCBI policy).
    let toolEmail = "lungfish-app@users.noreply.github.com"

    /// Identity threshold for a "verified" verdict (percentage).
    nonisolated let verifiedIdentityThreshold: Double = 90.0

    /// Query coverage threshold for a "verified" verdict (percentage).
    nonisolated let verifiedCoverageThreshold: Double = 80.0

    // MARK: - State

    /// The HTTP client used for requests (injectable for testing).
    let httpClient: HTTPClient

    /// Local NCBI BLAST etiquette limits.
    private let rateLimits: BlastRateLimitConfiguration

    /// What a search shares across processes. A test's service keeps no spacing and writes no file.
    package let searchShared: BlastSearchShared

    /// Number of currently active NCBI BLAST submission requests.
    var activeSubmissionCount = 0

    /// Rolling one-hour record of reads sent to NCBI.
    let submissionLedger: any BlastSubmissionLedger

    /// The clock used for rate limiting and result timestamps.
    private let now: @Sendable () -> Date

    // MARK: - Initialization

    /// Creates a new BLAST service.
    ///
    /// - Parameters:
    ///   - httpClient: HTTP client for making requests (defaults to URLSession).
    ///   - rateLimits: Local submission limits for NCBI BLAST etiquette.
    ///   - submissionLedger: Where the rolling-hour submission count is kept.
    ///     Defaults to an in-memory ledger; ``shared`` uses a file ledger.
    ///   - now: The clock, injectable for tests.
    ///   - environment: Read only by a debug build, for a stand-in origin (``BlastServiceEndpoints``).
    public init(
        httpClient: HTTPClient = URLSessionHTTPClient(),
        rateLimits: BlastRateLimitConfiguration = .ncbiDefault,
        submissionLedger: any BlastSubmissionLedger = InMemoryBlastSubmissionLedger(),
        now: @escaping @Sendable () -> Date = { Date() },
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.init(
            httpClient: httpClient, rateLimits: rateLimits, submissionLedger: submissionLedger, searchShared: BlastSearchShared(),
            now: now, environment: environment
        )
    }

    /// A service that shares `searchShared` with the other processes on this Mac.
    package init(
        httpClient: HTTPClient = URLSessionHTTPClient(),
        rateLimits: BlastRateLimitConfiguration = .ncbiDefault,
        submissionLedger: any BlastSubmissionLedger = InMemoryBlastSubmissionLedger(),
        searchShared: BlastSearchShared,
        now: @escaping @Sendable () -> Date = { Date() },
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.blastBaseURL = BlastServiceEndpoints(environment: environment).blastURL
        self.httpClient = httpClient
        self.rateLimits = rateLimits
        self.submissionLedger = submissionLedger
        self.searchShared = searchShared
        self.now = now
    }

    // MARK: - Request Building

    /// Builds a BLAST verification request using pre-fetched read IDs.
    ///
    /// Reads one source file. The `sources:` form reads every source file of
    /// a result, R1, R2, then single reads.
    ///
    /// Use this overload when read IDs have already been looked up via
    /// ``KrakenIndexDatabase`` for O(k) indexed access instead of O(n)
    /// linear scanning.
    ///
    /// Fragments are sampled uniformly at random (seeded, so repeatable).
    /// When `classificationOutputURL` is given, the Kraken 2 hit string of
    /// each sampled paired fragment decides which mate is submitted: the
    /// mate with the most k-mers assigned to `targetTaxIds`.
    ///
    /// - Parameters:
    ///   - taxonName: Display name of the taxon
    ///   - taxId: NCBI taxonomy ID
    ///   - matchingReadIds: Pre-fetched read IDs for the target taxon(s)
    ///   - sourceURL: Path to source FASTQ file
    ///   - readCount: Number of reads to subsample (default 20)
    ///   - targetTaxIds: The taxon (and descendants when requested) whose
    ///     k-mer hits count as evidence for mate selection and verdicts.
    ///     Defaults to `[taxId]` when empty.
    ///   - classificationOutputURL: Kraken 2 per-read output, used to read
    ///     hit strings for the sampled fragments.
    ///   - acceptedTaxonNames: Names of the taxa in `targetTaxIds`, used to
    ///     match BLAST hit organisms that name the taxon differently.
    ///   - taxonomyContext: The clade and genus relatives BLAST hits are
    ///     judged against. When `nil`, the clade is `targetTaxIds` with
    ///     `acceptedTaxonNames` and there are no known relatives.
    ///   - seed: Sampling seed.
    /// - Returns: A ready-to-submit BlastVerificationRequest
    public func buildVerificationRequestFromReadIds(
        taxonName: String,
        taxId: Int,
        matchingReadIds: Set<String>,
        sourceURL: URL,
        readCount: Int = 20,
        targetTaxIds: Set<Int> = [],
        classificationOutputURL: URL? = nil,
        acceptedTaxonNames: [String] = [],
        taxonomyContext: BlastTaxonomyContext? = nil,
        seed: UInt64 = 0
    ) async throws -> BlastVerificationRequest {
        try await buildVerificationRequestFromReadIds(
            taxonName: taxonName,
            taxId: taxId,
            matchingReadIds: matchingReadIds,
            sources: [BlastReadSource(url: sourceURL)],
            readCount: readCount,
            targetTaxIds: targetTaxIds,
            classificationOutputURL: classificationOutputURL,
            acceptedTaxonNames: acceptedTaxonNames,
            taxonomyContext: taxonomyContext,
            seed: seed
        )
    }

    /// Builds a BLAST verification request by subsampling reads from classification output.
    ///
    /// Reads one source file. The `sources:` form reads every source file of
    /// a result, R1, R2, then single reads.
    ///
    /// This is a convenience method that handles:
    /// 1. Scanning the Kraken2 per-read output for matching fragment IDs
    /// 2. Drawing an unbiased, seeded random sample of those fragments
    /// 3. Choosing, for each paired fragment, the mate that carries the
    ///    taxon's k-mer evidence according to the Kraken 2 hit string
    /// 4. Extracting those sequences from the source FASTQ
    /// 5. Building the BlastVerificationRequest
    ///
    /// - Parameters:
    ///   - taxonName: Display name of the taxon
    ///   - taxId: NCBI taxonomy ID
    ///   - targetTaxIds: All tax IDs to match (including descendants)
    ///   - classificationOutputURL: Path to Kraken2 per-read output
    ///   - sourceURL: Path to source FASTQ file
    ///   - readCount: Number of reads to subsample (default 20)
    ///   - acceptedTaxonNames: Names of the taxa in `targetTaxIds`.
    ///   - taxonomyContext: The clade and genus relatives BLAST hits are
    ///     judged against. When `nil`, the clade is `targetTaxIds`.
    ///   - seed: Sampling seed.
    /// - Returns: A ready-to-submit BlastVerificationRequest
    public func buildVerificationRequest(
        taxonName: String,
        taxId: Int,
        targetTaxIds: Set<Int>,
        classificationOutputURL: URL,
        sourceURL: URL,
        readCount: Int = 20,
        acceptedTaxonNames: [String] = [],
        taxonomyContext: BlastTaxonomyContext? = nil,
        seed: UInt64 = 0
    ) async throws -> BlastVerificationRequest {
        try await buildVerificationRequest(
            taxonName: taxonName,
            taxId: taxId,
            targetTaxIds: targetTaxIds,
            classificationOutputURL: classificationOutputURL,
            sources: [BlastReadSource(url: sourceURL)],
            readCount: readCount,
            acceptedTaxonNames: acceptedTaxonNames,
            taxonomyContext: taxonomyContext,
            seed: seed
        )
    }

    /// Starts `gzip -dc` on `url` through ``ToolProcess`` with its stdout streamed. A reader that stops
    /// early stops the gzip tree in its `defer`, and one that reaches the end waits in `waitBlocking()`.
    private func launchGzipDecompression(for url: URL) throws -> ToolProcessRun {
        try ToolProcess.start(ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/gzip"),
            arguments: ["-dc", url.path],
            environment: ["PATH": "/usr/bin:/bin"],
            stdout: .stream,
            label: "gzip -dc"
        ))
    }

    /// The next `count` bytes of a plain file or of `gzip -dc`, fewer at the end. A cancelled task ends a
    /// plain read before its next chunk (S38, 2.12 lane 12.10) and a gzip read before its next piece, so a
    /// gzip that writes nothing sees the cancel late.
    private nonisolated static func nextChunk(_ file: FileHandle?, _ gzip: ToolProcessRun?, count: Int) throws -> Data {
        guard let gzip else {
            try Task.checkCancellation()
            return file?.readData(ofLength: count) ?? Data()
        }
        var data = Data()
        while data.count < count {
            if Task.isCancelled { throw CancellationError() }
            let piece = gzip.stdout.read(upTo: count - data.count)
            if piece.isEmpty { break }
            data.append(piece)
        }
        return data
    }

    /// Waits for `gzip -dc` once its stream has ended. A cancelled run is a `CancellationError`.
    private nonisolated static func waitForGzip(_ run: ToolProcessRun, path: String) throws -> ToolProcessResult {
        do {
            return try run.waitBlocking()
        } catch let error as ToolProcessError {
            if case .cancelled = error { throw CancellationError() }
            throw BlastServiceError.inputReadFailed(message: "gzip decompression failed for \(path): \(error.localizedDescription)")
        }
    }

    /// Streams the lines of a plain or gzip-compressed Kraken 2 output file.
    func forEachKrakenOutputLine(
        _ url: URL,
        _ body: (Substring) -> Void
    ) throws {
        let isGzip = url.pathExtension.lowercased() == "gz"
        let gzipRun = try isGzip ? launchGzipDecompression(for: url) : nil
        defer { gzipRun?.cancel() }
        let fileHandle = isGzip ? nil : FileHandle(forReadingAtPath: url.path)
        defer { fileHandle?.closeFile() }
        if !isGzip && fileHandle == nil {
            throw BlastServiceError.noSequences
        }

        var residual = Data()
        let bufferSize = 1_048_576

        func emit(_ data: Data) {
            guard let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") {
                body(line)
            }
        }

        while true {
            let chunk = try Self.nextChunk(fileHandle, gzipRun, count: bufferSize)
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
            emit(data)
        }

        if !residual.isEmpty {
            emit(residual)
        }

        if let gzipRun {
            let result = try Self.waitForGzip(gzipRun, path: url.path)
            guard result.isSuccess else { throw Self.gzipFailure(path: url.path, result: result) }
        }
    }

    func scanKrakenClassificationOutput(
        _ classificationOutputURL: URL,
        targetTaxIds: Set<Int>
    ) throws -> (matchingReadIds: Set<String>, totalClassified: Int) {
        var matchingReadIds = Set<String>()
        var totalClassified = 0
        try forEachKrakenOutputLine(classificationOutputURL) { line in
            let cols = line.split(separator: "\t", maxSplits: 3)
            guard cols.count >= 3, cols[0] == "C" else { return }
            totalClassified += 1
            if let tid = Int(cols[2].trimmingCharacters(in: .whitespaces)),
               targetTaxIds.contains(tid) {
                let readId = cols[1].trimmingCharacters(in: .whitespaces)
                matchingReadIds.insert(Self.normalizeFragmentId(readId).id)
            }
        }
        return (matchingReadIds, totalClassified)
    }

    /// Reads the Kraken 2 hit strings (column 5) for the given fragment IDs.
    func lookupKrakenHitStrings(
        _ classificationOutputURL: URL,
        fragmentIds: Set<String>
    ) throws -> [String: String] {
        var hitStrings: [String: String] = [:]
        try forEachKrakenOutputLine(classificationOutputURL) { line in
            guard hitStrings.count < fragmentIds.count else { return }
            let cols = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard cols.count >= 5 else { return }
            let id = Self.normalizeFragmentId(cols[1].trimmingCharacters(in: .whitespaces)).id
            guard fragmentIds.contains(id) else { return }
            hitStrings[id] = String(cols[4])
        }
        return hitStrings
    }

    // MARK: - High-Level API

    /// Turns parsed NCBI results into a verification result for `request`.
    ///
    /// Every submitted sequence is judged, in submission order. A sequence NCBI
    /// returned no entry for, or whose entry could not be parsed, gets an
    /// `.error` verdict and the rest of the batch is still judged. A request
    /// that judges a claim holds one row per fragment (``fragmentRows(_:)``),
    /// and a request with no claim holds one row per sequence. Only when no
    /// row has a usable result does this throw, because then the job as a
    /// whole produced nothing to review.
    nonisolated func buildVerificationResult(
        request: BlastVerificationRequest,
        searchResults: [BlastSearchResult],
        rid: String,
        submittedAt: Date,
        completedAt: Date
    ) throws -> BlastVerificationResult {
        let reconciled = Self.reconcile(searchResults: searchResults, submittedIds: request.sequences.map(\.id))
        let judged = reconciled.enumerated().flatMap { index, entry in
            assignVerdicts(
                searchResults: [entry], eValueThreshold: request.eValueThreshold,
                sequenceMap: index < request.sequences.count ? [entry.queryId: request.sequences[index].sequence] : [:],
                queriedTaxonName: request.taxonName, sequenceMates: request.sequenceMates,
                acceptedTaxIds: request.acceptedTaxIds, acceptedTaxonNames: request.acceptedTaxonNames,
                relatedTaxIds: request.relatedTaxIds, relatedTaxonNames: request.relatedTaxonNames
            )
        }
        let judgesAClaim = !request.acceptedTaxIds.isEmpty || !request.acceptedTaxonNames.isEmpty
        let readResults = judgesAClaim ? Self.fragmentRows(judged) : judged
        if !readResults.isEmpty, readResults.allSatisfy({ $0.verdict == .error }) {
            let reason = readResults.first?.errorMessage ?? "no usable result"
            throw BlastServiceError.resultParsingFailed(
                message: "NCBI returned no usable result for any of the \(readResults.count) reads (RID \(rid)): \(reason)"
            )
        }
        return BlastVerificationResult(
            taxonName: request.taxonName,
            taxId: request.taxId,
            readResults: readResults,
            submittedAt: submittedAt,
            completedAt: completedAt,
            rid: rid,
            blastProgram: request.program,
            database: request.database
        )
    }

    /// Message on the `.error` row of a read NCBI returned no entry for.
    public nonisolated static let missingReadResultMessage = "NCBI returned no result for this read"

    /// Lines parsed results up with the submitted sequences, one answer each.
    ///
    /// Results are matched by query title, and the answers to a shared title
    /// go to its sequences in submission order, the order NCBI reports a batch
    /// in. When no title matches but NCBI returned exactly one entry per
    /// sequence, entries are matched by position. A sequence with no entry
    /// gets a failure placeholder, and entries that match no sequence are
    /// kept after the submitted ones unless they are unparsed placeholders.
    nonisolated static func reconcile(
        searchResults: [BlastSearchResult],
        submittedIds: [String]
    ) -> [BlastSearchResult] {
        guard !submittedIds.isEmpty else { return searchResults }
        var slots: [String: Int] = [:]
        for id in submittedIds { slots[id, default: 0] += 1 }
        let positional = searchResults.count == submittedIds.count

        var answers: [String: [BlastSearchResult]] = [:]
        var orphans: [BlastSearchResult] = []
        for (index, result) in searchResults.enumerated() {
            var id = result.queryId
            if slots[id] == nil, positional, answers[submittedIds[index], default: []].count < slots[submittedIds[index], default: 0] {
                id = submittedIds[index]
            }
            guard let slotCount = slots[id] else {
                if result.failureMessage == nil { orphans.append(result) }
                continue
            }
            if answers[id, default: []].count < slotCount {
                answers[id, default: []].append(BlastSearchResult(
                    queryId: id,
                    queryLength: result.queryLength,
                    hits: result.hits,
                    failureMessage: result.failureMessage
                ))
            }
        }

        var answered: [String: Int] = [:]
        var ordered: [BlastSearchResult] = []
        for id in submittedIds {
            let position = answered[id, default: 0]
            answered[id] = position + 1
            let queue = answers[id, default: []]
            ordered.append(position < queue.count ? queue[position] : BlastSearchResult(
                queryId: id,
                queryLength: 0,
                hits: [],
                failureMessage: missingReadResultMessage
            ))
        }
        return ordered + orphans
    }

    // MARK: - FASTQ Sequence Extraction

    /// Extracts matching sequences from a FASTQ file (raw or gzip-compressed).
    ///
    /// For gzip files, pipes through `/usr/bin/gzip -dc`. If the subprocess
    /// fails (e.g., killed by macOS XPC interruptions), retries once with a
    /// brief delay. A gzip that ends well with no matching record is read
    /// once, since `waitForGzip` reports a killed one (S38, 2.12 lane 12.10).
    ///
    /// - Parameters:
    ///   - sourceURL: Path to the FASTQ file (raw or .gz)
    ///   - matchingReadIds: Set of read IDs to extract
    ///   - isGzip: Whether the file is gzip-compressed
    /// - Returns: Every matching FASTQ record as (fragment id, declared mate
    ///   number if the header carries one, sequence), in file order.
    func extractMatchingSequences(
        from sourceURL: URL,
        matchingReadIds: Set<String>,
        isGzip: Bool
    ) async throws -> [(id: String, mate: Int?, sequence: String)] {
        let maxAttempts = isGzip ? 2 : 1  // Retry only for gzip (subprocess can fail)

        for attempt in 1...maxAttempts {
            do {
                return try extractMatchingSequencesOnce(
                    from: sourceURL,
                    matchingReadIds: matchingReadIds,
                    isGzip: isGzip
                )
            } catch {
                if error is CancellationError { throw error }
                if isGzip, attempt < maxAttempts {
                    logger.warning("extractMatchingSequences: gzip attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public); retrying...")
                    try await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                throw error
            }
        }

        return []
    }

    /// Single-attempt sequence extraction from a FASTQ file.
    private func extractMatchingSequencesOnce(
        from sourceURL: URL,
        matchingReadIds: Set<String>,
        isGzip: Bool
    ) throws -> [(id: String, mate: Int?, sequence: String)] {
        var allSequences: [(id: String, mate: Int?, sequence: String)] = []
        let gzipRun: ToolProcessRun?
        do {
            gzipRun = try isGzip ? launchGzipDecompression(for: sourceURL) : nil
        } catch {
            logger.error("extractMatchingSequences: failed to launch gzip: \(error.localizedDescription, privacy: .public)")
            throw BlastServiceError.noSequences
        }
        defer { gzipRun?.cancel() }
        let handle = isGzip ? nil : FileHandle(forReadingAtPath: sourceURL.path)

        if gzipRun != nil || handle != nil {
            defer {
                handle?.closeFile()
            }
            var lineBuffer: [String] = []
            var residual = ""
            let bufferSize = 4_194_304
            var totalBytesRead = 0
            var totalRecords = 0
            var chunksRead = 0
            var utf8Failures = 0

            while true {
                let chunk = try Self.nextChunk(handle, gzipRun, count: bufferSize)
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
                            let headerFields = lineBuffer[0].dropFirst()
                                .split(separator: " ", maxSplits: 1)
                            let (readId, idMate) = Self.normalizeFragmentId(headerFields.first ?? "")
                            if matchingReadIds.contains(readId) {
                                let mate = idMate ?? (headerFields.count > 1
                                    ? Self.mateFromDescription(headerFields[1])
                                    : nil)
                                allSequences.append((id: readId, mate: mate, sequence: lineBuffer[1]))
                            }
                        }
                        lineBuffer.removeAll(keepingCapacity: true)
                    }
                }
            }

            // Check gzip exit status
            if let gzipRun {
                let result = try Self.waitForGzip(gzipRun, path: sourceURL.path)
                logger.info("extractMatchingSequences: gzip exited with status \(result.status, privacy: .public), read \(chunksRead, privacy: .public) chunks (\(totalBytesRead, privacy: .public) bytes), \(totalRecords, privacy: .public) FASTQ records, \(utf8Failures, privacy: .public) UTF8 failures, \(allSequences.count, privacy: .public) matched")
                guard result.isSuccess else { throw Self.gzipFailure(path: sourceURL.path, result: result) }
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

        try await reservePost(sequenceCount: sequenceCount, kind: .first, at: now())

        let body = putFormBody(
            query: query,
            program: program,
            database: database,
            entrezQuery: entrezQuery,
            evalue: evalue,
            maxTargetSeqs: maxTargetSeqs,
            megablast: megablast,
            extraParameters: extraParameters
        )
        switch try await putOnce(Data(body.utf8)) {
        case .accepted(let submission):
            return submission
        case .noRID(let page):
            throw BlastServiceError.ridParsingFailed(responseBody: String(page.prefix(500)))
        case .busy(let status, let body), .refused(let status, let body):
            throw BlastServiceError.httpError(statusCode: status, body: body)
        case .notReached(let reason), .lostAfterSending(let reason):
            throw BlastServiceError.networkFailed(message: reason)
        }
    }

    /// The Put body of a search, form-encoded in the order NCBI has always been sent it.
    nonisolated func putFormBody(
        query: String,
        program: String,
        database: String,
        entrezQuery: String?,
        evalue: Double,
        maxTargetSeqs: Int,
        megablast: Bool,
        extraParameters: [String: String]
    ) -> String {
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

        return formEncode(params)
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
        try await statusOnce(rid: rid).status
    }

    /// Retrieves BLAST results in JSON2 format.
    ///
    /// - Parameter rid: The Request ID whose results to retrieve
    /// - Returns: Parsed search results for each query sequence
    /// - Throws: ``BlastServiceError`` on HTTP or parsing errors
    public func getResults(rid: String) async throws -> [BlastSearchResult] {
        try await parseReply(try await fetchOnce(rid: rid))
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

    /// Parses the BLAST status response. Its QBlastInfo blocks hold `Status` and, on READY, `ThereAreHits`.
    /// Each ``BlastJobStatus`` case says what its answer means. A page with no `Status` line is no news,
    /// and `Status=UNKNOWN` is NCBI's own answer.
    ///
    /// - Parameter body: The response body text
    /// - Returns: The parsed job status
    func parseStatusResponse(_ body: String) -> BlastJobStatus {
        guard let status = extractQBlastValue(from: body, key: "Status") else {
            return .noStatusLine
        }

        switch status.uppercased() {
        case "READY":
            return .ready(thereAreHits: extractQBlastValue(from: body, key: "ThereAreHits").flatMap { ["YES": true, "NO": false][$0.uppercased()] })
        case "WAITING":
            return .waiting(queuePosition: extractQBlastValue(from: body, key: "ThereAre").flatMap(Int.init))
        case "UNKNOWN":
            return .unknown
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
    func decompressZIPResponse(_ zipData: Data) async throws -> Data {
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
        let unzip = ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-o", "-q", tempZIP.path, "-d", extractDir.path],
            environment: ["PATH": "/usr/bin:/bin"],
            stdout: .discard,
            stderr: .discard,
            label: "unzip"
        )
        let result: ToolProcessResult
        do {
            result = try await ToolProcess.run(unzip)
        } catch let error as ToolProcessError {
            if case .cancelled = error { throw CancellationError() }
            throw BlastServiceError.resultParsingFailed(
                message: "Failed to launch unzip: \(error.localizedDescription)"
            )
        }

        guard result.isSuccess else {
            throw BlastServiceError.resultParsingFailed(
                message: "ZIP extraction failed (exit \(result.status))"
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

        // Sort RID_2.json before RID_10.json so entries keep submission order,
        // which `reconcile` relies on for entries without a usable title.
        for file in extractedFiles.sorted(by: Self.zipEntryOrder) {
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

    /// Orders extracted ZIP members by the trailing number of their base
    /// name (`RID_2` before `RID_10`), then by name.
    nonisolated static func zipEntryOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        func trailingNumber(_ url: URL) -> Int? {
            let base = url.deletingPathExtension().lastPathComponent
            let digits = base.reversed().prefix(while: \.isNumber)
            return digits.isEmpty ? nil : Int(String(digits.reversed()))
        }
        switch (trailingNumber(lhs), trailingNumber(rhs)) {
        case let (l?, r?) where l != r: return l < r
        default: return lhs.lastPathComponent < rhs.lastPathComponent
        }
    }

    nonisolated func extractURLErrorCode(from error: Error) -> URLError.Code? {
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

    private nonisolated static func gzipFailure(path: String, result: ToolProcessResult) -> BlastServiceError {
        let detail = result.incompleteOutputReason ?? result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = detail.isEmpty ? "" : ": \(detail)"
        return .inputReadFailed(message: "gzip decompression failed for \(path) with exit status \(result.status)\(suffix)")
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

    /// Counts one POST against LGE's own limit for its kind, or refuses it with no contact.
    package func reservePost(sequenceCount: Int, kind: BlastSubmissionKind, at date: Date) async throws {
        try await submissionLedger.reserve(
            count: max(0, sequenceCount),
            kind: kind,
            at: date,
            limit: rateLimits.limit(for: kind)
        )
    }

    func acquireSubmissionSlot(maxConcurrentSubmissions: Int) async throws {
        let limit = max(1, maxConcurrentSubmissions)
        while activeSubmissionCount >= limit {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(rateLimits.submissionSlotPollInterval))
        }
        activeSubmissionCount += 1
    }
}
