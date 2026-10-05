// SRAWindowRunDownload.swift - The window's download of one SRA run's FASTQ files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "DatabaseBrowser")

/// The FASTQ files the window's SRA download staged for one run, and where
/// they came from.
///
/// `DatabaseBrowserViewModel.startENADownloadTask` stages each run in its
/// own folder with `stage(accession:route:in:mirrorFile:toolkit:)`, which
/// downloads it with `download(accession:route:into:mirrorFile:toolkit:)`,
/// and then imports the files with `lungfish-cli import fastq`. Both take the
/// transfers as closures, so a test can drive them with a scripted mirror
/// and toolkit.
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

    /// Downloads one run's FASTQ files into `folder` along `route`.
    ///
    /// On the ENA route each file ENA lists is fetched with `mirrorFile` and
    /// checked with `ENAFASTQDownloadValidator`. When a file fails the check,
    /// a transfer breaks off or the mirror answers an HTTP error, the files
    /// staged so far are discarded and `toolkit` fetches the whole run with
    /// the SRA Toolkit, as `lungfish-cli fetch sra download` does. Both name
    /// the fallback with `SRAFASTQDownloadSource.toolkitFallback(after:)`. A
    /// cancellation stops the download instead.
    ///
    /// - Parameters:
    ///   - accession: The run accession.
    ///   - route: Where `ENAService.fastqDownloadRoute(forRun:)` sends the run.
    ///   - folder: The run's own staging folder, which the files are
    ///     written to.
    ///   - mirrorFile: Fetches one file from ENA's mirror, given its URL, the
    ///     size ENA lists for it, and the bytes the run's earlier files took.
    ///   - toolkit: Fetches the whole run with the SRA Toolkit, given the
    ///     status line the Operations panel row logs.
    static func download(
        accession: String,
        route: SRAFASTQDownloadRoute,
        into folder: URL,
        mirrorFile: (_ url: URL, _ expectedBytes: Int64?, _ priorBytes: Int64) async throws -> Data,
        toolkit: (_ statusDetail: String) async throws -> [URL]
    ) async throws -> SRAWindowRunDownload {
        let readRecord: ENAReadRecord
        switch route {
        case .enaMirror(let record):
            readRecord = record
        case .sraToolkit(_, let reason):
            let files = try await toolkit("\(reason); using SRA Toolkit...")
            return SRAWindowRunDownload(fastqFiles: files, source: .sraToolkit, enaSteps: [])
        }

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
            return SRAWindowRunDownload(fastqFiles: fastqFiles, source: .ena, enaSteps: enaSteps)
        } catch {
            guard let fallbackSource = SRAFASTQDownloadSource.toolkitFallback(after: error) else {
                throw error
            }
            // Discard the partial pair and fetch the run from NCBI via the
            // SRA Toolkit instead.
            logger.warning("startENADownloadTask: ENA download failed for \(accession, privacy: .public): \(error.localizedDescription, privacy: .public); falling back to SRA Toolkit")
            for stagedURL in fastqURLs {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(stagedURL.lastPathComponent))
            }
            let failure = fallbackSource == .sraToolkitAfterIncompleteMirror
                ? "ENA mirror is missing files" : "ENA transfer failed"
            let files = try await toolkit("\(failure) for \(accession); using SRA Toolkit...")
            return SRAWindowRunDownload(fastqFiles: files, source: fallbackSource, enaSteps: [])
        }
    }
}

/// The reads of one SRA run that the window imports, one file or both mates
/// of a pair.
///
/// ENA's mirror and the SRA Toolkit both name a run's files
/// `<accession>_1.fastq`, `<accession>_2.fastq` and `<accession>.fastq`,
/// gzipped when ENA serves them. Mates 1 and 2 import together as a pair.
/// The file without a suffix beside them holds the reads whose mate is
/// missing, and it stays out of the import. A run never imports as one mate
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

    /// The files `lungfish-cli import fastq` takes, mate 1 first.
    var files: [URL] { r2.map { [r1, $0] } ?? [r1] }

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
        let unpaired = try file("")
        switch (mate1, mate2) {
        case let (mate1?, mate2?):
            r1 = mate1
            r2 = mate2
        case (nil, .some):
            throw Failure(message: "Only mate 2 of \(accession) arrived, so it was not imported")
        case let (mate1?, nil):
            guard !listedAsPaired, unpaired == nil else {
                throw Failure(message: "Only mate 1 of the paired run \(accession) arrived, so it was not imported")
            }
            r1 = mate1
            r2 = nil
        case (nil, nil):
            guard let unpaired else {
                throw Failure(message: "No FASTQ file of \(accession) arrived")
            }
            r1 = unpaired
            r2 = nil
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

    /// Removes the run's folder and every file in it. The window calls it
    /// after the import and when the import fails, so no file of this run
    /// reaches the next one.
    func removeFolder() {
        try? FileManager.default.removeItem(at: folder)
    }
}

extension SRAWindowRunDownload {
    /// Downloads one run of a window batch into its own folder inside
    /// `batchDir` and sorts its files into the reads to import.
    ///
    /// A run that fails here leaves nothing behind, because its folder is
    /// removed. Once this returns, the caller removes the folder with
    /// `SRAWindowStagedRun.removeFolder()` after the import or on failure.
    ///
    /// - Parameters:
    ///   - mirrorFile: As for `download(accession:route:into:mirrorFile:toolkit:)`.
    ///   - toolkit: Fetches the whole run with the SRA Toolkit into the given
    ///     folder, given the status line the Operations panel row logs.
    static func stage(
        accession: String,
        route: SRAFASTQDownloadRoute,
        in batchDir: URL,
        mirrorFile: (_ url: URL, _ expectedBytes: Int64?, _ priorBytes: Int64) async throws -> Data,
        toolkit: (_ statusDetail: String, _ folder: URL) async throws -> [URL]
    ) async throws -> SRAWindowStagedRun {
        let folder = batchDir.appendingPathComponent(accession, isDirectory: true)
        // A folder left by an earlier copy of this run in the batch is stale.
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let download = try await download(
                accession: accession,
                route: route,
                into: folder,
                mirrorFile: mirrorFile,
                toolkit: { try await toolkit($0, folder) }
            )
            let reads = try SRAWindowRunReads(
                stagedFiles: download.fastqFiles,
                accession: accession,
                listedAsPaired: route.enaRecord?.isPaired == true
            )
            return SRAWindowStagedRun(folder: folder, download: download, reads: reads)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
