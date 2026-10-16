// DatabaseBrowserViewModel+PathoplexusRowDownload.swift - The Pathoplexus browser's rows, one bundle for each record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "DatabaseBrowser")

/// The route a Pathoplexus row of the browser's batch download takes (Phase 2.10 lane A45, panel
/// decision C4).
enum PathoplexusRowDownloadRoute: String, Sendable, Equatable, CaseIterable {
    /// The route before lane A45, kept for one release as the escape the hidden key names (C4). The
    /// app reads the record and builds the bundle in process in the batch folder, under the project's
    /// `.tmp` folder, and the import copies it into the Downloads folder. A record built from the
    /// Pathoplexus FASTA gets no provenance record, and a record built from GenBank names its one
    /// sequence by the LOCUS name and keeps the record of the build, the declared differences that
    /// keep the key. It goes in 2.11. A download with no project never starts a row, since the
    /// browser refuses it (lane A60).
    case legacy
    /// The default. One `lungfish-cli fetch pathoplexus <accession> --organism <id> --output-dir
    /// <folder> --format json` child for each row with a project, which writes straight into the
    /// project's Downloads folder, the folder the row's command names.
    case cli
}

/// Reads the route of the Pathoplexus rows from the defaults it is given, so a test passes its own
/// suite and never touches the user's defaults.
struct PathoplexusRowDownloadRouteSettings {
    /// The hidden key. It holds `cli` or `legacy`, or a Boolean that is true for the CLI route,
    /// for example `defaults write <app id> DatabaseBrowserPathoplexusRowRoute legacy`.
    static let defaultsKey = "DatabaseBrowserPathoplexusRowRoute"
    /// The route of a key that is unset or holds a value this reader does not know.
    static let defaultRoute: PathoplexusRowDownloadRoute = .cli

    let defaults: UserDefaults

    var route: PathoplexusRowDownloadRoute {
        switch defaults.object(forKey: Self.defaultsKey) {
        case let name as String:
            return PathoplexusRowDownloadRoute(rawValue: name.lowercased()) ?? Self.defaultRoute
        case let usesCLI as Bool:
            return usesCLI ? .cli : .legacy
        default:
            return Self.defaultRoute
        }
    }
}

extension DatabaseBrowserViewModel {
    /// The route of this browser's Pathoplexus rows, read from the defaults the view model was given
    /// (`sraDownloadSuiteName`, nil for the standard defaults).
    nonisolated var pathoplexusRowRoute: PathoplexusRowDownloadRoute {
        PathoplexusRowDownloadRouteSettings(defaults: sraDownloadDefaults).route
    }

    /// The arguments of `fetch pathoplexus` for `accessions` of `organism` into `folder`. They never
    /// hold the NCBI key, which reaches the child through its environment (SWIFT 6).
    nonisolated static func pathoplexusFetchArguments(
        accessions: [String], organism: String, folder: URL, includeGFF3Annotations: Bool
    ) -> [String] {
        ["fetch", "pathoplexus"] + accessions + ["--organism", organism, "--output-dir", folder.path]
            + (includeGFF3Annotations ? [] : ["--no-gff3"]) + ["--format", "json"]
    }

    /// Downloads the Pathoplexus row `record`, row `index` of the `totalCount` rows of the batch row
    /// `operationID`, by `route`, and returns its bundle. The CLI route writes into
    /// ``genomeRowFolder(projectURL:userDownloads:)`` and never asks for `batchFolder`. The in-process
    /// route builds in `batchFolder`, which makes the folder on its first use. `cliURLOverride` names
    /// the CLI a test launches.
    nonisolated static func downloadPathoplexusRow(
        _ record: SearchResultRecord,
        index: Int,
        totalCount: Int,
        operationID: UUID,
        route: PathoplexusRowDownloadRoute,
        organism: String,
        ncbi: NCBIService,
        genBankVM: GenBankBundleDownloadViewModel,
        includeGFF3Annotations: Bool,
        batchFolder: BatchDownloadFolder,
        projectURL: URL?,
        cliURLOverride: URL? = nil
    ) async throws -> URL {
        switch route {
        case .cli:
            let download = GenomeRowCLIDownload(
                operationID: operationID, index: index, totalCount: totalCount, cliURLOverride: cliURLOverride)
            return try await download.run(
                pathoplexusFetchArguments(
                    accessions: [record.accession.trimmingCharacters(in: .whitespacesAndNewlines)], organism: organism,
                    folder: genomeRowFolder(projectURL: projectURL), includeGFF3Annotations: includeGFF3Annotations),
                apiKey: await ncbi.resolvedAPIKey
            )
        case .legacy:
            return try await downloadPathoplexusRowInProcess(
                record, index: index, totalCount: totalCount, operationID: operationID, organism: organism,
                genBankVM: genBankVM, includeGFF3Annotations: includeGFF3Annotations, batchFolder: batchFolder)
        }
    }

    /// Downloads the Pathoplexus row `record`, row `index` of the `totalCount` rows of the batch row
    /// `operationID`, in process, and returns its bundle in `batchFolder` (Phase 2.10 lane A45).
    ///
    /// - A record whose data use terms are restricted is refused with `DatabaseServiceError.invalidQuery`.
    /// - A record with an INSDC accession builds from its GenBank record, with Pathoplexus's metadata
    ///   groups appended to the manifest. When GenBank cannot serve the record, the bundle is built from
    ///   the Pathoplexus FASTA instead.
    /// - A record with no INSDC accession builds from the Pathoplexus FASTA.
    nonisolated static func downloadPathoplexusRowInProcess(
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
