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
/// `DatabaseBrowserViewModel.startENADownloadTask` downloads each run with
/// `download(accession:route:into:mirrorFile:toolkit:)` and then imports the
/// files with `lungfish-cli import fastq`. The function takes the transfers
/// as closures, so a test can drive it with a scripted mirror and toolkit.
struct SRAWindowRunDownload {
    /// The staged FASTQ files, one per mate.
    var fastqFiles: [URL]
    /// What the run's provenance and FASTQ metadata record under
    /// `downloadSource`.
    var source: SRAFASTQDownloadSource
    /// One HTTPS transfer step for each file ENA's mirror served. Empty when
    /// the SRA Toolkit fetched the run.
    var enaSteps: [StepExecution]

    /// Downloads one run's FASTQ files into `batchDir` along `route`.
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
    ///   - batchDir: The staging folder the files are written to.
    ///   - mirrorFile: Fetches one file from ENA's mirror, given its URL, the
    ///     size ENA lists for it, and the bytes the run's earlier files took.
    ///   - toolkit: Fetches the whole run with the SRA Toolkit, given the
    ///     status line the Operations panel row logs.
    static func download(
        accession: String,
        route: SRAFASTQDownloadRoute,
        into batchDir: URL,
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
                let localPath = batchDir.appendingPathComponent(filename)
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
                try? FileManager.default.removeItem(at: batchDir.appendingPathComponent(stagedURL.lastPathComponent))
            }
            let failure = fallbackSource == .sraToolkitAfterIncompleteMirror
                ? "ENA mirror is missing files" : "ENA transfer failed"
            let files = try await toolkit("\(failure) for \(accession); using SRA Toolkit...")
            return SRAWindowRunDownload(fastqFiles: files, source: fallbackSource, enaSteps: [])
        }
    }
}
