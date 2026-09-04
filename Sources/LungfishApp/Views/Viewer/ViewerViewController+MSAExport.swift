// ViewerViewController+MSAExport.swift - Alignment export destinations
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
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

    /// Presents the alignment export sheet for a `.lungfishmsa` bundle.
    func presentMSAAlignmentExportSheet(
        bundleURL: URL,
        rows: String? = nil,
        columns: String? = nil,
        selectedRowCount: Int = 0,
        totalRowCount: Int = 0
    ) {
        guard let window = view.window, window.attachedSheet == nil else { return }

        // Estimate the exported size so the clipboard can be gated before the
        // user commits rather than refused afterwards.
        let alignedFASTA = bundleURL.appendingPathComponent("alignment/primary.aligned.fasta")
        let estimatedBytes = (try? FileManager.default.attributesOfItem(atPath: alignedFASTA.path)[.size] as? Int) ?? 0

        let model = MSAAlignmentExportModel(
            name: bundleURL.deletingPathExtension().lastPathComponent,
            estimatedBytes: estimatedBytes ?? 0,
            hasSelection: rows != nil && selectedRowCount > 0 && selectedRowCount < totalRowCount,
            selectedRowCount: selectedRowCount,
            totalRowCount: totalRowCount
        )
        model.reconcileFormat()

        let sheetWindow = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        let view = MSAAlignmentExportView(
            model: model,
            onCancel: { [weak window, weak sheetWindow] in
                guard let window, let sheetWindow, window.attachedSheet === sheetWindow else { return }
                window.endSheet(sheetWindow)
            },
            onExport: { [weak self, weak window, weak sheetWindow] in
                guard let self, let window, let sheetWindow else { return }
                if window.attachedSheet === sheetWindow {
                    window.endSheet(sheetWindow)
                }
                self.runMSAAlignmentExport(
                    bundleURL: bundleURL,
                    model: model,
                    rows: rows,
                    columns: columns,
                    window: window
                )
            }
        )
        sheetWindow.contentViewController = NSHostingController(rootView: view)
        window.beginSheet(sheetWindow)
    }

    private func runMSAAlignmentExport(
        bundleURL: URL,
        model: MSAAlignmentExportModel,
        rows: String?,
        columns: String?,
        window: NSWindow
    ) {
        let configuration = model.configuration
        switch configuration.destination {
        case .clipboard:
            // Export into a registered temp file, then read it back.
            guard let tempDirectory = try? TempFileManager.shared.createRegisteredTempDirectory(
                prefix: "lungfish-msa-clipboard-"
            ) else {
                presentBlockingAlert(
                    title: "Export Alignment Failed",
                    message: "Could not create a temporary file for the export."
                )
                return
            }
            let outputURL = tempDirectory.appendingPathComponent("alignment.fasta")
            exportMSAAlignment(
                bundleURL: bundleURL,
                configuration: configuration,
                outputURL: outputURL,
                rows: rows,
                columns: columns,
                isTemporaryOutput: true
            )

        case .file, .bundle:
            let suggestedName = configuration.destination == .bundle
                ? "\(configuration.name).lungfishmsa"
                : "\(configuration.name).\(Self.fileExtension(for: configuration))"
            Task { @MainActor in
                guard let destinationURL = await DefaultSavePanelPresenter().present(
                    suggestedName: suggestedName,
                    on: window
                ) else {
                    return
                }
                self.exportMSAAlignment(
                    bundleURL: bundleURL,
                    configuration: configuration,
                    outputURL: destinationURL,
                    rows: rows,
                    columns: columns,
                    isTemporaryOutput: false
                )
            }
        }
    }

    private static func fileExtension(for configuration: MSAAlignmentExportConfiguration) -> String {
        switch configuration.format {
        case "phylip": return "phy"
        case "nexus": return "nex"
        case "clustal": return "aln"
        case "stockholm": return "sto"
        case "a2m": return "a2m"
        case "a3m": return "a3m"
        default: return "fasta"
        }
    }
}
