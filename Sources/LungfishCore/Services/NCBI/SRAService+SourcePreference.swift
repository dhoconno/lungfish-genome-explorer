// SRAService+SourcePreference.swift - Download an SRA run from the archive the user prefers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.core, category: "SRAService")

public extension SRAService {
    /// Downloads one run's FASTQ files from the archive `preference` names
    /// first, as `lungfish-cli fetch sra download --prefer-source` does.
    ///
    /// `.ena` is `downloadFASTQWithFallback`, unchanged. `.ncbi` looks the
    /// run up on ENA, plans the transfers with
    /// `SRAFASTQDownloadRoute.plan(preferring:)`, and fetches the run with
    /// the SRA Toolkit. When the toolkit is not installed or fails, the reads
    /// it wrote are removed and ENA's mirror serves the run, if ENA lists
    /// FASTQ files for it. A cancellation stops the download.
    ///
    /// - Parameters:
    ///   - onFallback: Called once with the line to log when the download
    ///     falls back to the other archive.
    ///   - onSource: Called once with where the files came from.
    /// - Throws: `SRAError.downloadFailed` naming both failures when no
    ///   archive could serve the run, or a cancellation.
    func downloadFASTQ(
        accession: String,
        outputDir: URL,
        preferring preference: SRADownloadSourcePreference,
        progress: (@Sendable (Double) -> Void)? = nil,
        onFallback: (@Sendable (String) -> Void)? = nil,
        onSource: (@Sendable (SRAFASTQDownloadSource) -> Void)? = nil,
        trace: DownloadTraceHandler? = nil
    ) async throws -> [URL] {
        guard preference == .ncbi else {
            return try await downloadFASTQWithFallback(
                accession: accession,
                outputDir: outputDir,
                progress: progress,
                onFallback: onFallback,
                onSource: onSource,
                trace: trace
            )
        }

        let route = try await ENAService(httpClient: httpClient).fastqDownloadRoute(forRun: accession)
        let plan = route.plan(preferring: .ncbi)
        let toolkit: DownloadStrategy = toolkitDownloader ?? { acc, dir in
            try await self.downloadFASTQ(accession: acc, outputDir: dir, progress: progress, trace: trace)
        }
        // Noted before the toolkit runs, so only the reads it wrote are removed.
        let runFiles = SRAToolkitRunFiles(accession: accession, outputDirectory: outputDir)
        do {
            let files = try await toolkit(accession, outputDir)
            onSource?(.sraToolkit)
            return files
        } catch let toolkitError {
            guard let source = SRAFASTQDownloadSource.enaFallback(afterToolkitError: toolkitError) else {
                throw toolkitError
            }
            guard plan.transfers.contains(.enaMirror) else {
                let enaReason = route.toolkitReason ?? "ENA lists no FASTQ files for \(accession)"
                throw SRAError.downloadFailed("Toolkit: \(toolkitError.localizedDescription); ENA: \(enaReason)")
            }
            for file in runFiles.writtenFASTQFiles() {
                try? FileManager.default.removeItem(at: file)
            }
            let message = SRAFASTQDownloadSource.enaFallbackMessage(accession: accession, after: toolkitError)
            logger.warning("\(message, privacy: .public)")
            onFallback?(message)
            let ena: DownloadStrategy = enaDownloader ?? { acc, dir in
                try await self.downloadFASTQFromENA(accession: acc, outputDir: dir, progress: progress, trace: trace)
            }
            do {
                let files = try await ena(accession, outputDir)
                onSource?(source)
                return files
            } catch let enaError {
                if isArchiveRequestCancellation(enaError) {
                    throw enaError
                }
                let enaReason = (enaError as? ENAFASTQDownloadFailure)?.message ?? enaError.localizedDescription
                throw SRAError.downloadFailed("Toolkit: \(toolkitError.localizedDescription); ENA: \(enaReason)")
            }
        }
    }
}
