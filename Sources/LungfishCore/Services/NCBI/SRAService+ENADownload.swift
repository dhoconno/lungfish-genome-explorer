// SRAService+ENADownload.swift - Download an SRA run's FASTQ files from ENA, with the SRA Toolkit as the fallback
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.core, category: "SRAService")

extension SRAService {
    /// Downloads FASTQ via ENA (alternative to SRA Toolkit).
    ///
    /// This method downloads directly from ENA's FTP/HTTP servers,
    /// which doesn't require the SRA Toolkit. It downloads only the files
    /// ENA's portal lists, and throws when ENA fails or lists none, which
    /// sends `downloadFASTQWithFallback` to the SRA Toolkit.
    ///
    /// - Parameters:
    ///   - accession: SRA/ENA run accession
    ///   - outputDir: Output directory
    ///   - progress: Progress callback
    /// - Returns: URLs to downloaded files
    /// - Throws: `ENAFASTQDownloadFailure`, which names the fallback's source, or a cancellation.
    public func downloadFASTQFromENA(
        accession: String,
        outputDir: URL? = nil,
        progress: (@Sendable (Double) -> Void)? = nil,
        trace: DownloadTraceHandler? = nil
    ) async throws -> [URL] {
        let outputDirectory = outputDir ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("sra_downloads")

        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        // ENA's portal lists the run's FASTQ files and their sizes, which fix
        // the run's layout. When ENA fails or lists none, the run takes the SRA
        // Toolkit route that `ENAService.fastqDownloadRoute(forRun:)` names for
        // the window's download too. Paths guessed on ENA's mirror carry no
        // sizes, so a mirror missing one mate could hand over half a pair.
        let route = try await ENAService(httpClient: httpClient).fastqDownloadRoute(forRun: accession)
        guard case .enaMirror(let record) = route else {
            throw ENAFASTQDownloadFailure(
                fallbackSource: .sraToolkit,
                message: route.toolkitReason ?? "ENA lists no FASTQ files for \(accession)"
            )
        }
        let candidateURLs = record.fastqHTTPURLs
        // Per-file sizes advertised by the portal, aligned with candidateURLs.
        let expectedByteCounts = ENAFASTQDownloadValidator.expectedByteCounts(for: record)
        logger.info("Resolved \(candidateURLs.count, privacy: .public) FASTQ URL(s) for \(accession, privacy: .public) via ENA portal")

        var downloadedFiles: [URL] = []
        var attemptedURLs: [String] = []
        var rejectionReasons: [String] = []
        // How the first file that did not arrive failed, which names the fallback.
        var firstFailure: SRAFASTQDownloadSource?
        let totalCandidates = max(candidateURLs.count, 1)
        for (index, fileURL) in candidateURLs.enumerated() {
            try Task.checkCancellation()
            let filename = fileURL.lastPathComponent.isEmpty
                ? "\(accession)_\(index + 1).fastq.gz"
                : fileURL.lastPathComponent
            let localPath = outputDirectory.appendingPathComponent(filename)
            attemptedURLs.append(fileURL.absoluteString)
            let expectedBytes = index < expectedByteCounts.count ? expectedByteCounts[index] : nil

            do {
                logger.info("Attempting to download from ENA: \(fileURL.absoluteString, privacy: .public)")

                var request = URLRequest(url: fileURL)
                request.setValue("Lungfish Genome Explorer", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 600

                let downloadStartedAt = Date()
                let (temporaryURL, response) = try await httpClient.download(for: request)
                let downloadCompletedAt = Date()
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    try? FileManager.default.removeItem(at: temporaryURL)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    rejectionReasons.append("\(filename): HTTP \(code)")
                    firstFailure = firstFailure ?? .sraToolkitAfterFailedTransfer
                    continue
                }

                try Self.publishDownloadedFile(from: temporaryURL, to: localPath)

                // ENA's mirror answers a missing mate file with a 200 HTML
                // directory listing. Reject anything that is not the gzip file
                // the portal advertised before it can reach fastp.
                do {
                    try ENAFASTQDownloadValidator.validate(fileURL: localPath, expectedBytes: expectedBytes)
                } catch let failure as ENAFASTQDownloadValidator.Failure {
                    try? FileManager.default.removeItem(at: localPath)
                    rejectionReasons.append(failure.localizedDescription)
                    firstFailure = firstFailure ?? .sraToolkitAfterIncompleteMirror
                    logger.warning("ENA FASTQ download rejected for \(fileURL.absoluteString, privacy: .public): \(failure.localizedDescription, privacy: .public)")
                    continue
                }

                downloadedFiles.append(localPath)
                trace?(
                    FASTQDownloadStepTrace(
                        toolName: "https-download",
                        toolVersion: "URLSession",
                        command: [
                            "curl",
                            "-L",
                            "--fail",
                            "--user-agent", "Lungfish Genome Explorer",
                            fileURL.absoluteString,
                            "-o", localPath.path,
                        ],
                        inputs: [fileURL.absoluteString],
                        outputs: [localPath],
                        exitCode: 0,
                        wallTime: downloadCompletedAt.timeIntervalSince(downloadStartedAt),
                        stderr: nil,
                        startedAt: downloadStartedAt,
                        completedAt: downloadCompletedAt
                    )
                )
                progress?(Double(index + 1) / Double(totalCandidates))

                logger.info("Downloaded: \(localPath.lastPathComponent, privacy: .public)")
            } catch {
                guard let source = SRAFASTQDownloadSource.toolkitFallback(after: error) else {
                    throw error
                }
                firstFailure = firstFailure ?? source
                logger.warning("ENA FASTQ download failed for \(fileURL.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
        }

        if downloadedFiles.isEmpty {
            let attemptedPreview = attemptedURLs.prefix(3).joined(separator: ", ")
            let reasonSuffix = rejectionReasons.isEmpty ? "" : " \(rejectionReasons.joined(separator: "; "))"
            throw ENAFASTQDownloadFailure(
                fallbackSource: firstFailure ?? .sraToolkitAfterFailedTransfer,
                message: "Could not download FASTQ files from ENA for \(accession). Attempted URLs: \(attemptedPreview).\(reasonSuffix)"
            )
        }

        // Portal URLs are authoritative: a PAIRED run that yields one mate is a
        // failed download, not a single-end run. Leave nothing behind so the
        // toolkit fallback starts from a clean directory.
        if downloadedFiles.count < candidateURLs.count {
            for file in downloadedFiles {
                try? FileManager.default.removeItem(at: file)
            }
            throw ENAFASTQDownloadFailure(
                fallbackSource: firstFailure ?? .sraToolkitAfterFailedTransfer,
                message: "ENA served \(downloadedFiles.count) of \(candidateURLs.count) advertised FASTQ file(s) for \(accession). \(rejectionReasons.joined(separator: "; "))"
            )
        }

        progress?(1.0)

        return downloadedFiles
    }

    /// Downloads FASTQ via ENA first, and automatically retries via the SRA Toolkit when ENA fails.
    ///
    /// If both paths fail, the combined error message from each attempt is surfaced as
    /// `SRAError.downloadFailed`. Tests inject the `enaDownloader` / `toolkitDownloader`
    /// closures via the dedicated initializer; in production both default to the real
    /// `downloadFASTQFromENA` and `downloadFASTQ` methods.
    ///
    /// - Parameters:
    ///   - accession: SRA/ENA run accession.
    ///   - outputDir: Output directory (defaults to a temp folder when nil).
    ///   - progress: Optional progress callback (0.0–1.0).
    ///   - onFallback: Optional callback invoked exactly once when the ENA path
    ///     throws and the toolkit retry is about to start. Receives a
    ///     human-readable message suitable for display in CLI output or an
    ///     operation row note.
    ///   - onSource: Optional callback invoked once with where the files came
    ///     from, which `fetch sra download` records under `downloadSource`.
    /// - Returns: URLs to downloaded FASTQ files.
    public func downloadFASTQWithFallback(
        accession: String,
        outputDir: URL?,
        progress: (@Sendable (Double) -> Void)? = nil,
        onFallback: (@Sendable (String) -> Void)? = nil,
        onSource: (@Sendable (SRAFASTQDownloadSource) -> Void)? = nil,
        trace: DownloadTraceHandler? = nil
    ) async throws -> [URL] {
        let ena: DownloadStrategy = enaDownloader ?? { acc, dir in
            try await self.downloadFASTQFromENA(accession: acc, outputDir: dir, progress: progress, trace: trace)
        }
        let toolkit: DownloadStrategy = toolkitDownloader ?? { acc, dir in
            try await self.downloadFASTQ(accession: acc, outputDir: dir, progress: progress, trace: trace)
        }
        do {
            let enaFiles = try await ena(accession, outputDir)
            onSource?(.ena)
            return enaFiles
        } catch let enaError {
            // A cancellation stops the download. Any other ENA failure sends
            // the run to the SRA Toolkit, as the window's download does.
            guard let source = SRAFASTQDownloadSource.toolkitFallback(after: enaError) else {
                throw enaError
            }
            onFallback?(SRAFASTQDownloadSource.toolkitFallbackMessage(accession: accession, after: enaError))
            do {
                let toolkitFiles = try await toolkit(accession, outputDir)
                onSource?(source)
                return toolkitFiles
            } catch let toolkitError {
                if Self.isCancellation(toolkitError) {
                    throw toolkitError
                }
                throw SRAError.downloadFailed("ENA: \(enaError.localizedDescription); Toolkit: \(toolkitError.localizedDescription)")
            }
        }
    }

    private static func publishDownloadedFile(from temporaryURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }
}
