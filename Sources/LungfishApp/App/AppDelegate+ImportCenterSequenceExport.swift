// AppDelegate+ImportCenterSequenceExport.swift - The Import Center's sequence export, moved out of AppDelegate+ImportCenter.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// The Import Center's sequence export lives here, moved out of
/// AppDelegate+ImportCenter.swift, which is at its size baseline. It holds the
/// single and batch export and the recorded `convert` commands. Every export
/// runs `lungfish-cli convert`, on the files ``SequenceExportStaging`` writes
/// for a captured document snapshot or a file `convert` does not read.
extension AppDelegate {

    /// Stages the selection off the main actor, then registers the export row with the `convert` command the
    /// run executes, and runs it (Phase 2.12 lane 12.13, A49-GAP). A staging failure shows an alert and
    /// starts no row.
    func startSequenceExport(
        sources: [SequenceExportSourceResolver.Source],
        outputURL: URL,
        format: SequenceExportFormat,
        compression: SequenceExportCompression,
        window: NSWindow,
        routeContext: OperationRouteContext?
    ) {
        Task.detached { [weak self] in
            let staged: SequenceExportStaging.Staged
            do {
                staged = try SequenceExportStaging.stage(sources, format: format, outputURL: outputURL)
            } catch {
                let report = AppFailureReports.stageSequenceExport(error)
                await MainActor.run { FailurePresenter.present(report, in: window) }
                return
            }
            guard let self else { return staged.discard() }
            await self.beginStagedSequenceExport(
                staged, outputURL: outputURL, format: format, compression: compression,
                window: window, routeContext: routeContext
            )
        }
    }

    /// Registers the export row for the staged inputs and runs the export once the row started. A refused row
    /// and a failed or cancelled run discard the staging, since no record names it then.
    private func beginStagedSequenceExport(
        _ staged: SequenceExportStaging.Staged,
        outputURL: URL,
        format: SequenceExportFormat,
        compression: SequenceExportCompression,
        window: NSWindow,
        routeContext: OperationRouteContext?
    ) {
        let result = Self.beginSequenceExportOperation(
            outputURL: outputURL,
            inputURLs: staged.inputs,
            format: format,
            compression: compression,
            routeContext: routeContext
        ) { opID in
            let task = Task.detached { [weak self] in
                do {
                    await appPerformOnMainRunLoop {
                        OperationCenter.shared.log(id: opID, level: .info, message: "Writing \(format.displayName) export to \(outputURL.path)")
                    }
                    let count = try await staged.run { inputs in
                        try await self?.performSequenceExport(
                            inputs: inputs,
                            outputURL: outputURL,
                            format: format,
                            compression: compression
                        ) ?? 0
                    }

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard OperationCenter.shared.complete(
                                id: opID,
                                detail: "Exported \(count) sequence(s) to \(outputURL.lastPathComponent)"
                            ) else { return }
                            let alert = NSAlert()
                            alert.messageText = "Export Complete"
                            alert.informativeText = "Exported \(count) sequence(s) to \(outputURL.lastPathComponent)."
                            alert.alertStyle = .informational
                            alert.addButton(withTitle: "OK")
                            alert.addButton(withTitle: "Show in Finder")
                            alert.beginSheetModal(for: window) { response in
                                if response == .alertSecondButtonReturn {
                                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                                }
                            }
                        }
                    }
                } catch {
                    debugLog("exportSequences: Failed - \(error)")
                    let detail = error.localizedDescription
                    let report = AppFailureReports.exportSequences(error)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard OperationCenter.shared.fail(
                                id: opID,
                                detail: detail,
                                errorMessage: "Sequence export failed",
                                errorDetail: detail
                            ) else { return }
                            FailurePresenter.present(report, in: window)
                        }
                    }
                }
            }
            OperationCenter.shared.setCancelCallback(for: opID) {
                task.cancel()
            }
        }
        if case .refused = result { staged.discard() }
    }

    /// Runs `lungfish-cli convert` on `inputs`, the files of the selection after staging, and returns the count
    /// of sequences written. The command is the one the row records (``SequenceExportRoute``), and it compresses.
    nonisolated func performSequenceExport(
        inputs: [URL],
        outputURL: URL,
        format: SequenceExportFormat,
        compression: SequenceExportCompression
    ) async throws -> Int {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try await SequenceExportRoute.run(
            arguments: SequenceExportRoute.arguments(
                inputs: inputs,
                outputURL: outputURL,
                format: format,
                compression: compression
            ),
            outputURL: outputURL
        )
    }

    nonisolated static func batchSequenceExportTargets(
        for bundleURLs: [URL],
        outputFolder: URL,
        format: SequenceExportFormat,
        compression: SequenceExportCompression
    ) -> [URL: URL] {
        var usedNames = Set<String>()
        var targets: [URL: URL] = [:]

        for bundleURL in bundleURLs {
            let rawBase = bundleURL.deletingPathExtension().lastPathComponent
            let base = rawBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "reference" : rawBase
            var filename = "\(base).\(format.fileExtension)"
            if let compressionExtension = compression.fileExtension {
                filename += ".\(compressionExtension)"
            }

            if usedNames.contains(filename) {
                var counter = 2
                repeat {
                    filename = "\(base)-\(counter).\(format.fileExtension)"
                    if let compressionExtension = compression.fileExtension {
                        filename += ".\(compressionExtension)"
                    }
                    counter += 1
                } while usedNames.contains(filename)
            }

            usedNames.insert(filename)
            targets[bundleURL] = outputFolder.appendingPathComponent(filename)
        }

        return targets
    }

    /// The `convert` command of each bundle, in order, which the batch runs one after another.
    nonisolated static func batchSequenceExportCLICommands(
        for bundleURLs: [URL],
        outputFolder: URL,
        format: SequenceExportFormat,
        compression: SequenceExportCompression
    ) -> [String] {
        let targets = batchSequenceExportTargets(
            for: bundleURLs,
            outputFolder: outputFolder,
            format: format,
            compression: compression
        )
        return bundleURLs.compactMap { bundleURL in
            guard let outputURL = targets[bundleURL] else { return nil }
            return sequenceExportCLICommand(
                inputURLs: [bundleURL],
                outputURL: outputURL,
                format: format,
                compression: compression
            )
        }
    }

    /// The `lungfish-cli convert` command the export runs, which the row records. It is nil for an empty list
    /// or a file `convert` cannot read, which ``SequenceExportStaging`` never hands it, since it stages such a
    /// file and every captured document snapshot first.
    nonisolated static func sequenceExportCLICommand(
        inputURLs: [URL],
        outputURL: URL,
        format: SequenceExportFormat,
        compression: SequenceExportCompression
    ) -> String? {
        guard !inputURLs.isEmpty, inputURLs.allSatisfy(SequenceExportRoute.convertReads) else { return nil }
        let arguments = SequenceExportRoute.arguments(
            inputs: inputURLs,
            outputURL: outputURL,
            format: format,
            compression: compression
        )
        return OperationCenter.buildCLICommand(subcommand: "convert", args: Array(arguments.dropFirst()))
    }

    /// The bundle's annotations through the loader `bundle export-gff3` shares (Phase 2.12 lane 12.39).
    nonisolated func loadBundleAnnotations(bundleURL: URL, manifest: BundleManifest) throws -> [SequenceAnnotation] {
        try AnnotationGFF3Export.loadBundleAnnotations(bundleURL: bundleURL, manifest: manifest).annotations
    }
}
