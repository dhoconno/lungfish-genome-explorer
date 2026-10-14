// SRADownloadRequest.swift - The download and the run-reads check that fetch sra download and its --bundle form share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// What a `fetch sra download` run needs to fetch one run's FASTQ files, as plain values a task can
/// hold (Phase 2.10 lane A45 M3). The plain run and `--bundle` call the same two functions, so the
/// route to the files, the fallback to the other archive and the lone-mate rule are written once.
struct SRADownloadRequest: Sendable {
    let accession: String
    let useToolkit: Bool
    let sourcePreference: SRADownloadSourcePreference

    /// Downloads the run into `outputURL`. With `--use-toolkit` the SRA Toolkit fetches it alone.
    /// Otherwise ENA's mirror serves it, or the toolkit after a failure, in the order the preference
    /// gives.
    func downloadFiles(
        service: SRAService,
        into outputURL: URL,
        trace: SRADownloadTraceCapture,
        reporter: SRADownloadReporter
    ) async throws -> [URL] {
        if useToolkit {
            return try await service.downloadFASTQ(
                accession: accession,
                outputDir: outputURL,
                progress: { reporter.downloadProgress($0) },
                trace: { trace.recordStep($0) }
            )
        }
        return try await service.downloadFASTQ(
            accession: accession,
            outputDir: outputURL,
            preferring: sourcePreference,
            progress: { reporter.downloadProgress($0) },
            onFallback: { message in
                trace.recordFallback(message)
                reporter.fallback(message)
            },
            onSource: { trace.recordSource($0) },
            onRecord: { trace.recordENARecord($0) },
            trace: { trace.recordStep($0) }
        )
    }

    /// Applies the lone-mate rule the window applies before it imports a run, with the layout ENA's
    /// record gives or NCBI's, and returns the reads to import with the warning to log and record.
    /// A refused run removes the files it wrote, so no half pair stays.
    func sortRunReads(
        _ files: [URL],
        service: SRAService,
        enaRecord: ENAReadRecord?
    ) async throws -> (reads: SRARunReads, layoutWarning: String?) {
        let accession = accession
        do {
            return try await SRARunReads.sorting(
                files,
                accession: accession,
                enaLayout: enaRecord?.libraryLayout,
                ncbiLayout: { await service.ncbiRunInfo(forRun: accession)?.libraryLayout }
            )
        } catch let failure as SRARunReads.Failure {
            Self.remove(files)
            throw SRARunRefusal(failure: failure)
        } catch {
            Self.remove(files)
            throw error
        }
    }

    private static func remove(_ files: [URL]) {
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
