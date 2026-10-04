// FASTQPlatformLabelOperation.swift - Runs `lungfish-cli fastq platform` for the Inspector
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// Every platform or read-type change the app makes runs
/// `lungfish-cli fastq platform`, so it is recorded in the Operations panel
/// with the command that reproduces it and in a provenance record beside
/// the bundle's metadata file. The app never writes the label itself.
///
/// Sites: the Inspector's Read Type popup (`--read-type`) and the
/// suspect-label notice ("Use <platform>" runs `--set`, "Keep" runs
/// `--confirm`).
@MainActor
enum FASTQPlatformLabelOperation {

    /// One change, as the user asked for it.
    enum Change: Equatable, Sendable {
        case setPlatform(LungfishIO.SequencingPlatform)
        case setReadType(FASTQAssemblyReadType?)
        case confirm

        var title: String {
            switch self {
            case .setPlatform(let platform): return "Record platform \(platform.displayName)"
            case .setReadType(let readType?): return "Record read type \(readType.displayName)"
            case .setReadType(nil): return "Clear the recorded read type"
            case .confirm: return "Keep the recorded platform"
            }
        }
    }

    /// The argv the runner executes, starting with `fastq platform`.
    nonisolated static func cliArguments(bundleURLs: [URL], change: Change) -> [String] {
        var arguments = ["fastq", "platform"] + bundleURLs.map(\.path)
        switch change {
        case .setPlatform(let platform):
            arguments += ["--set", platform.importCLIValue]
        case .setReadType(let readType?):
            arguments += ["--read-type", AssemblyReadType(persistedReadType: readType)?.cliArgument ?? "auto"]
        case .setReadType(nil):
            arguments += ["--read-type", "auto"]
        case .confirm:
            arguments.append("--confirm")
        }
        return arguments + ["--format", "json"]
    }

    /// Registers the row and, only when it starts, calls `launch`. The row
    /// locks the first bundle and every other bundle it rewrites.
    @discardableResult
    static func beginPlatformLabelOperation(
        title: String,
        bundleURLs: [URL],
        cliArguments: [String],
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: title,
            detail: "Recording the sequencing platform...",
            operationType: .fastqOperation,
            targetBundleURL: bundleURLs.first,
            additionalLockedBundleURLs: Array(bundleURLs.dropFirst()),
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "fastq platform",
                args: Array(cliArguments.dropFirst(2))
            ),
            routeContext: nil
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// Runs one change through the CLI and reports the outcome on the main actor.
    static func run(
        change: Change,
        bundleURLs: [URL],
        onFinish: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard !bundleURLs.isEmpty else { return }
        let arguments = cliArguments(bundleURLs: bundleURLs, change: change)
        let result = beginPlatformLabelOperation(
            title: change.title,
            bundleURLs: bundleURLs,
            cliArguments: arguments
        ) { operationID in
            let transport = CLISubprocessTransport()
            let task = Task {
                do {
                    let outcome = try await transport.run(
                        arguments: arguments,
                        isCancelled: { await OperationCenterCLIBridge.isOperationCancelled(operationID) },
                        onEvent: OperationCenterCLIBridge.onEvent(operationID: operationID)
                    )
                    OperationCenterCLIBridge.completeOperation(
                        operationID,
                        detail: outcome.message ?? "Recorded",
                        outputURLs: outcome.outputs.map { URL(fileURLWithPath: $0) }
                    )
                    onFinish?(true)
                } catch is CancellationError {
                    OperationCenterCLIBridge.acknowledgeCancellation(operationID)
                    onFinish?(false)
                } catch {
                    OperationCenterCLIBridge.failOperation(
                        operationID,
                        detail: error.localizedDescription,
                        fallbackMessage: "Recording the platform failed"
                    )
                    onFinish?(false)
                }
            }
            OperationCenter.shared.setCancelCallback(for: operationID) {
                task.cancel()
                transport.cancel()
            }
        }
        if case .refused = result {
            onFinish?(false)
        }
    }
}
