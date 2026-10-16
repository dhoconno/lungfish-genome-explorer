// DatabaseBrowserViewModel+GenomeRowDownload.swift - The NCBI browser's genome rows through lungfish-cli fetch genome
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import os.log
import Synchronization

private let genomeRowLogger = Logger(subsystem: LogSubsystem.app, category: "DatabaseBrowserGenomeRows")

extension DatabaseBrowserViewModel {
    /// The folder a genome row writes its bundle into, which its command names. With a project
    /// it is the project's Downloads folder, where the import keeps a bundle in place
    /// (`DownloadImportRouting`). A download with no project never starts a row, since the browser
    /// refuses it with `No Project Open` (lane A60, decision C2), so no row writes without one.
    /// Without one the folder would be the user's Downloads folder, never a system scratch folder
    /// (UX 8) and never `Lungfish Downloads`, where the import would copy the bundle under a new
    /// name and delete it.
    nonisolated static func genomeRowFolder(projectURL: URL?, userDownloads: URL = userDownloadsFolder) -> URL {
        projectURL?.appendingPathComponent("Downloads", isDirectory: true) ?? userDownloads
    }

    /// The user's Downloads folder.
    nonisolated static var userDownloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// The arguments of `fetch genome` for `accessions` into `folder`. They never hold the NCBI
    /// key, which reaches the child through its environment (SWIFT 6).
    nonisolated static func genomeFetchArguments(accessions: [String], folder: URL) -> [String] {
        ["fetch", "genome"] + accessions + ["--output-dir", folder.path, "--format", "json"]
    }

    /// The child environment of a genome row, the key the browser's NCBI service sends, if any.
    nonisolated static func genomeFetchEnvironment(apiKey: String?) -> [String: String] {
        apiKey.map { ["NCBI_API_KEY": $0] } ?? [:]
    }

    /// Downloads the genome row `record`, row `index` of the `totalCount` rows of the batch row
    /// `operationID`, through `lungfish-cli fetch genome` into
    /// ``genomeRowFolder(projectURL:userDownloads:)``, and returns its bundle. `cliURLOverride`
    /// names the CLI a test launches.
    nonisolated static func downloadGenomeRow(
        _ record: SearchResultRecord,
        index: Int,
        totalCount: Int,
        operationID: UUID,
        ncbi: NCBIService,
        projectURL: URL?,
        cliURLOverride: URL? = nil
    ) async throws -> URL {
        let download = GenomeRowCLIDownload(
            operationID: operationID, index: index, totalCount: totalCount, cliURLOverride: cliURLOverride)
        return try await download.fetch(
            record.accession.trimmingCharacters(in: .whitespacesAndNewlines),
            into: genomeRowFolder(projectURL: projectURL),
            apiKey: await ncbi.resolvedAPIKey
        )
    }
}

/// The batch folder of one batch download of the browser, made on its first use (Phase 2.10 lane
/// A44, ruling 1). An in-process row builds its bundle in it, under the project's `.tmp` folder,
/// or the system's temporary folder with no project. A genome row on the CLI route writes straight
/// into the folder its command names and never asks for it, so a CLI genome batch makes no batch
/// folder. A failure to make it fails the row that asked, and the next row asks again. One batch
/// download makes one inside its own task and never shares it.
final class BatchDownloadFolder: Sendable {
    let projectURL: URL?
    private let made = Mutex<URL?>(nil)

    init(projectURL: URL?) {
        self.projectURL = projectURL
    }

    /// The batch folder, made with its owner marker on the first call.
    func url() throws -> URL {
        try made.withLock { folder in
            if let folder { return folder }
            let created = try ProjectTempDirectory.create(prefix: "batch-", in: projectURL)
            genomeRowLogger.info("performBatchDownload: Created batch directory at \(created.path, privacy: .public)")
            folder = created
            return created
        }
    }
}

/// One genome row through `lungfish-cli fetch genome <accession> --output-dir <folder> --format
/// json` (Phase 2.10 lane A44, ruling Q2b). The child gets the NCBI key through its environment and
/// never its arguments (SWIFT 6), SIGTERM and the launcher's grace when the batch row is
/// cancelled, so it removes the bundle it was building and exits 125, and the launcher's drain. Its
/// events reach the batch row through `OperationCenterCLIBridge`, each progress fraction as the
/// row's share `(index + fraction) / totalCount`, its start line as a log line and its failure as
/// an error line. The bundle is the first path its `complete` line names. The variant-only
/// reference download runs its `--into-bundle` child the same way, as row 0 of 1 (lane A44 M3).
struct GenomeRowCLIDownload: Sendable {
    let operationID: UUID
    let index: Int
    let totalCount: Int
    /// The CLI to launch, nil for the app's own.
    var cliURLOverride: URL?

    init(operationID: UUID, index: Int, totalCount: Int, cliURLOverride: URL? = nil) {
        self.operationID = operationID
        self.index = index
        self.totalCount = totalCount
        self.cliURLOverride = cliURLOverride
    }

    func fetch(_ accession: String, into folder: URL, apiKey: String?) async throws -> URL {
        try await run(DatabaseBrowserViewModel.genomeFetchArguments(accessions: [accession], folder: folder), apiKey: apiKey)
    }

    /// Runs one `fetch genome` child with `arguments`, which never hold the key, and returns the
    /// first path its `complete` line names.
    func run(_ arguments: [String], apiKey: String?) async throws -> URL {
        let transport = CLISubprocessTransport(cliURLOverride: cliURLOverride)
        let operationID = operationID
        // On the main run loop, as every update of this batch is, so a modal session cannot hold it.
        await performOnMainRunLoopAsync {
            OperationCenter.shared.setCancelCallback(for: operationID) { transport.cancel() }
        }
        let bridge = OperationCenterCLIBridge.onEvent(operationID: operationID)
        let share = self.share
        let result = try await transport.run(
            arguments: arguments,
            terminationGracePeriod: CLIProcessLauncher.operationGrace,
            drainGracePeriod: CLIProcessLauncher.operationDrain,
            environmentAdditions: DatabaseBrowserViewModel.genomeFetchEnvironment(apiKey: apiKey),
            isCancelled: {
                await performOnMainRunLoopAsync { OperationCenterCLIBridge.isOperationCancelled(operationID) }
            },
            onEvent: { event in
                switch event {
                case let .progress(fraction, message):
                    bridge(.progress(fraction: share(fraction), message: message))
                case let .start(message):
                    bridge(.log(level: .info, message: message))
                case let .failed(message, _):
                    bridge(.log(level: .error, message: message))
                case .log, .output, .complete:
                    bridge(event)
                }
            }
        )
        guard let path = result.outputs.first, !path.isEmpty else {
            throw CLISubprocessTransport.RunError.missingCompletion
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The batch row's fraction for `fraction` of this row.
    var share: @Sendable (Double) -> Double {
        let index = Double(index)
        let total = Double(max(totalCount, 1))
        return { fraction in (index + min(max(fraction, 0), 1)) / total }
    }
}
