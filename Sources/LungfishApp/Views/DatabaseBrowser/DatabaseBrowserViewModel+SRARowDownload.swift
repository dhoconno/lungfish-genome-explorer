// DatabaseBrowserViewModel+SRARowDownload.swift - The SRA browser's rows, one lungfish-cli fetch sra download child for each run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "DatabaseBrowser")

extension DatabaseBrowserViewModel {
    /// The arguments of `fetch sra download --bundle` for `accession` into `project`, with the import
    /// sheet's settings. The import's flags come from `sraImportCLIArguments`, the function the window
    /// builds its `import fastq` argv with, so the two never disagree. They never hold the NCBI key,
    /// which reaches the child through its environment (SWIFT 6).
    nonisolated static func sraFetchArguments(
        accession: String, importConfig: FASTQImportConfiguration, project: URL, preferNCBI: Bool
    ) -> [String] {
        // `import fastq <file> --project <folder>` come first, and `--format json` sits among the flags.
        var flags = Array(
            sraImportCLIArguments(
                importConfig: importConfig, r1: URL(fileURLWithPath: "/"), r2: nil, projectDirectory: project
            ).dropFirst(5))
        if let format = flags.firstIndex(of: "--format"), format + 1 < flags.count {
            flags.removeSubrange(format...(format + 1))
        }
        return ["fetch", "sra", "download", accession, "--bundle", "--project", project.path] + flags
            + (preferNCBI ? ["--prefer-source", "ncbi"] : []) + ["--format", "json"]
    }

    /// The command the SRA row records: one `fetch sra download` line for each run, in run order,
    /// because the command takes one run (`SRADownloadSubcommand`).
    nonisolated static func sraRowCLICommand(arguments: [[String]]) -> String {
        arguments
            .map { OperationCenter.buildCLICommand(subcommand: "fetch sra download", args: Array($0.dropFirst(3))) }
            .joined(separator: "\n")
    }

    /// Starts the download of the SRA runs `records` after the user confirmed the import sheet. Each run
    /// is one `fetch sra download --bundle` child into the project, in order. The row began before the
    /// sheet, so its command is set here with the sheet's flags. A batch with no project never gets
    /// here, since the browser refuses it before its row begins (lane A60). If one ever does, the row
    /// fails in the refusal's words and starts nothing, because the in-process download that took such
    /// a batch went with the hidden key of the SRA row (Phase 2.11 K3).
    func startSRADownloadTask(
        records: [SearchResultRecord],
        importConfig: FASTQImportConfiguration,
        downloadCenterTaskID: UUID,
        totalCount: Int
    ) {
        guard let context = routeContext, let projectURL = context.projectURL else {
            logger.error("startSRADownloadTask: No project for \(records.count) run(s), so nothing starts")
            _ = DownloadCenter.shared.fail(
                id: downloadCenterTaskID, detail: "Open or create a project before downloading SRA runs.")
            return
        }
        let preferNCBI = sraDownloadPreference() == .ncbi
        let argumentLists = records.map {
            Self.sraFetchArguments(
                accession: $0.accession, importConfig: importConfig, project: projectURL, preferNCBI: preferNCBI)
        }
        DownloadCenter.shared.setCommand(id: downloadCenterTaskID, command: Self.sraRowCLICommand(arguments: argumentLists))
        let ncbi = ncbiService
        let downloadTask = Task.detached {
            guard await Self.canWriteSRAProject(projectURL, context: context) else {
                performOnMainRunLoop {
                    _ = DownloadCenter.shared.fail(id: downloadCenterTaskID, detail: "Project is open read only")
                }
                return
            }
            let apiKey = await ncbi.resolvedAPIKey
            var delivered = 0
            var failures: [String] = []
            var cancelled = false
            for (index, record) in records.enumerated() {
                do {
                    let bundle = try await GenomeRowCLIDownload(
                        operationID: downloadCenterTaskID, index: index, totalCount: totalCount
                    ).run(argumentLists[index], apiKey: apiKey)
                    delivered += 1
                    // Deliver the bundle at once, so it appears in the sidebar before the next run starts.
                    performOnMainRunLoop {
                        if let handler = DownloadCenter.shared.onBundleReadyWithContext {
                            handler([bundle], context)
                        } else {
                            DownloadCenter.shared.onBundleReady?([bundle])
                        }
                    }
                } catch is CancellationError {
                    logger.info("startSRADownloadTask: Cancelled during \(record.accession, privacy: .public)")
                    cancelled = true
                    break
                } catch {
                    logger.error("startSRADownloadTask: Failed for \(record.accession, privacy: .public): \(error, privacy: .public)")
                    failures.append("\(record.accession): \(error.localizedDescription)")
                    performOnMainRunLoop {
                        _ = DownloadCenter.shared.update(
                            id: downloadCenterTaskID,
                            progress: Double(index + 1) / Double(max(totalCount, 1)),
                            detail: "Failed: \(record.accession) - \(error.localizedDescription)")
                    }
                }
            }
            let finalDelivered = delivered
            let finalFailures = failures
            let wasCancelled = cancelled
            performOnMainRunLoop {
                Self.finishSRARow(
                    id: downloadCenterTaskID, totalCount: totalCount, delivered: finalDelivered,
                    failures: finalFailures, cancelled: wasCancelled)
            }
        }
        // Until the first child starts, the Operations panel's Cancel stops the batch. Each child then
        // installs the callback that cancels its own transport (GenomeRowCLIDownload.run).
        DownloadCenter.shared.setCancelCallback(for: downloadCenterTaskID) { downloadTask.cancel() }
    }

    /// Ends the row once every run was tried. A cancel ends it as Cancelled with no alert (UX 4), the
    /// bundles delivered before it stay, and a batch where every run failed ends as failed.
    @MainActor
    private static func finishSRARow(id: UUID, totalCount: Int, delivered: Int, failures: [String], cancelled: Bool) {
        if cancelled {
            // The row is already cancelling, so OperationCenter records this as cancelled.
            _ = DownloadCenter.shared.fail(id: id, detail: "Cancelled by user")
        } else if delivered == 0 && !failures.isEmpty {
            let summary = failures.prefix(3).joined(separator: "; ")
            _ = DownloadCenter.shared.fail(id: id, detail: "Completed with \(failures.count) failure(s): \(summary)")
        } else {
            let detail: String
            if !failures.isEmpty {
                detail = "Completed \(delivered) download(s), \(failures.count) failed. \(failures.prefix(3).joined(separator: "; "))"
            } else if totalCount == 1 {
                detail = "FASTQ ready"
            } else {
                detail = "Completed \(delivered) file(s)"
            }
            // The bundles were delivered as each run finished.
            _ = DownloadCenter.shared.complete(id: id, detail: detail, bundleURLs: [])
        }
    }

    /// Whether the batch may write the project, which a read-only project refuses, as the window's task asks.
    private static func canWriteSRAProject(_ projectURL: URL, context: OperationRouteContext) async -> Bool {
        await performOnMainRunLoopAsync {
            AppDelegate.shared?.canWriteProjectOutputs(
                projectURL: projectURL,
                windowStateScope: context.windowStateScopeID.map(WindowStateScope.init(id:)),
                workflowName: "SRA/ENA download",
                presentingWindow: NSApp.keyWindow ?? NSApp.mainWindow
            ) ?? true
        }
    }
}
