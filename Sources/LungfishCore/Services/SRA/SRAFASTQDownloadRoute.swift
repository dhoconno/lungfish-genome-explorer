// SRAFASTQDownloadRoute.swift - Where an SRA run's FASTQ files are downloaded from
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.core, category: "SRAFASTQDownloadRoute")

/// Where one SRA run's FASTQ files are downloaded from.
///
/// ENA serves each run as FASTQ files ready to use, so a run ENA lists
/// files for is downloaded from ENA's mirror. Every other case takes the
/// SRA Toolkit route, which fetches the run from NCBI with `prefetch` and
/// converts it with `fasterq-dump`. That covers an ENA error, such as the
/// HTTP 500 page ENA's portal API served for every request on 2026-10-04,
/// a run ENA has no record of, and a record without FASTQ links, so an
/// unavailable ENA never stops a download. The window's SRA download and
/// `lungfish-cli fetch sra download` both take their route from
/// `ENAService.fastqDownloadRoute(forRun:)`.
public enum SRAFASTQDownloadRoute: Sendable {
    /// ENA lists FASTQ files for the run.
    case enaMirror(ENAReadRecord)

    /// Fetch the run from NCBI with the SRA Toolkit. `enaRecord` is ENA's
    /// record when ENA answered without FASTQ links, and `reason` says in
    /// one line why ENA cannot serve the files.
    case sraToolkit(enaRecord: ENAReadRecord?, reason: String)

    /// ENA's record of the run, when ENA answered with one.
    public var enaRecord: ENAReadRecord? {
        switch self {
        case .enaMirror(let record):
            return record
        case .sraToolkit(let record, _):
            return record
        }
    }

    /// Why the route skips ENA, or nil for the ENA route.
    public var toolkitReason: String? {
        switch self {
        case .enaMirror:
            return nil
        case .sraToolkit(_, let reason):
            return reason
        }
    }
}

public extension ENAService {
    /// Chooses where to download one run's FASTQ files from.
    ///
    /// An ENA error, a run ENA has no record of, and a record without
    /// FASTQ links all choose the SRA Toolkit route, and an ENA error is
    /// logged.
    ///
    /// - Throws: Only the cancellation error when the task is cancelled.
    func fastqDownloadRoute(forRun accession: String) async throws -> SRAFASTQDownloadRoute {
        let records: [ENAReadRecord]
        do {
            records = try await searchReads(term: accession, limit: 1)
        } catch {
            if isArchiveRequestCancellation(error) {
                throw error
            }
            let failure = ArchiveRequestFailure(archive: "ENA", error: error)
            logger.warning("ENA lookup for \(accession, privacy: .public) failed, so the SRA Toolkit fetches the run: \(failure.message, privacy: .public) (\(String(describing: error), privacy: .public))")
            return .sraToolkit(enaRecord: nil, reason: "\(failure.message) for \(accession)")
        }
        guard let record = records.first else {
            return .sraToolkit(enaRecord: nil, reason: "ENA has no record of \(accession)")
        }
        guard !record.fastqHTTPURLs.isEmpty else {
            return .sraToolkit(enaRecord: record, reason: "ENA lists no FASTQ files for \(accession)")
        }
        return .enaMirror(record)
    }
}

/// Where one SRA run's FASTQ files came from, as the run's provenance and
/// FASTQ metadata record it under `downloadSource`.
public enum SRAFASTQDownloadSource: String, Sendable, CaseIterable {
    /// ENA's mirror served every file ENA lists for the run.
    case ena = "ENA"
    /// The route skipped ENA, so the SRA Toolkit fetched the run from NCBI.
    case sraToolkit = "SRA Toolkit"
    /// A file from ENA's mirror failed the download check, so the SRA
    /// Toolkit fetched the whole run.
    case sraToolkitAfterIncompleteMirror = "SRA Toolkit (ENA mirror incomplete)"
}
