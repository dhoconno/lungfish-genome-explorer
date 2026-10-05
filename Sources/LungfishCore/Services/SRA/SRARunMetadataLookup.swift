// SRARunMetadataLookup.swift - SRA run records from ENA and NCBI, either of which may fail
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.core, category: "SRARunMetadataLookup")

/// Looks up SRA runs in ENA and in NCBI, so that one archive's outage never
/// hides a run the other archive still describes.
///
/// ENA's record adds the FASTQ links and file sizes, and NCBI's run info
/// adds the organism and the release date. Each archive's failure is
/// logged and reported in the outcome. A lookup throws only when both
/// archives fail, or when its task is cancelled. On 2026-10-04 ENA's portal
/// API failed every request while NCBI worked, and a search for one run
/// failed outright, because it stopped at ENA's error before it read NCBI's
/// answer.
public struct SRARunMetadataLookup: Sendable {
    /// One run with each archive's record. At least one of the two is set.
    public struct Run: Sendable {
        public let accession: String
        public let enaRecord: ENAReadRecord?
        public let ncbiRun: SRARunInfo?
    }

    /// The runs a lookup found and how each archive answered.
    public struct Outcome: Sendable {
        /// The runs in the order the lookup asked for them.
        public let runs: [Run]
        /// ENA's first failure, nil when ENA answered every lookup.
        public let enaFailure: ArchiveRequestFailure?
        /// How many of the `enaLookupCount` ENA lookups failed.
        public let enaFailedCount: Int
        public let enaLookupCount: Int
        /// NCBI's failure, nil when NCBI answered.
        public let ncbiFailure: ArchiveRequestFailure?

        /// One line saying which archive failed and whose records are
        /// shown, or nil when both archives answered, for example
        /// "ENA returned HTTP 500 (server error). Results from NCBI are shown."
        public var notice: String? {
            var failures: [String] = []
            if let ncbiFailure {
                failures.append(ncbiFailure.message)
            }
            if let enaFailure {
                failures.append(
                    enaFailedCount < enaLookupCount
                        ? "\(enaFailure.message) for \(enaFailedCount) of \(enaLookupCount) accessions"
                        : enaFailure.message
                )
            }
            guard !failures.isEmpty else { return nil }
            let shownArchive = ncbiFailure == nil ? "NCBI" : "ENA"
            return failures.joined(separator: ", and ") + ". Results from \(shownArchive) are shown."
        }
    }

    /// Both archives failed, so the lookup has no record to show.
    public struct BothArchivesFailed: LocalizedError, Sendable, Equatable {
        public let ena: ArchiveRequestFailure
        public let ncbi: ArchiveRequestFailure

        public var errorDescription: String? {
            "\(ena.message), and \(ncbi.message)."
        }
    }

    private let ena: ENAService
    private let ncbi: NCBIService
    private let enaConcurrency: Int

    public init(ena: ENAService, ncbi: NCBIService, enaConcurrency: Int = 10) {
        self.ena = ena
        self.ncbi = ncbi
        self.enaConcurrency = enaConcurrency
    }

    /// Looks up accessions in ENA's file report and NCBI's run info at
    /// the same time. A run comes back when either archive has a record of
    /// it under the accession asked for, in the order of `accessions`.
    ///
    /// - Parameter progress: Receives (completed, total) after each ENA lookup.
    /// - Throws: `BothArchivesFailed` when every ENA lookup and the NCBI
    ///   lookup failed, or the cancellation error when the task is cancelled.
    public func lookUpRuns(
        _ accessions: [String],
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> Outcome {
        guard !accessions.isEmpty else {
            return Outcome(runs: [], enaFailure: nil, enaFailedCount: 0, enaLookupCount: 0, ncbiFailure: nil)
        }
        let ena = self.ena
        let ncbi = self.ncbi
        let enaConcurrency = self.enaConcurrency
        async let enaBatch = ena.searchReadsBatchReportingFailures(
            accessions: accessions,
            concurrency: enaConcurrency,
            progress: progress
        )
        async let ncbiAnswer = Self.ncbiRunInfo(for: accessions, from: ncbi)
        let batch = try await enaBatch
        let ncbiRuns = try await ncbiAnswer

        let ncbiFailure: ArchiveRequestFailure?
        let runInfo: [SRARunInfo]
        switch ncbiRuns {
        case .success(let runs):
            ncbiFailure = nil
            runInfo = runs
        case .failure(let failure):
            ncbiFailure = failure
            runInfo = []
        }
        if let ncbiFailure, let enaFailure = batch.failure, batch.failedAccessions.count == accessions.count {
            throw BothArchivesFailed(ena: enaFailure, ncbi: ncbiFailure)
        }

        let enaByAccession = Dictionary(batch.records.map { ($0.runAccession, $0) }, uniquingKeysWith: { first, _ in first })
        let ncbiByAccession = Dictionary(runInfo.map { ($0.accession, $0) }, uniquingKeysWith: { first, _ in first })
        let runs = accessions.compactMap { accession -> Run? in
            let enaRecord = enaByAccession[accession]
            let ncbiRun = ncbiByAccession[accession]
            guard enaRecord != nil || ncbiRun != nil else { return nil }
            return Run(accession: accession, enaRecord: enaRecord, ncbiRun: ncbiRun)
        }
        return Outcome(
            runs: runs,
            enaFailure: batch.failure,
            enaFailedCount: batch.failedAccessions.count,
            enaLookupCount: accessions.count,
            ncbiFailure: ncbiFailure
        )
    }

    /// Adds ENA's records to runs an NCBI search already found. ENA's
    /// failures leave those runs with NCBI's record only.
    ///
    /// - Parameter progress: Receives (completed, total) after each ENA lookup.
    /// - Throws: Only the cancellation error when the task is cancelled.
    public func addingENARecords(
        to ncbiRuns: [SRARunInfo],
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> Outcome {
        let accessions = ncbiRuns.map(\.accession)
        let batch = try await ena.searchReadsBatchReportingFailures(
            accessions: accessions,
            concurrency: enaConcurrency,
            progress: progress
        )
        let enaByAccession = Dictionary(batch.records.map { ($0.runAccession, $0) }, uniquingKeysWith: { first, _ in first })
        return Outcome(
            runs: ncbiRuns.map { Run(accession: $0.accession, enaRecord: enaByAccession[$0.accession], ncbiRun: $0) },
            enaFailure: batch.failure,
            enaFailedCount: batch.failedAccessions.count,
            enaLookupCount: accessions.count,
            ncbiFailure: nil
        )
    }

    private static func ncbiRunInfo(
        for accessions: [String],
        from ncbi: NCBIService
    ) async throws -> Result<[SRARunInfo], ArchiveRequestFailure> {
        do {
            return .success(try await ncbi.sraEFetchRunInfo(ids: accessions))
        } catch {
            if isArchiveRequestCancellation(error) {
                throw error
            }
            let failure = ArchiveRequestFailure(archive: "NCBI", error: error)
            logger.warning("NCBI run info lookup failed for \(accessions.count, privacy: .public) accession(s): \(failure.message, privacy: .public) (\(String(describing: error), privacy: .public))")
            return .failure(failure)
        }
    }
}
