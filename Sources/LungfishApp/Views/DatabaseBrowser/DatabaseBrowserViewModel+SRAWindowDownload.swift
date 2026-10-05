// DatabaseBrowserViewModel+SRAWindowDownload.swift - The window's SRA download and CLI import task
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import os

private let logger = Logger(subsystem: LogSubsystem.app, category: "DatabaseBrowser")

final class SRAGUIDownloadTraceCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var traces: [SRAService.FASTQDownloadStepTrace] = []

    func record(_ trace: SRAService.FASTQDownloadStepTrace) {
        lock.lock()
        traces.append(trace)
        lock.unlock()
    }

    var steps: [SRAService.FASTQDownloadStepTrace] {
        lock.lock()
        defer { lock.unlock() }
        return traces
    }
}

extension DatabaseBrowserViewModel {
    // MARK: - ENA/SRA Download with CLI Import

    /// Starts the SRA download and CLI import pipeline for the given records.
    ///
    /// Called from the `FASTQImportConfigSheet` `onImport` callback after the user
    /// confirms import settings. Downloads FASTQ files from ENA, then runs
    /// `CLIImportRunner` to create `.lungfishfastq` bundles, and finally augments
    /// each bundle's metadata sidecar with ENA provenance info.
    func startENADownloadTask(
        records: [SearchResultRecord],
        importConfig: FASTQImportConfiguration,
        downloadCenterTaskID: UUID,
        totalCount: Int
    ) {
        let ena = enaService
        let sra = SRAWindowDownloadSeams.sraService ?? SRAService(ncbiService: ncbiService)
        // Recorded in the GUI provenance envelope; the argv itself comes from
        // `sraImportCLIArguments` so the two never disagree.
        let platformStr = importConfig.cliPlatformValue
        let recipeName = FASTQIngestionService.resolvedRecipeName(for: importConfig)
        let compressionStr = importConfig.compressionLevel?.rawValue ?? "balanced"
        let qualityBinning = importConfig.qualityBinning.rawValue
        let optimizeStorage = !importConfig.skipClumpify && importConfig.clumpingTool != .none

        let enaRouteContext = routeContext
        let projectURL = enaRouteContext?.projectURL
        let ncbiRunsFromSearch = sraNCBIRunsFromSearch
        // One snapshot for the whole batch, so a change mid-batch does not
        // split it between archives.
        let sourcePreference = sraDownloadPreference()

        let downloadTask = Task.detached {
            var downloadedURLs: [URL] = []
            var failedCount = 0
            var failureDetails: [String] = []

            if let projectURL {
                let canWriteProject = await performOnMainRunLoopAsync {
                    AppDelegate.shared?.canWriteProjectOutputs(
                        projectURL: projectURL,
                        windowStateScope: enaRouteContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
                        workflowName: "SRA/ENA download",
                        presentingWindow: NSApp.keyWindow ?? NSApp.mainWindow
                    ) ?? true
                }
                guard canWriteProject else {
                    performOnMainRunLoop {
                        _ = DownloadCenter.shared.fail(
                            id: downloadCenterTaskID,
                            detail: "Project is open read only"
                        )
                    }
                    return
                }
            }

            let batchDir = try ProjectTempDirectory.create(prefix: "sra-batch-", in: projectURL)
            logger.info("startENADownloadTask: Created batch directory at \(batchDir.path, privacy: .public)")

            for (index, record) in records.enumerated() {
                // A cancel from the Operations panel stops the batch before
                // the next run.
                if Task.isCancelled { break }
                let progressFraction = Double(index) / Double(totalCount)
                performOnMainRunLoop {
                    _ = DownloadCenter.shared.update(
                        id: downloadCenterTaskID,
                        progress: progressFraction,
                        detail: "Downloading \(record.accession) (\(index + 1)/\(totalCount))"
                    )
                }

                do {
                    // 1. Fetch ENA read record for FASTQ URLs and metadata
                    logger.info("startENADownloadTask: Downloading FASTQ for SRA run \(record.accession, privacy: .public)")
                    performOnMainRunLoop {
                        _ = DownloadCenter.shared.update(
                            id: downloadCenterTaskID,
                            progress: progressFraction,
                            detail: "Fetching FASTQ URLs for \(record.accession)..."
                        )
                    }

                    let toolkitTraceCollector = SRAGUIDownloadTraceCollector()
                    func logLine(_ line: String, _ level: OperationLogLevel) {
                        performOnMainRunLoop {
                            _ = DownloadCenter.shared.updateWithLog(id: downloadCenterTaskID, progress: progressFraction, detail: line, level: level)
                        }
                    }

                    func downloadViaToolkit(status: SRAWindowToolkitStatus, into folder: URL) async throws -> [URL] {
                        // Logged, so the row's history keeps the route and why.
                        logLine(status.line, status.level)
                        return try await sra.downloadFASTQ(
                            accession: record.accession,
                            outputDir: folder,
                            progress: { toolkitProgress in
                                performOnMainRunLoop {
                                    _ = DownloadCenter.shared.update(
                                        id: downloadCenterTaskID,
                                        progress: min(
                                            progressFraction + (toolkitProgress / Double(max(totalCount, 1))),
                                            1.0
                                        ),
                                        detail: "Downloading \(record.accession) via SRA Toolkit..."
                                    )
                                }
                            },
                            trace: { trace in
                                toolkitTraceCollector.record(trace)
                            }
                        )
                    }

                    // 2. Download the run's FASTQ files into its own folder of the batch.
                    // An ENA error, a run ENA lacks or a record without FASTQ links
                    // takes the SRA Toolkit route, which fetches the run from NCBI.
                    let accession = record.accession
                    let staged = try await self.stageSRARun(
                        accession: accession,
                        preference: sourcePreference,
                        ncbiRun: ncbiRunsFromSearch[accession],
                        in: batchDir,
                        lookUpRoute: { try await ena.fastqDownloadRoute(forRun: accession) },
                        mirrorFile: { fastqURL, fileExpectedBytes, priorBytes, totalExpectedBytes in
                            try await streamingDownload(
                                url: fastqURL,
                                totalBytes: fileExpectedBytes,
                                progressHandler: { bytesWritten, _ in
                                    let totalSoFar = priorBytes + bytesWritten
                                    performOnMainRunLoop {
                                        DownloadCenter.shared.updateBytes(
                                            id: downloadCenterTaskID,
                                            bytesDownloaded: totalSoFar,
                                            totalBytes: totalExpectedBytes
                                        )
                                    }
                                }
                            )
                        },
                        toolkit: { try await downloadViaToolkit(status: $0, into: $1) },
                        log: { logLine($0, .warning) }
                    )
                    let readRecord = staged.download.enaRecord
                    // Removed after the import or on failure, so no file of
                    // this run reaches the next one.
                    defer { staged.removeFolder() }
                    let enaDownloadSteps = staged.download.enaSteps
                    let downloadSource = staged.download.source.rawValue

                    // 3. Mates 1 and 2 import as a pair, never as one mate,
                    // with the run's reads whose mate is missing beside them
                    let reads = staged.reads

                    // 4. Run CLI import pipeline
                    performOnMainRunLoop {
                        _ = DownloadCenter.shared.update(
                            id: downloadCenterTaskID,
                            progress: progressFraction,
                            detail: "\(record.accession) importing via CLI pipeline..."
                        )
                    }

                    // Use the real project directory so CLI creates bundles
                    // directly in <project>.lungfish/Imports/ (not inside .tmp/)
                    let projectDirectory = projectURL ?? batchDir

                    let args = Self.sraImportCLIArguments(
                        importConfig: importConfig,
                        r1: reads.r1,
                        r2: reads.r2,
                        unpaired: reads.unpaired,
                        projectDirectory: projectDirectory
                    )

                    let cliStartedAt = Date()
                    let bundleURL = try await SRAWindowImportLeftovers.importRun(
                        arguments: args,
                        operationID: downloadCenterTaskID,
                        projectDirectory: projectDirectory,
                        accession: accession,
                        files: reads.files,
                        launchedAt: cliStartedAt
                    )
                    let cliCompletedAt = Date()

                    // 5. Augment metadata sidecar with ENA provenance info
                    let contents = try? FileManager.default.contentsOfDirectory(
                        at: bundleURL,
                        includingPropertiesForKeys: nil
                    )
                    if let fastqURL = contents?.first(where: {
                        $0.lastPathComponent.hasSuffix(".fastq.gz")
                            || $0.lastPathComponent.hasSuffix(".fq.gz")
                            || $0.lastPathComponent.hasSuffix(".fastq")
                            || $0.lastPathComponent.hasSuffix(".fq")
                    }) {
                        var metadata = FASTQMetadataStore.load(for: fastqURL) ?? PersistedFASTQMetadata()
                        metadata.enaReadRecord = readRecord
                        metadata.sraRunInfo = metadata.sraRunInfo ?? (readRecord == nil ? staged.ncbiRun : nil)
                        metadata.downloadDate = Date()
                        metadata.downloadSource = downloadSource
                        FASTQMetadataStore.save(metadata, for: fastqURL)

                        try writeGUISRAFASTQImportProvenance(
                            accession: record.accession,
                            readRecord: readRecord,
                            downloadSource: downloadSource, preferredSource: staged.download.preference, layoutWarning: staged.layoutWarning,
                            fallbackMessage: staged.download.fallbackMessage,
                            enaDownloadSteps: enaDownloadSteps,
                            toolkitDownloadTraces: toolkitTraceCollector.steps,
                            cliArguments: args,
                            cliStartedAt: cliStartedAt,
                            cliCompletedAt: cliCompletedAt,
                            stagedFASTQFiles: reads.files,
                            stagedReadCounts: reads.readCounts(in: metadata.readClassification),
                            finalFASTQURL: fastqURL,
                            bundleURL: bundleURL,
                            platform: platformStr,
                            recipeName: recipeName,
                            qualityBinning: qualityBinning,
                            optimizeStorage: optimizeStorage,
                            compressionLevel: compressionStr
                        )
                    }

                    logger.info("startENADownloadTask: Created bundle at \(bundleURL.path, privacy: .public)")
                    downloadedURLs.append(bundleURL)

                    // Deliver bundle immediately so it appears in sidebar right away
                    let deliverURL = bundleURL
                    performOnMainRunLoop {
                        if let handler = DownloadCenter.shared.onBundleReadyWithContext {
                            handler([deliverURL], enaRouteContext)
                        } else {
                            DownloadCenter.shared.onBundleReady?([deliverURL])
                        }
                    }

                } catch {
                    // A cancelled run is not a failure. Its folder is already
                    // removed, and the batch folder goes below.
                    if Task.isCancelled {
                        logger.info("startENADownloadTask: Cancelled during \(record.accession, privacy: .public)")
                        break
                    }
                    logger.error("startENADownloadTask: Failed for \(record.accession, privacy: .public): \(error, privacy: .public)")
                    failedCount += 1
                    failureDetails.append("\(record.accession): \(error.localizedDescription)")
                    performOnMainRunLoop {
                        _ = DownloadCenter.shared.update(
                            id: downloadCenterTaskID,
                            progress: Double(index + 1) / Double(totalCount),
                            detail: "Failed: \(record.accession) — \(error.localizedDescription)"
                        )
                    }
                }
            }

            // Clean up the batch staging directory (each run's folder is already removed)
            try? FileManager.default.removeItem(at: batchDir)
            logger.info("startENADownloadTask: Cleaned up batch staging dir")

            if Task.isCancelled {
                // The row is already cancelling, so OperationCenter records
                // this as cancelled. Bundles imported before the cancel stay.
                performOnMainRunLoop {
                    _ = DownloadCenter.shared.fail(id: downloadCenterTaskID, detail: "Cancelled by user")
                }
                return
            }

            // Complete — bundles were already delivered incrementally via onBundleReady
            let finalDownloadedCount = downloadedURLs.count
            let finalFailedCount = failedCount
            let finalFailureDetails = failureDetails
            performOnMainRunLoop {
                if finalDownloadedCount == 0 && finalFailedCount > 0 {
                    let reasonSummary = finalFailureDetails.prefix(3).joined(separator: "; ")
                    _ = DownloadCenter.shared.fail(
                        id: downloadCenterTaskID,
                        detail: reasonSummary.isEmpty
                            ? "Completed with \(finalFailedCount) failure(s)"
                            : "Completed with \(finalFailedCount) failure(s): \(reasonSummary)"
                    )
                } else {
                    let detail: String
                    if finalFailedCount > 0 {
                        let reasonSummary = finalFailureDetails.prefix(3).joined(separator: "; ")
                        detail = "Completed \(finalDownloadedCount) download(s), \(finalFailedCount) failed. \(reasonSummary)"
                    } else if totalCount == 1 {
                        detail = "FASTQ ready"
                    } else {
                        detail = "Completed \(finalDownloadedCount) file(s)"
                    }
                    // Don't pass bundleURLs — they were already delivered incrementally
                    _ = DownloadCenter.shared.complete(
                        id: downloadCenterTaskID,
                        detail: detail,
                        bundleURLs: []
                    )
                }

                logger.info("startENADownloadTask: Complete - \(finalDownloadedCount) downloaded, \(finalFailedCount) failed")
            }
        }
        // The Operations panel's Cancel stops the download, the toolkit and
        // the import of the run in progress.
        DownloadCenter.shared.setCancelCallback(for: downloadCenterTaskID) { downloadTask.cancel() }
    }
}

/// What the window's SRA download task uses in place of the real thing.
/// Only tests set it, so a batch runs without the real SRA Toolkit.
enum SRAWindowDownloadSeams {
    /// The SRA service for the SRA Toolkit route, read once when a batch
    /// starts.
    @TaskLocal static var sraService: SRAService?
}

// MARK: - Streaming Download Helper

/// Downloads a file using URLSession downloadTask with byte-level progress callbacks.
///
/// Unlike `URLSession.shared.data(for:)`, this uses the delegate-based `downloadTask`
/// API which reliably fires `didWriteData` progress callbacks. The file is written to
/// a temp location and its contents returned as Data.
///
/// - Parameters:
///   - url: The URL to download.
///   - totalBytes: Expected total size (used when Content-Length header is absent).
///   - progressHandler: Called with (bytesDownloaded, totalBytes?) during download.
/// - Returns: The downloaded data.
/// - Throws: `DatabaseServiceError` on network or HTTP errors, or a
///   `CancellationError` when the task is cancelled, even before it starts.
func streamingDownload(
    url: URL,
    totalBytes: Int64?,
    progressHandler: @escaping @Sendable (Int64, Int64?) -> Void
) async throws -> Data {
    final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let knownTotal: Int64?
        let progress: @Sendable (Int64, Int64?) -> Void
        let completion = SRAWindowTransferCompletion()

        init(knownTotal: Int64?, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
            self.knownTotal = knownTotal
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData _: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite expected: Int64) {
            let total: Int64? = expected > 0 ? expected : knownTotal
            progress(totalBytesWritten, total)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-" + location.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: location, to: tmp)
            } catch {
                completion.finish(.failure(error))
                return
            }
            guard let resp = downloadTask.response as? HTTPURLResponse,
                  (200...299).contains(resp.statusCode) else {
                try? FileManager.default.removeItem(at: tmp)
                let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
                completion.finish(.failure(DatabaseServiceError.serverError(
                    message: "HTTP \(code) downloading \(downloadTask.originalRequest?.url?.lastPathComponent ?? "file")"
                )))
                return
            }
            if !completion.finish(.success(tmp)) {
                try? FileManager.default.removeItem(at: tmp)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: (any Error)?) {
            if let error {
                completion.finish(.failure(error))
            }
        }
    }

    // An already cancelled task never creates the transfer.
    try Task.checkCancellation()

    var request = URLRequest(url: url)
    request.setValue("Lungfish Genome Explorer", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 600

    let delegate = Delegate(knownTotal: totalBytes, progress: progressHandler)
    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

    // A cancel can end the transfer before the continuation is handed over.
    // The completion keeps that early end and resumes the wait with it.
    let transfer = session.downloadTask(with: request)
    let tempURL: URL
    do {
        tempURL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.completion.wait(continuation)
                transfer.resume()
            }
        } onCancel: {
            transfer.cancel()
        }
    } catch {
        session.invalidateAndCancel()
        if Task.isCancelled {
            throw CancellationError()
        }
        throw error
    }
    session.invalidateAndCancel()

    let data = try Data(contentsOf: tempURL)
    try? FileManager.default.removeItem(at: tempURL)
    return data
}

/// Hands a URLSession transfer's end to the wait for it, in either order.
///
/// The transfer can end, for example when a cancel stops it, before the
/// wait's continuation is handed over. The end is then kept and resumes the
/// wait at once, so the wait never hangs. Only the first end counts.
final class SRAWindowTransferCompletion: Sendable {
    private struct State {
        var continuation: CheckedContinuation<URL, Error>?
        var result: Result<URL, Error>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Resumes `continuation` with the transfer's end, now if it has ended.
    func wait(_ continuation: CheckedContinuation<URL, Error>) {
        let ended: Result<URL, Error>? = state.withLock { state in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let ended {
            continuation.resume(with: ended)
        }
    }

    /// Records the transfer's end and resumes the wait if it is waiting.
    ///
    /// - Returns: Whether this was the first end. A later end is ignored.
    @discardableResult
    func finish(_ result: Result<URL, Error>) -> Bool {
        let (first, waiting) = state.withLock { state -> (Bool, CheckedContinuation<URL, Error>?) in
            guard state.result == nil else { return (false, nil) }
            state.result = result
            defer { state.continuation = nil }
            return (true, state.continuation)
        }
        waiting?.resume(with: result)
        return first
    }
}
