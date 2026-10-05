// SRAWindowRunDownload.swift - The window's download of one SRA run's FASTQ files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "DatabaseBrowser")

/// A line the window's Operations panel row logs when the SRA Toolkit
/// fetches a run.
struct SRAWindowToolkitStatus: Equatable, Sendable {
    let line: String
    /// True when the toolkit runs because ENA could not serve the run, false
    /// when it is the route the user chose with Prefer NCBI.
    let isFallback: Bool

    /// A fallback is a warning, the chosen route is information.
    var level: OperationLogLevel { isFallback ? .warning : .info }
}

/// The FASTQ files the window's SRA download staged for one run, and where
/// they came from.
///
/// `DatabaseBrowserViewModel.startENADownloadTask` stages each run in its
/// own folder with `stage(accession:preference:ncbiRun:in:lookUpRoute:mirrorFile:toolkit:log:)`,
/// which downloads it with `download(accession:preference:lookUpRoute:into:mirrorFile:toolkit:log:)`,
/// and then imports the files with `lungfish-cli import fastq`. Both take the
/// ENA lookup and the transfers as closures, so a test can drive them with a
/// scripted portal, mirror and toolkit.
struct SRAWindowRunDownload {
    /// The staged FASTQ files, as ENA lists them or the SRA Toolkit wrote
    /// them.
    var fastqFiles: [URL]
    /// What the run's provenance and FASTQ metadata record under
    /// `downloadSource`.
    var source: SRAFASTQDownloadSource
    /// One HTTPS transfer step for each file ENA's mirror served. Empty when
    /// the SRA Toolkit fetched the run.
    var enaSteps: [StepExecution]
    /// The window's "Download source" setting the run was downloaded with,
    /// which its provenance records under `preferredSource`.
    var preference: SRADownloadSourcePreference = .ena
    /// ENA's record of the run, which the bundle's metadata keeps. Nil when
    /// ENA has no record of it or did not answer in time.
    var enaRecord: ENAReadRecord?
    /// Why `enaRecord` is nil, for the Operations panel row.
    var enaRecordGap: String?
    /// The line the row logged when the run fell back to the other archive,
    /// which its provenance records under `fallbackMessage`. Nil when the
    /// preferred archive served the run.
    var fallbackMessage: String? = nil

    /// How long a toolkit download that already finished waits for ENA's
    /// record of the run before it imports without it.
    static let enaRecordWait: Duration = .seconds(15)

    /// Downloads one run's FASTQ files into `folder` along `route`, as
    /// `download(accession:preference:lookUpRoute:into:mirrorFile:toolkit:log:)`
    /// does with a lookup that already answered.
    static func download(
        accession: String,
        route: SRAFASTQDownloadRoute,
        preference: SRADownloadSourcePreference = .ena,
        into folder: URL,
        mirrorFile: (_ url: URL, _ expectedBytes: Int64?, _ priorBytes: Int64) async throws -> Data,
        toolkit: (_ status: SRAWindowToolkitStatus) async throws -> [URL],
        log: (_ line: String) -> Void = { _ in }
    ) async throws -> SRAWindowRunDownload {
        try await download(
            accession: accession, preference: preference, lookUpRoute: { route },
            into: folder, mirrorFile: mirrorFile, toolkit: toolkit, log: log
        )
    }

    /// Downloads one run's FASTQ files into `folder`.
    ///
    /// With `.ena` the run is looked up with `lookUpRoute` first. On ENA's
    /// route each file ENA lists is fetched with `mirrorFile` and checked
    /// with `ENAFASTQDownloadValidator`. When a file fails the check, a
    /// transfer breaks off or the mirror answers an HTTP error, the files
    /// staged so far are discarded and `toolkit` fetches the whole run with
    /// the SRA Toolkit, as `lungfish-cli fetch sra download` does. Both name
    /// the fallback with `SRAFASTQDownloadSource.toolkitFallback(after:)`.
    ///
    /// With `.ncbi` the toolkit starts at once and the ENA lookup runs beside
    /// it, so a slow ENA never holds the toolkit up. When the toolkit fails,
    /// the download waits for the lookup and ENA's mirror serves the run. When
    /// the toolkit succeeds, the lookup has `enaRecordWait` more to deliver
    /// ENA's record for the bundle's metadata. A cancellation stops the
    /// download in either case.
    ///
    /// - Parameters:
    ///   - lookUpRoute: `ENAService.fastqDownloadRoute(forRun:)` for the run.
    ///   - folder: The run's own staging folder, which the files are
    ///     written to.
    ///   - mirrorFile: Fetches one file from ENA's mirror, given its URL, the
    ///     size ENA lists for it, and the bytes the run's earlier files took.
    ///   - toolkit: Fetches the whole run with the SRA Toolkit, given the
    ///     status line the Operations panel row logs.
    static func download(
        accession: String,
        preference: SRADownloadSourcePreference,
        lookUpRoute: @escaping @Sendable () async throws -> SRAFASTQDownloadRoute,
        enaRecordWait: Duration = SRAWindowRunDownload.enaRecordWait,
        into folder: URL,
        mirrorFile: (_ url: URL, _ expectedBytes: Int64?, _ priorBytes: Int64) async throws -> Data,
        toolkit: (_ status: SRAWindowToolkitStatus) async throws -> [URL],
        log: (_ line: String) -> Void = { _ in }
    ) async throws -> SRAWindowRunDownload {
        if preference == .ncbi {
            return try await downloadPreferringToolkit(
                accession: accession, lookUpRoute: lookUpRoute, enaRecordWait: enaRecordWait,
                into: folder, mirrorFile: mirrorFile, toolkit: toolkit, log: log
            )
        }
        let route = try await lookUpRoute()
        let readRecord: ENAReadRecord
        switch route {
        case .enaMirror(let record):
            readRecord = record
        case .sraToolkit(let record, let reason):
            let line = "\(reason); using SRA Toolkit..."
            let files = try await toolkit(SRAWindowToolkitStatus(line: line, isFallback: true))
            return SRAWindowRunDownload(
                fastqFiles: files, source: .sraToolkit, enaSteps: [], preference: preference, enaRecord: record, fallbackMessage: line
            )
        }

        do {
            let mirrored = try await downloadFromMirror(record: readRecord, into: folder, mirrorFile: mirrorFile)
            return SRAWindowRunDownload(
                fastqFiles: mirrored.files, source: .ena, enaSteps: mirrored.steps, preference: preference, enaRecord: readRecord
            )
        } catch {
            guard let fallbackSource = SRAFASTQDownloadSource.toolkitFallback(after: error) else {
                throw error
            }
            // Fetch the run from NCBI via the SRA Toolkit instead.
            logger.warning("startENADownloadTask: ENA download failed for \(accession, privacy: .public): \(error.localizedDescription, privacy: .public); falling back to SRA Toolkit")
            let failure = fallbackSource == .sraToolkitAfterIncompleteMirror
                ? "ENA mirror is missing files" : "ENA transfer failed"
            let line = "\(failure) for \(accession); using SRA Toolkit..."
            let files = try await toolkit(SRAWindowToolkitStatus(line: line, isFallback: true))
            return SRAWindowRunDownload(
                fastqFiles: files, source: fallbackSource, enaSteps: [], preference: preference, enaRecord: readRecord,
                fallbackMessage: line
            )
        }
    }

    /// Fetches the run with the SRA Toolkit first, as "Prefer NCBI" asks,
    /// while `lookUpRoute` asks ENA about the run beside it. When the toolkit
    /// is not installed or fails, everything it left in the run's folder is
    /// removed, `log` gets the reason, and ENA's mirror serves the files ENA
    /// lists. A cancellation stops the download.
    private static func downloadPreferringToolkit(
        accession: String,
        lookUpRoute: @escaping @Sendable () async throws -> SRAFASTQDownloadRoute,
        enaRecordWait: Duration,
        into folder: URL,
        mirrorFile: (_ url: URL, _ expectedBytes: Int64?, _ priorBytes: Int64) async throws -> Data,
        toolkit: (_ status: SRAWindowToolkitStatus) async throws -> [URL],
        log: (_ line: String) -> Void
    ) async throws -> SRAWindowRunDownload {
        let lookup = Task { try await lookUpRoute() }
        let files: [URL]
        do {
            files = try await toolkit(SRAWindowToolkitStatus(
                line: "Fetching \(accession) from NCBI with the SRA Toolkit (Prefer NCBI)...", isFallback: false
            ))
        } catch let toolkitError {
            guard let source = SRAFASTQDownloadSource.enaFallback(afterToolkitError: toolkitError) else {
                lookup.cancel()
                throw toolkitError
            }
            // The folder holds only this run, so nothing the toolkit wrote
            // can reach the import beside ENA's files.
            for entry in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: entry)
            }
            func bothFailed(_ enaError: any Error) -> SRAError {
                bothFailed(reason: (enaError as? ENAFASTQDownloadFailure)?.message ?? enaError.localizedDescription)
            }
            func bothFailed(reason enaReason: String) -> SRAError {
                SRAError.downloadFailed("Toolkit: \(toolkitError.localizedDescription); ENA: \(enaReason)")
            }
            // Logged before the wait on ENA's lookup, so the row is not silent.
            let fallbackLine = SRAFASTQDownloadSource.enaFallbackMessage(accession: accession, after: toolkitError)
            log(fallbackLine)
            let route: SRAFASTQDownloadRoute
            do {
                route = try await value(of: lookup)
            } catch let lookupError {
                if SRAFASTQDownloadSource.toolkitFallback(after: lookupError) == nil { throw lookupError }
                throw bothFailed(lookupError)
            }
            try Task.checkCancellation()
            guard case .enaMirror(let record) = route else {
                throw bothFailed(reason: route.toolkitReason ?? "ENA lists no FASTQ files for \(accession)")
            }
            do {
                let mirrored = try await downloadFromMirror(record: record, into: folder, mirrorFile: mirrorFile)
                return SRAWindowRunDownload(
                    fastqFiles: mirrored.files, source: source, enaSteps: mirrored.steps, preference: .ncbi, enaRecord: record,
                    fallbackMessage: fallbackLine
                )
            } catch let enaError {
                if SRAFASTQDownloadSource.toolkitFallback(after: enaError) == nil {
                    throw enaError
                }
                throw bothFailed(enaError)
            }
        }
        let answer = await enaRecord(from: lookup, within: enaRecordWait)
        // A cancel during the wait is not ENA failing to answer, so the run
        // stops here and nothing is imported.
        try Task.checkCancellation()
        return SRAWindowRunDownload(
            fastqFiles: files, source: .sraToolkit, enaSteps: [], preference: .ncbi,
            enaRecord: answer.record, enaRecordGap: answer.gap
        )
    }

    /// The lookup's answer. Awaiting an unstructured task does not pass a
    /// cancel on, so this cancels `lookup` when the waiting task is cancelled.
    private static func value(of lookup: Task<SRAFASTQDownloadRoute, any Error>) async throws -> SRAFASTQDownloadRoute {
        try await withTaskCancellationHandler {
            try await lookup.value
        } onCancel: {
            lookup.cancel()
        }
    }

    /// ENA's record from `lookup`, or why there is none. A lookup still
    /// running after `wait` is cancelled, so a slow ENA delays the import by
    /// `wait` at most.
    private static func enaRecord(
        from lookup: Task<SRAFASTQDownloadRoute, any Error>,
        within wait: Duration
    ) async -> (record: ENAReadRecord?, gap: String?) {
        let first = await withTaskGroup(of: Result<SRAFASTQDownloadRoute, any Error>?.self) { group in
            group.addTask {
                do { return .success(try await value(of: lookup)) } catch { return .failure(error) }
            }
            group.addTask {
                try? await Task.sleep(for: wait)
                return nil
            }
            let first = await group.next() ?? nil
            // Awaiting a task's value does not cancel it, so the lookup
            // itself is cancelled for the group to finish.
            if first == nil { lookup.cancel() }
            group.cancelAll()
            return first
        }
        switch first {
        case nil:
            return (nil, "ENA did not answer within \(wait.components.seconds) s")
        case .failure(let error)?:
            return (nil, error.localizedDescription)
        case .success(let route)?:
            return (route.enaRecord, route.enaRecord == nil ? route.toolkitReason : nil)
        }
    }

    /// Fetches every file ENA lists for the run from ENA's mirror with
    /// `mirrorFile`, checking each with `ENAFASTQDownloadValidator`. On any
    /// failure the files staged so far are removed and the error rethrown.
    private static func downloadFromMirror(
        record readRecord: ENAReadRecord,
        into folder: URL,
        mirrorFile: (_ url: URL, _ expectedBytes: Int64?, _ priorBytes: Int64) async throws -> Data
    ) async throws -> (files: [URL], steps: [StepExecution]) {
        let fastqURLs = readRecord.fastqHTTPURLs
        let perFileSizes = ENAFASTQDownloadValidator.expectedByteCounts(for: readRecord)
        var fastqFiles: [URL] = []
        var enaSteps: [StepExecution] = []
        var priorBytesDownloaded: Int64 = 0

        do {
            for (fileIdx, fastqURL) in fastqURLs.enumerated() {
                let filename = fastqURL.lastPathComponent
                let localPath = folder.appendingPathComponent(filename)
                let fileExpectedBytes = fileIdx < perFileSizes.count ? perFileSizes[fileIdx] : nil

                logger.info("startENADownloadTask: Downloading \(fastqURL.absoluteString, privacy: .public)")

                let downloadStartedAt = Date()
                let data = try await mirrorFile(fastqURL, fileExpectedBytes, priorBytesDownloaded)

                try data.write(to: localPath)
                // ENA's mirror answers a missing mate with a 200 HTML
                // directory listing. Catch it here rather than in fastp.
                try ENAFASTQDownloadValidator.validate(
                    fileURL: localPath,
                    expectedBytes: fileExpectedBytes
                )
                let downloadCompletedAt = Date()
                enaSteps.append(
                    StepExecution(
                        toolName: "https-download",
                        toolVersion: "URLSession",
                        command: [
                            "curl",
                            "-L",
                            "--fail",
                            "--user-agent", "Lungfish Genome Explorer",
                            fastqURL.absoluteString,
                            "-o", localPath.path
                        ],
                        inputs: [
                            FileRecord(
                                path: fastqURL.absoluteString,
                                format: .fastq,
                                role: .input
                            )
                        ],
                        outputs: [
                            ProvenanceRecorder.fileRecord(url: localPath, format: .fastq, role: .output)
                        ],
                        exitCode: 0,
                        wallTime: downloadCompletedAt.timeIntervalSince(downloadStartedAt),
                        stderr: nil,
                        startTime: downloadStartedAt,
                        endTime: downloadCompletedAt
                    )
                )
                logger.info("startENADownloadTask: Saved \(filename) (\(data.count) bytes)")
                fastqFiles.append(localPath)
                priorBytesDownloaded += fileExpectedBytes ?? Int64(data.count)
            }
            return (fastqFiles, enaSteps)
        } catch {
            // Discard the partial pair.
            for stagedURL in fastqURLs {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(stagedURL.lastPathComponent))
            }
            throw error
        }
    }
}

/// The reads of one SRA run that the window imports, one file, or both mates
/// of a pair with the reads whose mate is missing when the run has any.
///
/// ENA's mirror and the SRA Toolkit both name a run's files
/// `<accession>_1.fastq`, `<accession>_2.fastq` and `<accession>.fastq`,
/// gzipped when ENA serves them. Mates 1 and 2 import together as a pair.
/// The file without a suffix beside them holds the reads whose mate is
/// missing, and it imports with the pair as the run's unpaired reads, so
/// the bundle holds every read of the run. A run never imports as one mate
/// of a pair, so a lone mate 2 fails, and so does a lone mate 1 of a run ENA
/// lists as paired. Files named for another run never import.
struct SRAWindowRunReads: Equatable {
    /// Why a run's staged files hold no reads the window can import.
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Mate 1, or the run's only file.
    let r1: URL
    /// Mate 2, or nil for single reads.
    let r2: URL?
    /// The reads beside a pair whose mate is missing, or nil.
    let unpaired: URL?

    /// The files `lungfish-cli import fastq` takes, mate 1, mate 2, then
    /// the unpaired reads.
    var files: [URL] { [r1] + [r2, unpaired].compactMap { $0 } }

    /// The reads each file held, read from the bundle's classification, for
    /// a run that imported unpaired reads beside its pairs. Nil for any other
    /// run, so its record keeps the parameters it had.
    func readCounts(in classification: ReadClassification?) -> [URL: Int]? {
        guard let r2, let unpaired, let classification else { return nil }
        func reads(_ role: ReadClassification.FileRole) -> Int {
            classification.files.filter { $0.role == role }.reduce(0) { $0 + $1.readCount }
        }
        return [r1: reads(.pairedR1), r2: reads(.pairedR2), unpaired: reads(.unpaired)]
    }

    /// Sorts one run's staged files into the reads to import.
    ///
    /// - Parameter listedAsPaired: Whether ENA's record lists the run's
    ///   layout as PAIRED.
    /// - Throws: `Failure` when the files hold one mate of a pair, two copies
    ///   of one file, or no file of this run.
    init(stagedFiles: [URL], accession: String, listedAsPaired: Bool) throws {
        func file(_ suffix: String) throws -> URL? {
            let names: Set = ["\(accession)\(suffix).fastq", "\(accession)\(suffix).fastq.gz"]
            let matches = stagedFiles.filter { names.contains($0.lastPathComponent) }
            guard matches.count < 2 else {
                throw Failure(message: "\(accession) arrived as both \(matches[0].lastPathComponent) and \(matches[1].lastPathComponent), so it was not imported")
            }
            return matches.first
        }
        let mate1 = try file("_1")
        let mate2 = try file("_2")
        let unsuffixed = try file("")
        switch (mate1, mate2) {
        case let (mate1?, mate2?):
            r1 = mate1
            r2 = mate2
            unpaired = unsuffixed
        case (nil, .some):
            throw Failure(message: "Only mate 2 of \(accession) arrived, so it was not imported")
        case let (mate1?, nil):
            guard !listedAsPaired, unsuffixed == nil else {
                throw Failure(message: "Only mate 1 of the paired run \(accession) arrived, so it was not imported")
            }
            r1 = mate1
            r2 = nil
            unpaired = nil
        case (nil, nil):
            guard let unsuffixed else {
                throw Failure(message: "No FASTQ file of \(accession) arrived")
            }
            r1 = unsuffixed
            r2 = nil
            unpaired = nil
        }
    }
}

/// One run of a window batch, downloaded into its own staging folder.
struct SRAWindowStagedRun {
    /// The run's folder inside the batch folder. It holds only this run's
    /// files.
    let folder: URL
    let download: SRAWindowRunDownload
    /// The files the window imports.
    let reads: SRAWindowRunReads
    /// NCBI's run info from the window's search, which the bundle's metadata
    /// keeps beside ENA's record.
    var ncbiRun: SRARunInfo? = nil
    /// The line the row and the provenance log when the run arrived in a
    /// layout its archive record does not list, or nil.
    var layoutWarning: String? = nil

    /// Removes the run's folder and every file in it. The window calls it
    /// after the import and when the import fails, so no file of this run
    /// reaches the next one.
    func removeFolder() {
        try? FileManager.default.removeItem(at: folder)
    }
}

extension SRAWindowRunDownload {
    /// Stages one run along a route that is already known, as
    /// `stage(accession:preference:ncbiRun:in:lookUpRoute:mirrorFile:toolkit:log:)`
    /// does with a lookup that already answered.
    static func stage(
        accession: String,
        route: SRAFASTQDownloadRoute,
        preference: SRADownloadSourcePreference = .ena,
        in batchDir: URL,
        mirrorFile: (_ url: URL, _ expectedBytes: Int64?, _ priorBytes: Int64) async throws -> Data,
        toolkit: (_ status: SRAWindowToolkitStatus, _ folder: URL) async throws -> [URL],
        log: (_ line: String) -> Void = { _ in }
    ) async throws -> SRAWindowStagedRun {
        try await stage(
            accession: accession, preference: preference, in: batchDir, lookUpRoute: { route },
            mirrorFile: mirrorFile, toolkit: toolkit, log: log
        )
    }

    /// Downloads one run of a window batch into its own folder inside
    /// `batchDir` and sorts its files into the reads to import.
    ///
    /// A run that fails here leaves nothing behind, because its folder is
    /// removed. Once this returns, the caller removes the folder with
    /// `SRAWindowStagedRun.removeFolder()` after the import or on failure.
    ///
    /// ENA's record lists the run's layout. When it did not arrive, NCBI's
    /// `ncbiRun` from the search gives the metadata, and `log` says so. A run
    /// NCBI lists as paired that arrived as one file imports as single-end
    /// reads with `SRAWindowStagedRun.layoutWarning` naming the mismatch.
    ///
    /// - Parameters:
    ///   - lookUpRoute: As for `download(accession:preference:lookUpRoute:into:mirrorFile:toolkit:log:)`.
    ///   - mirrorFile: As for `download(accession:preference:lookUpRoute:into:mirrorFile:toolkit:log:)`.
    ///   - toolkit: Fetches the whole run with the SRA Toolkit into the given
    ///     folder, given the status line the Operations panel row logs.
    static func stage(
        accession: String,
        preference: SRADownloadSourcePreference,
        ncbiRun: SRARunInfo? = nil,
        in batchDir: URL,
        lookUpRoute: @escaping @Sendable () async throws -> SRAFASTQDownloadRoute,
        enaRecordWait: Duration = SRAWindowRunDownload.enaRecordWait,
        mirrorFile: (_ url: URL, _ expectedBytes: Int64?, _ priorBytes: Int64) async throws -> Data,
        toolkit: (_ status: SRAWindowToolkitStatus, _ folder: URL) async throws -> [URL],
        log: (_ line: String) -> Void = { _ in }
    ) async throws -> SRAWindowStagedRun {
        let folder = batchDir.appendingPathComponent(accession, isDirectory: true)
        // A folder left by an earlier copy of this run in the batch is stale.
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let download = try await download(
                accession: accession,
                preference: preference,
                lookUpRoute: lookUpRoute,
                enaRecordWait: enaRecordWait,
                into: folder,
                mirrorFile: mirrorFile,
                toolkit: { try await toolkit($0, folder) },
                log: log
            )
            if download.enaRecord == nil, let gap = download.enaRecordGap {
                log(ncbiRun == nil
                    ? "ENA's record of \(accession) is missing (\(gap)), so the run is imported without ENA metadata."
                    : "ENA's record of \(accession) is missing (\(gap)), so NCBI's record gives the run's metadata.")
            }
            // Only ENA's record refuses a lone mate 1. NCBI's layout names the
            // mismatch but keeps the earlier outcome, single-end reads, until
            // sub-phase 2.1 decides whether to refuse such runs.
            let reads = try SRAWindowRunReads(
                stagedFiles: download.fastqFiles,
                accession: accession,
                listedAsPaired: download.enaRecord?.isPaired == true
            )
            var layoutWarning: String?
            if download.enaRecord == nil, reads.r2 == nil, ncbiRun?.libraryLayout?.uppercased() == "PAIRED" {
                let line = "NCBI lists \(accession) as paired but only one read file arrived; imported as single-end reads"
                log(line)
                layoutWarning = line
            }
            return SRAWindowStagedRun(
                folder: folder, download: download, reads: reads, ncbiRun: ncbiRun, layoutWarning: layoutWarning
            )
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
