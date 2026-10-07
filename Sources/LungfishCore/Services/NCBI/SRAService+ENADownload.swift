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
    /// The files are staged in a hidden folder inside `outputDir` and each
    /// is checked against the size and MD5 the portal lists. They reach
    /// `outputDir` only once every listed file arrived whole, so a file of
    /// the same name already there is replaced only by a complete run. The
    /// first file that fails stops the download with a one-line reason, and
    /// a failure or a cancellation removes the staged files, so no lone
    /// mate is ever left behind.
    ///
    /// - Parameters:
    ///   - accession: SRA/ENA run accession
    ///   - outputDir: Output directory
    ///   - progress: Progress callback
    ///   - onRecord: Called once with ENA's record of the run when ENA
    ///     answered with one, even when the run then takes the SRA Toolkit
    ///     route.
    /// - Returns: URLs to downloaded files
    /// - Throws: `ENAFASTQDownloadFailure`, which names the fallback's source, or a cancellation.
    public func downloadFASTQFromENA(
        accession: String,
        outputDir: URL? = nil,
        progress: (@Sendable (Double) -> Void)? = nil,
        onRecord: (@Sendable (ENAReadRecord) -> Void)? = nil,
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
        if let record = route.enaRecord {
            onRecord?(record)
        }
        guard case .enaMirror(let record) = route else {
            throw ENAFASTQDownloadFailure(
                fallbackSource: .sraToolkit,
                message: route.toolkitReason ?? "ENA lists no FASTQ files for \(accession)"
            )
        }
        let candidateURLs = record.fastqHTTPURLs
        // Per-file sizes and checksums listed by the portal, aligned with candidateURLs.
        let expectedByteCounts = ENAFASTQDownloadValidator.expectedByteCounts(for: record)
        let expectedMD5s = ENAFASTQDownloadValidator.expectedMD5s(for: record)
        logger.info("Resolved \(candidateURLs.count, privacy: .public) FASTQ URL(s) for \(accession, privacy: .public) via ENA portal")

        let staging = outputDirectory.appendingPathComponent(".lungfish-ena-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        // Removed on success, failure and cancellation alike. Only a killed
        // process leaves it, hidden, and never as a file named for the run.
        defer { try? FileManager.default.removeItem(at: staging) }

        var stagedFiles: [(staged: URL, published: URL)] = []
        let totalCandidates = max(candidateURLs.count, 1)
        for (index, fileURL) in candidateURLs.enumerated() {
            try Task.checkCancellation()
            let filename = fileURL.lastPathComponent.isEmpty
                ? "\(accession)_\(index + 1).fastq.gz"
                : fileURL.lastPathComponent
            let stagedPath = staging.appendingPathComponent(filename)
            let publishedPath = outputDirectory.appendingPathComponent(filename)
            let expectedBytes = index < expectedByteCounts.count ? expectedByteCounts[index] : nil
            let expectedMD5 = index < expectedMD5s.count ? expectedMD5s[index] : nil

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
                    throw ENAFASTQDownloadFailure.mirrorStatus(
                        (response as? HTTPURLResponse)?.statusCode ?? -1,
                        for: filename
                    )
                }

                try Self.publishDownloadedFile(from: temporaryURL, to: stagedPath)

                // ENA's mirror answers a missing mate file with a 200 HTML
                // directory listing, and a transfer can arrive cut short or
                // altered. Reject anything that is not the file the portal
                // lists, by its size and MD5, before it can reach fastp.
                try ENAFASTQDownloadValidator.validate(
                    fileURL: stagedPath,
                    expectedBytes: expectedBytes,
                    expectedMD5: expectedMD5
                )

                stagedFiles.append((stagedPath, publishedPath))
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
                            "-o", publishedPath.path,
                        ],
                        inputs: [fileURL.absoluteString],
                        outputs: [publishedPath],
                        exitCode: 0,
                        wallTime: downloadCompletedAt.timeIntervalSince(downloadStartedAt),
                        stderr: nil,
                        startedAt: downloadStartedAt,
                        completedAt: downloadCompletedAt
                    )
                )
                progress?(Double(index + 1) / Double(totalCandidates))

                logger.info("Downloaded: \(filename, privacy: .public)")
            } catch {
                guard let failure = ENAFASTQDownloadFailure.mirrorFile(filename, failedWith: error) else {
                    throw error
                }
                logger.warning("ENA FASTQ download failed for \(fileURL.absoluteString, privacy: .public): \(failure.message, privacy: .public)")
                throw failure
            }
        }

        // Every listed file arrived whole, so the run is published at once.
        var downloadedFiles: [URL] = []
        for file in stagedFiles {
            try Self.publishDownloadedFile(from: file.staged, to: file.published)
            downloadedFiles.append(file.published)
        }

        progress?(1.0)

        return downloadedFiles
    }

    /// Downloads FASTQ via ENA first, and automatically retries via the SRA Toolkit when ENA fails.
    ///
    /// If both paths fail, `SRAError.bothArchivesFailed` names each reason in
    /// one line. Tests inject the `enaDownloader` / `toolkitDownloader`
    /// closures via the dedicated initializer. In production both default to the real
    /// `downloadFASTQFromENA` and `downloadFASTQ` methods.
    ///
    /// - Parameters:
    ///   - accession: SRA/ENA run accession.
    ///   - outputDir: Output directory (defaults to a temp folder when nil).
    ///   - progress: Optional progress callback (0.0–1.0).
    ///   - onFallback: Optional callback invoked exactly once when the ENA path
    ///     throws and the toolkit retry is about to start. Receives the
    ///     one-line `SRAFASTQDownloadSource.toolkitFallbackMessage`, which the
    ///     window's download logs and records too.
    ///   - onSource: Optional callback invoked once with where the files came
    ///     from, which `fetch sra download` records under `downloadSource`.
    ///   - onRecord: Called once with ENA's record of the run when ENA
    ///     answered with one.
    /// - Returns: URLs to downloaded FASTQ files.
    public func downloadFASTQWithFallback(
        accession: String,
        outputDir: URL?,
        progress: (@Sendable (Double) -> Void)? = nil,
        onFallback: (@Sendable (String) -> Void)? = nil,
        onSource: (@Sendable (SRAFASTQDownloadSource) -> Void)? = nil,
        onRecord: (@Sendable (ENAReadRecord) -> Void)? = nil,
        trace: DownloadTraceHandler? = nil
    ) async throws -> [URL] {
        let ena: DownloadStrategy = enaDownloader ?? { acc, dir in
            try await self.downloadFASTQFromENA(
                accession: acc, outputDir: dir, progress: progress, onRecord: onRecord, trace: trace
            )
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
                throw SRAError.bothArchivesFailed(toolkitFirst: false, enaError: enaError, toolkitError: toolkitError)
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
