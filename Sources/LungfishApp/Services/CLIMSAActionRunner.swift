// CLIMSAActionRunner.swift — Runs `lungfish-cli msa <action>` through CLISubprocessTransport.
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow

/// Runs any `lungfish-cli msa` action subcommand (annotate/export/consensus/
/// extract/mask/trim/distance/…) as a subprocess, decoding the shared
/// `CLIEvent` schema instead of the private `msaAction*` JSON shape this
/// runner used to hand-parse (ARC-02, SIMP-04). All call sites only ever
/// cared whether the run succeeded and, on success, its output path; none
/// read `warningCount` or `actionID` from the old `CLIMSAActionResult`, so
/// those fields are no longer round-tripped over the wire.
struct CLIMSAActionRunner {
    enum RunError: Error, LocalizedError, Equatable {
        case underlying(String)

        var errorDescription: String? {
            switch self {
            case let .underlying(message): return message
            }
        }
    }

    struct Result: Sendable, Equatable {
        let outputURL: URL
    }

    private let transport: CLISubprocessTransport

    init(cliURLOverride: URL? = nil) {
        self.transport = CLISubprocessTransport(cliURLOverride: cliURLOverride)
    }

    /// - Parameter ownsOperationLifecycle: When `false` (the clipboard export
    ///   leg), the caller records `OperationCenter` completion itself after
    ///   further work (clipboard availability check, publish), so this method
    ///   must not call `complete`/`fail` on success or cancellation — only on
    ///   a genuine launch/process failure, matching the previous runner's
    ///   contract.
    func run(arguments: [String], operationID: UUID, ownsOperationLifecycle: Bool = true) async throws -> Result {
        do {
            let result = try await transport.run(
                arguments: arguments,
                isCancelled: { await OperationCenterCLIBridge.isOperationCancelled(operationID) },
                onEvent: OperationCenterCLIBridge.onEvent(operationID: operationID)
            )
            guard let outputPath = result.outputs.first,
                  !outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                let message = "lungfish-cli finished without reporting an MSA action output."
                if ownsOperationLifecycle {
                    await OperationCenterCLIBridge.failOperation(operationID, detail: message, fallbackMessage: message)
                }
                throw RunError.underlying(message)
            }
            let outputURL = URL(fileURLWithPath: outputPath, isDirectory: Self.isNativeBundlePath(outputPath))
            if ownsOperationLifecycle {
                if Self.isNativeBundleURL(outputURL) {
                    await OperationCenterCLIBridge.completeOperation(
                        operationID,
                        detail: "MSA action complete",
                        bundleURLs: [outputURL]
                    )
                } else {
                    await OperationCenterCLIBridge.completeOperation(
                        operationID,
                        detail: "MSA action complete",
                        outputURLs: [outputURL]
                    )
                }
                if await OperationCenterCLIBridge.isOperationCancelled(operationID) {
                    throw CancellationError()
                }
            }
            return Result(outputURL: outputURL)
        } catch is CancellationError {
            if ownsOperationLifecycle {
                await OperationCenterCLIBridge.acknowledgeCancellation(operationID)
            }
            throw CancellationError()
        } catch let error as CLISubprocessTransport.RunError {
            let message = error.errorDescription ?? "MSA action failed"
            if ownsOperationLifecycle {
                await OperationCenterCLIBridge.failOperation(operationID, detail: message, fallbackMessage: message)
            }
            throw RunError.underlying(message)
        }
    }

    func cancel() {
        transport.cancel()
    }

    private static func isNativeBundlePath(_ path: String) -> Bool {
        isNativeBundleExtension(URL(fileURLWithPath: path).pathExtension)
    }

    private static func isNativeBundleURL(_ url: URL) -> Bool {
        isNativeBundleExtension(url.pathExtension)
    }

    private static func isNativeBundleExtension(_ pathExtension: String) -> Bool {
        switch pathExtension.lowercased() {
        case "lungfishmsa", "lungfishref", "lungfishtree":
            return true
        default:
            return false
        }
    }
}
