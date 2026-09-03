// ViewerViewController+MSAExport.swift - Alignment export destinations
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import os.log

private let msaExportLogger = Logger(subsystem: LogSubsystem.app, category: "ViewerMSAExport")

extension ViewerViewController {
    /// Runs an alignment export to a bundle, a file, or the clipboard.
    ///
    /// The clipboard leg reads the exported file and checks its size off the
    /// main actor, then hops back carrying only the resulting string.
    func exportMSAAlignment(
        bundleURL: URL,
        configuration: MSAAlignmentExportConfiguration,
        outputURL: URL,
        rows: String?,
        columns: String?,
        isTemporaryOutput: Bool
    ) {
        let arguments = MSAAlignmentExportSheet.cliArguments(
            for: configuration,
            bundleURL: bundleURL,
            outputURL: outputURL,
            rows: rows,
            columns: columns
        )
        let cliCommand = CLIMSAActionCommandBuilder.displayCommand(arguments: arguments)
        let isBundleOutput = configuration.destination == .bundle
        let title: String
        switch configuration.destination {
        case .bundle: title = "Create Alignment Bundle"
        case .file: title = "Export Alignment"
        case .clipboard: title = "Copy Alignment"
        }

        let operationID = OperationCenter.shared.start(
            title: title,
            detail: "Exporting \(bundleURL.lastPathComponent)...",
            operationType: .multipleSequenceAlignmentAction,
            targetBundleURL: bundleURL,
            cliCommand: cliCommand,
            routeContext: OperationRouteContext(
                projectURL: ProjectTempDirectory.findProjectRoot(bundleURL),
                windowStateScope: windowStateScope
            )
        )
        OperationCenter.shared.log(
            id: operationID,
            level: .info,
            message: "Exporting \(configuration.layout == .aligned ? "aligned" : "unaligned") sequences as \(configuration.format)."
        )

        let runner = CLIMSAActionRunner()
        OperationCenter.shared.setCancelCallback(for: operationID) { runner.cancel() }

        let destination = configuration.destination
        Task.detached {
            do {
                _ = try await runner.run(arguments: arguments, operationID: operationID)

                guard destination == .clipboard else {
                    if isBundleOutput {
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                OperationCenter.shared.log(
                                    id: operationID,
                                    level: .info,
                                    message: "Created \(outputURL.lastPathComponent)."
                                )
                            }
                        }
                    }
                    return
                }

                // Read and size-check off the main actor; only the resulting
                // string crosses back.
                defer {
                    if isTemporaryOutput {
                        try? FileManager.default.removeItem(at: outputURL)
                    }
                }
                let data = try Data(contentsOf: outputURL)
                guard MSAAlignmentExportSheet.isClipboardAvailable(estimatedBytes: data.count) else {
                    let message = MSAAlignmentExportSheet.clipboardUnavailableMessage(estimatedBytes: data.count)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            _ = OperationCenter.shared.fail(
                                id: operationID,
                                detail: "Alignment too large for the clipboard",
                                errorMessage: message
                            )
                        }
                    }
                    return
                }
                let text = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(text, forType: .string)
                        _ = OperationCenter.shared.update(
                            id: operationID,
                            progress: 1.0,
                            detail: "Copied the alignment to the clipboard"
                        )
                        OperationCenter.shared.log(
                            id: operationID,
                            level: .info,
                            message: "Copied \(data.count) bytes to the clipboard."
                        )
                        _ = OperationCenter.shared.complete(
                            id: operationID,
                            detail: "Copied the alignment to the clipboard",
                            bundleURLs: []
                        )
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        _ = OperationCenter.shared.fail(
                            id: operationID,
                            detail: error.localizedDescription,
                            errorMessage: error.localizedDescription
                        )
                    }
                }
            }
        }
    }
}
