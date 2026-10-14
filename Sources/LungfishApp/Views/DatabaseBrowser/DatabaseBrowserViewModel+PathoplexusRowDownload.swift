// DatabaseBrowserViewModel+PathoplexusRowDownload.swift - The Pathoplexus browser's rows, one bundle for each record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "DatabaseBrowser")

extension DatabaseBrowserViewModel {
    /// Downloads the Pathoplexus row `record`, row `index` of the `totalCount` rows of the batch row
    /// `operationID`, in process, and returns its bundle in `batchFolder` (Phase 2.10 lane A45).
    ///
    /// - A record whose data use terms are restricted is refused with `DatabaseServiceError.invalidQuery`.
    /// - A record with an INSDC accession builds from its GenBank record, with Pathoplexus's metadata
    ///   groups appended to the manifest. When GenBank cannot serve the record, the bundle is built from
    ///   the Pathoplexus FASTA instead.
    /// - A record with no INSDC accession builds from the Pathoplexus FASTA.
    nonisolated static func downloadPathoplexusRow(
        _ record: SearchResultRecord,
        index: Int,
        totalCount: Int,
        operationID downloadCenterTaskID: UUID,
        organism ppOrganism: String,
        genBankVM: GenBankBundleDownloadViewModel,
        includeGFF3Annotations: Bool,
        batchFolder: BatchDownloadFolder
    ) async throws -> URL {
        let progressFraction = Double(index) / Double(totalCount)
        let normalizedRecordAccession = record.accession.trimmingCharacters(in: .whitespacesAndNewlines)
        var fileURL: URL?
        // Check if this record has an INSDC accession for GenBank retrieval
        let pathoplexusService = PathoplexusService()
        let ppMeta = try await pathoplexusService.fetchMetadataForAccession(
            organism: ppOrganism,
            accession: normalizedRecordAccession
        )

        if ppMeta?.dataUseTerms?.uppercased() == DataUseTerms.restricted.rawValue {
            throw DatabaseServiceError.invalidQuery(
                reason: "Record \(normalizedRecordAccession) is restricted and cannot be downloaded"
            )
        } else if let insdcAccession = ppMeta?.bestINSDCAccession?.trimmingCharacters(in: .whitespacesAndNewlines), !insdcAccession.isEmpty {
            // Prefer INSDC GenBank retrieval for rich annotations; if unavailable,
            // fall back to direct Pathoplexus FASTA so the sample still downloads.
            logger.info("performBatchDownload: Pathoplexus record \(record.accession, privacy: .public) has INSDC accession \(insdcAccession, privacy: .public), fetching from GenBank")
            do {
                performOnMainRunLoop {
                    _ = DownloadCenter.shared.update(
                        id: downloadCenterTaskID,
                        progress: progressFraction,
                        detail: "Fetching GenBank record \(insdcAccession)..."
                    )
                }

                let bundleURL = try await genBankVM.downloadAndBuild(
                    accession: insdcAccession,
                    outputDirectory: try batchFolder.url(),
                    includeGFF3Annotations: includeGFF3Annotations
                ) { progress, message in
                    let overall = (Double(index) + progress) / Double(totalCount)
                    performOnMainRunLoop {
                        _ = DownloadCenter.shared.update(
                            id: downloadCenterTaskID,
                            progress: overall,
                            detail: "\(insdcAccession): \(message)"
                        )
                    }
                }

                // Append Pathoplexus metadata to the bundle manifest
                if let meta = ppMeta {
                    appendPathoplexusMetadata(meta, organism: ppOrganism, toBundleAt: bundleURL)
                }

                fileURL = bundleURL
                logger.info("performBatchDownload: Built GenBank bundle from Pathoplexus INSDC at \(bundleURL.path, privacy: .public)")
            } catch {
                logger.warning("performBatchDownload: INSDC fetch failed for \(record.accession, privacy: .public) (\(insdcAccession, privacy: .public)); falling back to Pathoplexus FASTA. Error: \(error.localizedDescription, privacy: .public)")
                performOnMainRunLoop {
                    _ = DownloadCenter.shared.update(
                        id: downloadCenterTaskID,
                        progress: progressFraction,
                        detail: "GenBank unavailable for \(record.accession); falling back to FASTA..."
                    )
                }

                let dbRecord = try await pathoplexusService.fetch(accession: record.accession, organism: ppOrganism)
                let bundleURL = try await genBankVM.buildBundleFromSequence(
                    accession: dbRecord.accession,
                    title: dbRecord.title,
                    sequence: dbRecord.sequence,
                    outputDirectory: try batchFolder.url(),
                    sourceDatabase: "Pathoplexus",
                    sourceURL: URL(string: "https://pathoplexus.org/\(ppOrganism)/search?accession=\(dbRecord.accession)"),
                    notes: "Generated from Pathoplexus FASTA fallback after INSDC lookup failed"
                ) { progress, message in
                    let overall = (Double(index) + progress) / Double(totalCount)
                    performOnMainRunLoop {
                        _ = DownloadCenter.shared.update(
                            id: downloadCenterTaskID,
                            progress: overall,
                            detail: "\(dbRecord.accession): \(message)"
                        )
                    }
                }
                if let meta = ppMeta {
                    appendPathoplexusMetadata(meta, organism: ppOrganism, toBundleAt: bundleURL)
                }
                fileURL = bundleURL
            }
        } else {
            // No INSDC accession — download FASTA only from Pathoplexus
            logger.info("performBatchDownload: Pathoplexus record \(record.accession, privacy: .public) has no INSDC accession, building bundle from Pathoplexus FASTA")
            performOnMainRunLoop {
                _ = DownloadCenter.shared.update(
                    id: downloadCenterTaskID,
                    progress: progressFraction,
                    detail: "Building bundle from Pathoplexus sequence for \(record.accession)..."
                )
            }

            let dbRecord = try await pathoplexusService.fetch(accession: normalizedRecordAccession, organism: ppOrganism)
            let bundleURL = try await genBankVM.buildBundleFromSequence(
                accession: dbRecord.accession,
                title: dbRecord.title,
                sequence: dbRecord.sequence,
                outputDirectory: try batchFolder.url(),
                sourceDatabase: "Pathoplexus",
                sourceURL: URL(string: "https://pathoplexus.org/\(ppOrganism)/search?accession=\(dbRecord.accession)"),
                notes: "Generated from Pathoplexus sequence (no INSDC accession available)"
            ) { progress, message in
                let overall = (Double(index) + progress) / Double(totalCount)
                performOnMainRunLoop {
                    _ = DownloadCenter.shared.update(
                        id: downloadCenterTaskID,
                        progress: overall,
                        detail: "\(dbRecord.accession): \(message)"
                    )
                }
            }
            if let meta = ppMeta {
                appendPathoplexusMetadata(meta, organism: ppOrganism, toBundleAt: bundleURL)
            }
            fileURL = bundleURL
        }

        guard let fileURL else {
            throw DatabaseServiceError.invalidQuery(
                reason: "Pathoplexus record \(normalizedRecordAccession) produced no bundle")
        }
        return fileURL
    }
}
