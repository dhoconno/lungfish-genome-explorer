// BlastService+Search.swift - One contact with NCBI at a time, and a whole search on the advancer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// What one POST of a search's form came to. Which case it is decides what the search does next
/// (ARCH-BLAST-RESILIENCE section 5).
package enum BlastPutAnswer: Sendable {
    /// NCBI holds the search.
    case accepted(BlastJobSubmission)
    /// The POST never left, so nothing was sent.
    case notReached(String)
    /// A 5xx, 429 or 408, so NCBI accepted nothing and may later.
    case busy(status: Int, body: String)
    /// Any other HTTP answer, so NCBI accepted nothing.
    case refused(status: Int, body: String)
    /// A 200 page with no RID on it.
    case noRID(page: String)
    /// The POST went out and no answer came, so nobody knows whether NCBI has it.
    case lostAfterSending(String)
}

/// What one status check read.
package struct BlastSearchStatusAnswer: Sendable {
    package let status: BlastJobStatus
    /// The page it was read from, which holds NCBI's words on a failure.
    package let page: String
}

extension BlastSearchFile.Origin {
    /// `standIn` for a debug run that a stand-in answers, and `ncbi` otherwise.
    package init(environment: [String: String]) {
        self = BlastStandInState(environment: environment) == nil ? .ncbi : .standIn
    }

    /// Whether a run with `environment` may contact the service of a search of this origin. A release build never
    /// contacts NCBI for a stand-in's search, and a debug run on a stand-in never touches a search at NCBI (item 20).
    package func allowsContact(environment: [String: String]) -> Bool {
        self == BlastSearchFile.Origin(environment: environment)
    }
}

extension BlastService {
    private nonisolated static let busyStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]

    /// URL errors that mean the request never left this Mac.
    private nonisolated static let notSentURLErrors: Set<URLError.Code> = [
        .cannotFindHost,
        .cannotConnectToHost,
        .dnsLookupFailed,
        .notConnectedToInternet,
        .internationalRoamingOff,
        .callIsActive,
        .dataNotAllowed,
    ]

    // MARK: One contact

    /// The POSTs this Mac has sent in the last 24 hours, by LGE's own count, which NCBI's may differ from. Past
    /// ``BlastSearchPolicy/postsADayBeforeNoCopies`` LGE makes no automatic copy, and a person may be told.
    package func postsInTheLastDay(at date: Date) async -> Int {
        await submissionLedger.postsInTheLastDay(at: date)
    }

    /// The Put body `request` makes.
    package func putForm(for request: BlastVerificationRequest) throws -> Data {
        let extraParameters = try BlastVerificationRequest.parseBlastURLAPIExtraParameters(request.extraArgs)
        return Data(putFormBody(
            query: request.toMultiFASTA(),
            program: request.program,
            database: request.database,
            entrezQuery: request.entrezQuery,
            evalue: request.eValueThreshold,
            maxTargetSeqs: request.maxTargetSeqs,
            megablast: request.program == "blastn",
            extraParameters: extraParameters
        ).utf8)
    }

    /// One POST of `form`, inside this process's limit on POSTs in flight.
    package func sendPut(_ form: Data, maxConcurrentSubmissions: Int) async throws -> BlastPutAnswer {
        try await acquireSubmissionSlot(maxConcurrentSubmissions: maxConcurrentSubmissions)
        defer { activeSubmissionCount = max(0, activeSubmissionCount - 1) }
        return try await putOnce(form)
    }

    /// One POST of `form`, with no retry. The caller decides what its answer means.
    func putOnce(_ form: Data) async throws -> BlastPutAnswer {
        try await searchShared.contactGate?.takeSlot()
        var request = URLRequest(url: blastBaseURL, timeoutInterval: BlastSearchPolicy.putTimeout)
        request.httpMethod = "POST"
        let address = await contactAddressInForce()
        request.httpBody = form + Data("&email=\(Self.formEscape(address))".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let reason = error.localizedDescription
            if let code = extractURLErrorCode(from: error), Self.notSentURLErrors.contains(code) {
                return .notReached(reason)
            }
            return .lostAfterSending(reason)
        }
        let body = String(decoding: data, as: UTF8.self)
        guard let http = response as? HTTPURLResponse else { return .lostAfterSending("Non-HTTP response") }
        // NCBI's page can repeat the request. The request ID is read from the page as NCBI sent it, so a search that
        // started is never lost to the scrub, and only the text kept afterwards is cleared of the address.
        guard http.statusCode == 200 else {
            let page = BlastContactAddress.scrubbed(body, address: address)
            return Self.busyStatusCodes.contains(http.statusCode)
                ? .busy(status: http.statusCode, body: page)
                : .refused(status: http.statusCode, body: page)
        }
        guard let submission = try? parseSubmissionResponse(body) else {
            return .noRID(page: BlastContactAddress.scrubbed(body, address: address))
        }
        return .accepted(submission)
    }

    /// One status check, with no retry. It throws when nothing came back that can be read.
    package func statusOnce(rid: String) async throws -> BlastSearchStatusAnswer {
        let url = await contactURL([
            URLQueryItem(name: "CMD", value: "Get"),
            URLQueryItem(name: "RID", value: rid),
            URLQueryItem(name: "FORMAT_OBJECT", value: "SearchInfo"),
        ])
        let page = String(decoding: try await getOnce(url, what: "status check"), as: UTF8.self)
        // The status is read from the page as NCBI sent it, and the page kept for words is cleared of the address.
        return BlastSearchStatusAnswer(
            status: parseStatusResponse(page),
            page: BlastContactAddress.scrubbed(page, address: Self.addressSent(in: url))
        )
    }

    /// The address a GET carries, which is the one a page from NCBI can repeat.
    private static func addressSent(in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "email" }?.value
    }

    /// One fetch of the reply, with no retry and nothing unzipped or parsed.
    package func fetchOnce(rid: String) async throws -> Data {
        let url = await contactURL([
            URLQueryItem(name: "CMD", value: "Get"),
            URLQueryItem(name: "RID", value: rid),
            URLQueryItem(name: "FORMAT_TYPE", value: "JSON2"),
            URLQueryItem(name: "FORMAT_OBJECT", value: "Alignment"),
        ])
        return try await getOnce(url, what: "result fetch")
    }

    /// A GET of `items` with the tool and the address NCBI asks for. `URLQueryItem` leaves a plus as it is, which a
    /// form parser reads as a space, so a plus goes out as `%2B`.
    private func contactURL(_ items: [URLQueryItem]) async -> URL {
        var components = URLComponents(url: blastBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = items + [
            URLQueryItem(name: "tool", value: toolName),
            URLQueryItem(name: "email", value: await contactAddressInForce()),
        ]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// The address NCBI gets with this contact, read anew each time, so it is never held by a record or an argument
    /// and a change in Settings reaches a search already running (O132).
    private func contactAddressInForce() async -> String {
        await searchShared.contactAddress?.addressInForce() ?? toolEmail
    }

    private func getOnce(_ url: URL, what: String) async throws -> Data {
        try await searchShared.contactGate?.takeSlot()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw BlastServiceError.networkFailed(message: "The BLAST \(what) failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw BlastServiceError.submissionFailed(message: "The BLAST \(what) returned a non-HTTP response")
        }
        guard http.statusCode == 200 else {
            throw BlastServiceError.httpError(
                statusCode: http.statusCode,
                body: BlastContactAddress.scrubbed(String(decoding: data, as: UTF8.self), address: Self.addressSent(in: url))
            )
        }
        return data
    }

    /// The search results a saved reply holds. NCBI sometimes sends JSON2 as a ZIP archive, which is unpacked first.
    package func parseReply(_ data: Data) async throws -> [BlastSearchResult] {
        let isZIP = data.count >= 4 && Array(data.prefix(4)) == [0x50, 0x4B, 0x03, 0x04]
        return try parseJSON2Results(isZIP ? await decompressZIPResponse(data) : data)
    }

    // MARK: A whole search

    /// Creates the search in `folder`, which already holds `query`, and runs it to an ending.
    package func search(
        request: BlastVerificationRequest,
        in folder: URL,
        query: BlastSubmissionRecord.Query,
        submitArgv: [String],
        lineage: BlastSubmissionRecord.Lineage? = nil,
        sourceStamp: String? = nil,
        origin: BlastSearchFile.Origin,
        clock: BlastSearchClock,
        noun: String,
        pass: BlastSearchAdvancer.Pass = .toAnEnding,
        outlivesTheRun: Bool = true,
        progress: @escaping BlastSearchAdvancer.Progress,
        publish: @escaping BlastSearchAdvancer.Publish
    ) async throws -> BlastSearchOutcome {
        let index = outlivesTheRun ? searchShared.inFlight : nil
        let advancer = BlastSearchAdvancer(
            service: self, store: BlastSearchStore(folder: folder), request: request,
            clock: clock, noun: noun, progress: progress, publish: publish, pass: pass, index: index
        )
        let searchID = UUID()
        var lock: BlastSearchLock?
        if case .taken(let taken) = await index?.takeLock(of: searchID) { lock = taken }
        defer { lock?.release() }
        let file = try await advancer.create(
            searchID: searchID, origin: origin, query: query, submitArgv: submitArgv, lineage: lineage, sourceStamp: sourceStamp
        )
        if let index { return try await index.runStoppable(searchID) { try await advancer.advance(file) } }
        return try await advancer.advance(file)
    }

    /// Submits reads for BLAST verification against a specific taxon and returns the judged result.
    ///
    /// The search runs on ``BlastSearchAdvancer`` in a temporary folder that goes with the run, and only NCBI's answer
    /// or a cancel ends it. A caller that needs the search to outlive the run names a folder, as `blast verify` does.
    ///
    /// - Parameters:
    ///   - request: The verification request with sequences and parameters
    ///   - progress: Optional callback for progress updates (fraction 0-1, message)
    /// - Returns: The verification result with per-read verdicts and summary
    /// - Throws: ``BlastServiceError`` if the search ends without a result
    public func verify(
        request: BlastVerificationRequest,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> BlastVerificationResult {
        try await verify(request: request, searchFolder: nil, submitArgv: [], clock: .system, progress: progress)
    }

    /// ``verify(request:progress:)`` with the search kept in `searchFolder`, so `blast resume` can go on with it, and
    /// on `clock`. The folder gets the query as `query.fasta`.
    package func verify(
        request: BlastVerificationRequest,
        searchFolder: URL?,
        submitArgv: [String],
        clock: BlastSearchClock,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> BlastVerificationResult {
        guard !request.sequences.isEmpty else { throw BlastServiceError.noSequences }
        let folder = searchFolder ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-blast-search-\(UUID().uuidString)", isDirectory: true)
        defer { if searchFolder == nil { try? FileManager.default.removeItem(at: folder) } }

        let fasta = Data(request.toMultiFASTA().utf8)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try DurableReplace.replace(fasta, named: BlastSubmissionRecord.queryFileName, in: folder)
        let outcome = try await search(
            request: request,
            in: folder,
            query: BlastSubmissionRecord.Query(
                fileName: BlastSubmissionRecord.queryFileName,
                sha256: BlastSearchStore.digest(of: fasta),
                sequenceCount: request.sequences.count
            ),
            submitArgv: submitArgv,
            origin: BlastSearchFile.Origin(environment: ProcessInfo.processInfo.environment),
            clock: clock,
            noun: "reads",
            outlivesTheRun: searchFolder != nil,
            progress: { progress?($0, $1) },
            publish: { _ in }
        )
        switch outcome {
        case .done(let result):
            return result
        case .ended(_, let words), .needsAPerson(let words), .parked(let words):
            throw BlastServiceError.searchEnded(words: words)
        }
    }
}
