// SRAService.swift - NCBI Sequence Read Archive integration
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: NCBI Integration Lead (Role 12)

import Foundation
import Darwin
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
    public struct FASTQDownloadStepTrace: Sendable, Equatable {
        public let toolName: String
        public let toolVersion: String
        public let command: [String]
        public let inputs: [String]
        public let outputs: [URL]
        public let exitCode: Int32?
        public let wallTime: TimeInterval
        public let stderr: String?
        public let startedAt: Date
        public let completedAt: Date

        public init(
            toolName: String,
            toolVersion: String,
            command: [String],
            inputs: [String],
            outputs: [URL],
            exitCode: Int32?,
            wallTime: TimeInterval,
            stderr: String?,
            startedAt: Date,
            completedAt: Date
        ) {
            self.toolName = toolName
            self.toolVersion = toolVersion
            self.command = command
            self.inputs = inputs
            self.outputs = outputs
            self.exitCode = exitCode
            self.wallTime = wallTime
            self.stderr = stderr
            self.startedAt = startedAt
            self.completedAt = completedAt
        }
    }

    public typealias DownloadTraceHandler = @Sendable (FASTQDownloadStepTrace) -> Void

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

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        return (error as? URLError)?.code == .cancelled
    }

    let ncbiService: NCBIService
    let httpClient: HTTPClient
    private let homeDirectoryProvider: @Sendable () -> URL
    private let appIdentity: LungfishAppIdentity

    /// Closure type used to inject custom download strategies (primarily for tests).
    public typealias DownloadStrategy = @Sendable (_ accession: String, _ outputDir: URL?) async throws -> [URL]

    let enaDownloader: DownloadStrategy?
    let toolkitDownloader: DownloadStrategy?
    /// Runs `prefetch` and `fasterq-dump`, or nil for the managed sra-tools environment's.
    private let toolkitRunner: SRAToolkitRunner?

    // MARK: - Initialization

    /// Creates a new SRA service.
    ///
    /// - Parameters:
    ///   - ncbiService: NCBI service for E-utilities access
    ///   - httpClient: HTTP client for direct API calls
    ///   - toolkitRunner: Runs the SRA Toolkit in place of the managed
    ///     sra-tools environment, so a test spawns no tool.
    public init(
        ncbiService: NCBIService = NCBIService(),
        httpClient: HTTPClient = URLSessionHTTPClient(),
        homeDirectoryProvider: @escaping @Sendable () -> URL = {
            FileManager.default.homeDirectoryForCurrentUser
        },
        appIdentity: LungfishAppIdentity = .current,
        toolkitRunner: SRAToolkitRunner? = nil
    ) {
        self.ncbiService = ncbiService
        self.httpClient = httpClient
        self.homeDirectoryProvider = homeDirectoryProvider
        self.appIdentity = appIdentity
        self.enaDownloader = nil
        self.toolkitDownloader = nil
        self.toolkitRunner = toolkitRunner
    }

    /// Creates a new SRA service with injectable download strategies.
    ///
    /// Used primarily by tests to substitute the ENA and Toolkit download paths
    /// without performing real network or filesystem work.
    ///
    /// - Parameters:
    ///   - enaDownloader: Optional override for the ENA download strategy.
    ///   - toolkitDownloader: Optional override for the SRA Toolkit download strategy.
    public init(
        enaDownloader: DownloadStrategy? = nil,
        toolkitDownloader: DownloadStrategy? = nil
    ) {
        self.ncbiService = NCBIService()
        self.httpClient = URLSessionHTTPClient()
        self.homeDirectoryProvider = { FileManager.default.homeDirectoryForCurrentUser }
        self.appIdentity = .current
        self.enaDownloader = enaDownloader
        self.toolkitDownloader = toolkitDownloader
        self.toolkitRunner = nil
    }

    /// Creates a service that performs the real ENA download through the given
    /// HTTP client but substitutes the SRA Toolkit path.
    ///
    /// Used by tests that exercise `downloadFASTQWithFallback` end to end
    /// against a scripted ENA mirror without spawning prefetch/fasterq-dump.
    ///
    /// - Parameters:
    ///   - ncbiService: NCBI service for E-utilities access.
    ///   - httpClient: HTTP client used for the ENA portal lookup and file downloads.
    ///   - toolkitDownloader: Replacement for the SRA Toolkit download strategy.
    public init(
        ncbiService: NCBIService,
        httpClient: HTTPClient,
        toolkitDownloader: DownloadStrategy?
    ) {
        self.ncbiService = ncbiService
        self.httpClient = httpClient
        self.homeDirectoryProvider = { FileManager.default.homeDirectoryForCurrentUser }
        self.appIdentity = .current
        self.enaDownloader = nil
        self.toolkitDownloader = toolkitDownloader
        self.toolkitRunner = nil
    }

    // MARK: - Search

    /// Searches SRA for datasets matching the query.
    ///
    /// - Parameter query: Search query
    /// - Returns: Search results with SRA run information
    public func search(_ query: SearchQuery) async throws -> SRASearchResults {
        // Use NCBI ESearch with SRA database
        let searchResult = try await ncbiService.esearchWithCount(
            database: .sra,
            term: query.term,
            retmax: query.limit,
            retstart: query.offset
        )
        let ids = searchResult.ids

        guard !ids.isEmpty else {
            return SRASearchResults(totalCount: searchResult.totalCount, runs: [])
        }

        // Get run info via EFetch
        let runs = try await fetchRunInfo(ids: ids)

        return SRASearchResults(
            totalCount: searchResult.totalCount,
            runs: runs,
            hasMore: query.offset + ids.count < searchResult.totalCount
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

        // Reuse the API key already resolved by `ncbiService` (via
        // NCBIAPIKeyResolver) instead of re-running key resolution here, so SRA
        // run-info fetches get the same 10 req/s eutils rate limit as every
        // other NCBI eutils call this service's caller configured. See F51.
        if let apiKey = await ncbiService.resolvedAPIKey {
            components.queryItems?.append(URLQueryItem(name: "api_key", value: apiKey))
        }

        var request = URLRequest(url: components.url!)
        request.setValue("Lungfish Genome Explorer", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let data = try await fetchRunInfoData(request: request)

        guard let content = String(data: data, encoding: .utf8) else {
            throw SRAError.parseError("Invalid encoding")
        }

        return SRARunInfoCSVParser.parseRows(content)
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

    // MARK: - Download

    /// Downloads FASTQ files for an SRA run.
    ///
    /// Requires SRA Toolkit (prefetch + fasterq-dump) to be installed.
    ///
    /// - Parameters:
    ///   - accession: SRA run accession (e.g., SRR11140748)
    ///   - outputDir: Directory for output files (defaults to temp)
    ///   - progress: Optional progress callback (0.0-1.0)
    /// - Returns: This run's FASTQ files that the download wrote. Other runs'
    ///   files and older files in `outputDir` are never returned, and the
    ///   archive `prefetch` added is removed once `fasterq-dump` succeeds.
    /// - Throws: A one-line `SRAError` naming the tool that failed, its exit
    ///   status and its error line. Its whole standard error goes to the log
    ///   and to its step trace. When `fasterq-dump` fails or is cancelled,
    ///   the reads it wrote are removed, so no partial mate stays.
    public func downloadFASTQ(
        accession: String,
        outputDir: URL? = nil,
        progress: (@Sendable (Double) -> Void)? = nil,
        trace: DownloadTraceHandler? = nil
    ) async throws -> [URL] {
        guard let toolkit = toolkitRunner ?? managedToolkitRunner() else {
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
        // Noted before the tools run, since the folder can hold other runs' files.
        let runFiles = SRAToolkitRunFiles(accession: accession, outputDirectory: outputDirectory)

        let sraFile = outputDirectory
            .appendingPathComponent(accession)
            .appendingPathComponent("\(accession).sra")

        // Step 1: Prefetch the SRA file
        progress?(0.1)
        let prefetchStartedAt = Date()
        let prefetchResult = try await toolkit.run(toolkit.prefetch, [accession, "-O", outputDirectory.path])
        let prefetchCompletedAt = Date()
        trace?(
            FASTQDownloadStepTrace(
                toolName: "prefetch",
                toolVersion: "sra-tools",
                command: [toolkit.prefetch.path, accession, "-O", outputDirectory.path],
                inputs: [accession],
                outputs: [sraFile],
                exitCode: prefetchResult.exitCode,
                wallTime: prefetchCompletedAt.timeIntervalSince(prefetchStartedAt),
                stderr: prefetchResult.stderr,
                startedAt: prefetchStartedAt,
                completedAt: prefetchCompletedAt
            )
        )

        if prefetchResult.exitCode != 0 {
            logger.error("prefetch failed: \(prefetchResult.stderr, privacy: .public)")
            throw SRAError.downloadFailed(SRADownloadMessages.toolFailure(
                tool: "prefetch", exitCode: prefetchResult.exitCode, stderr: prefetchResult.stderr
            ))
        }

        progress?(0.5)

        // Step 2: fasterq-dump --split-3 writes mates to <run>_1 and <run>_2, reads without a mate to <run>.fastq
        let fasterqTempDirectory = try Self.createFasterqTempDirectory(for: outputDirectory)
        defer { try? FileManager.default.removeItem(at: fasterqTempDirectory) }

        let fasterqArguments = [
            sraFile.path,
            "-O", outputDirectory.path,
            "-t", fasterqTempDirectory.path,
            "--split-3",
            "--threads", "4"
        ]
        let fasterqStartedAt = Date()
        let fasterqResult: SRAToolkitRunner.Result
        do {
            fasterqResult = try await toolkit.run(toolkit.fasterqDump, fasterqArguments)
        } catch {
            // A cancel can stop fasterq-dump partway through writing a mate.
            runFiles.removeWrittenFASTQFiles()
            throw error
        }
        let fasterqCompletedAt = Date()

        // Shared trace fields for both the failure and success paths; only `outputs` differs.
        let makeFasterqTrace: ([URL]) -> FASTQDownloadStepTrace = { outputs in
            FASTQDownloadStepTrace(
                toolName: "fasterq-dump",
                toolVersion: "sra-tools",
                command: [toolkit.fasterqDump.path] + fasterqArguments,
                inputs: [sraFile.path],
                outputs: outputs,
                exitCode: fasterqResult.exitCode,
                wallTime: fasterqCompletedAt.timeIntervalSince(fasterqStartedAt),
                stderr: fasterqResult.stderr,
                startedAt: fasterqStartedAt,
                completedAt: fasterqCompletedAt
            )
        }

        if fasterqResult.exitCode != 0 {
            trace?(makeFasterqTrace([]))
            logger.error("fasterq-dump failed: \(fasterqResult.stderr, privacy: .public)")
            runFiles.removeWrittenFASTQFiles()
            throw SRAError.conversionFailed(SRADownloadMessages.toolFailure(
                tool: "fasterq-dump", exitCode: fasterqResult.exitCode, stderr: fasterqResult.stderr
            ))
        }

        progress?(0.9)

        // Only this run's reads that fasterq-dump wrote, never another run's
        // file or an older file of this run.
        let fastqFiles = runFiles.writtenFASTQFiles()
        trace?(makeFasterqTrace(fastqFiles))
        guard !fastqFiles.isEmpty else {
            throw SRAError.conversionFailed("fasterq-dump wrote no FASTQ file for \(accession)")
        }
        runFiles.removePrefetchFiles()

        progress?(1.0)

        logger.info("Downloaded \(fastqFiles.count, privacy: .public) FASTQ files for \(accession, privacy: .public)")

        return fastqFiles
    }

    // MARK: - SRA Toolkit Detection

    internal static func managedExecutableURL(
        executableName: String,
        homeDirectory: URL,
        appIdentity: LungfishAppIdentity = .current
    ) -> URL {
        let store = ManagedStorageConfigStore(homeDirectory: homeDirectory, appIdentity: appIdentity)
        // Match CoreToolLocator: an explicit nondefault home pins tool discovery
        // to that home, while normal app/CLI discovery honors ambient overrides.
        let defaultHome = FileManager.default.homeDirectoryForCurrentUser
        let environment = homeDirectory.standardizedFileURL == defaultHome.standardizedFileURL
            ? ProcessInfo.processInfo.environment : [:]
        return store.currentCondaRootURL(environment: environment)
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

    private func managedToolkitRunner() -> SRAToolkitRunner? {
        let homeDirectory = homeDirectoryProvider()
        let prefetchURL = Self.managedExecutableURL(
            executableName: "prefetch",
            homeDirectory: homeDirectory,
            appIdentity: appIdentity
        )
        let fasterqDumpURL = Self.managedExecutableURL(
            executableName: "fasterq-dump",
            homeDirectory: homeDirectory,
            appIdentity: appIdentity
        )

        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: prefetchURL.path),
              fileManager.isExecutableFile(atPath: fasterqDumpURL.path) else {
            logger.warning("SRA Toolkit not found in managed environment")
            return nil
        }

        return SRAToolkitRunner(prefetch: prefetchURL, fasterqDump: fasterqDumpURL) { executable, arguments in
            try await self.runCommand(executable.path, arguments: arguments)
        }
    }

    /// Checks if SRA Toolkit is available.
    public var isSRAToolkitAvailable: Bool {
        toolkitRunner != nil || managedToolkitRunner() != nil
    }

    // MARK: - Process Execution

    private final class PipeDataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func set(_ data: Data) {
            lock.lock()
            storage = data
            lock.unlock()
        }

        func stringValue() -> String {
            lock.lock()
            let data = storage
            lock.unlock()
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    private final class CommandCancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancellationRequested = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancellationRequested
        }

        func store(_ process: Process) {
            let shouldTerminate: Bool
            lock.lock()
            self.process = process
            shouldTerminate = cancellationRequested
            lock.unlock()

            if shouldTerminate {
                terminate(process)
            }
        }

        func cancel() {
            let process: Process?
            lock.lock()
            cancellationRequested = true
            process = self.process
            lock.unlock()

            guard let process else { return }
            terminate(process)
        }

        func terminateIfCancelled() {
            let process: Process?
            lock.lock()
            process = cancellationRequested ? self.process : nil
            lock.unlock()

            guard let process else { return }
            terminate(process)
        }

        private func terminate(_ process: Process) {
            let pid = process.processIdentifier
            guard pid > 0 else {
                if process.isRunning {
                    process.terminate()
                }
                return
            }
            let initialTree = processTree(rootPID: pid)
            signal(processIDs: initialTree, rootPID: pid, signal: SIGTERM)
            if process.isRunning {
                process.terminate()
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                let expandedTree = self.uniqueProcessIDs(
                    initialTree + self.processTree(rootPID: pid) + initialTree.flatMap(self.processTree(rootPID:))
                )
                self.signal(processIDs: expandedTree, rootPID: pid, signal: SIGKILL)
            }
        }

        private func processTree(rootPID: Int32) -> [Int32] {
            var processIDs = descendantProcessIDs(of: rootPID)
            processIDs.append(rootPID)
            return uniqueProcessIDs(processIDs)
        }

        private func descendantProcessIDs(of rootPID: Int32) -> [Int32] {
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-Ao", "pid=,ppid="]
            let stdoutPipe = Pipe()
            ps.standardOutput = stdoutPipe
            ps.standardError = Pipe()

            do {
                try ps.run()
            } catch {
                return []
            }

            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            ps.waitUntilExit()
            guard ps.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else {
                return []
            }

            var childrenByParent: [Int32: [Int32]] = [:]
            for line in output.split(separator: "\n") {
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count == 2,
                      let pid = Int32(fields[0]),
                      let parentPID = Int32(fields[1]) else {
                    continue
                }
                childrenByParent[parentPID, default: []].append(pid)
            }

            var descendants: [Int32] = []
            var queue = [rootPID]
            var seen: Set<Int32> = [rootPID]
            while !queue.isEmpty {
                let parent = queue.removeFirst()
                for child in childrenByParent[parent, default: []] where seen.insert(child).inserted {
                    descendants.append(child)
                    queue.append(child)
                }
            }
            return descendants
        }

        private func signal(processIDs: [Int32], rootPID: Int32, signal: Int32) {
            let descendants = processIDs.filter { $0 != rootPID }
            for pid in descendants.reversed() where processExists(pid: pid) {
                kill(pid, signal)
            }
            if processExists(pid: rootPID) {
                kill(rootPID, signal)
            }
        }

        private func processExists(pid: Int32) -> Bool {
            if kill(pid, 0) == 0 {
                return true
            }
            return errno != ESRCH
        }

        private func uniqueProcessIDs(_ processIDs: [Int32]) -> [Int32] {
            var seen = Set<Int32>()
            return processIDs.filter { pid in
                pid > 0 && seen.insert(pid).inserted
            }
        }
    }

    private func runCommand(_ path: String, arguments: [String]) async throws -> SRAToolkitRunner.Result {
        let cancellationState = CommandCancellationState()

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: path)
                    process.arguments = arguments
                    cancellationState.store(process)

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    do {
                        try process.run()
                        cancellationState.terminateIfCancelled()

                        let stdoutData = PipeDataBox()
                        let stderrData = PipeDataBox()
                        let readGroup = DispatchGroup()

                        readGroup.enter()
                        DispatchQueue.global(qos: .utility).async {
                            stdoutData.set(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                            readGroup.leave()
                        }
                        readGroup.enter()
                        DispatchQueue.global(qos: .utility).async {
                            stderrData.set(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                            readGroup.leave()
                        }

                        process.waitUntilExit()
                        readGroup.wait()

                        if cancellationState.isCancelled {
                            continuation.resume(throwing: CancellationError())
                            return
                        }

                        let result = SRAToolkitRunner.Result(
                            exitCode: process.terminationStatus,
                            stdout: stdoutData.stringValue(),
                            stderr: stderrData.stringValue()
                        )

                        continuation.resume(returning: result)
                    } catch {
                        if cancellationState.isCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        } onCancel: {
            cancellationState.cancel()
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
