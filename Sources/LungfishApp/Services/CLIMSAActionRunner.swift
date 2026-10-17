// CLIMSAActionRunner.swift — Runs `lungfish-cli msa <action>` through CLISubprocessTransport.
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// Runs any `lungfish-cli msa` action subcommand (annotate/export/consensus/
/// extract/mask/trim/distance/…) as a subprocess, decoding the shared
/// `CLIEvent` schema instead of the private `msaAction*` JSON shape this
/// runner used to hand-parse. All call sites only ever
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

    /// The time the command has between SIGTERM and SIGKILL to end the action and record its cancelled
    /// run, the launcher's ``CLIProcessLauncher/operationGrace`` (Phase 2.11 lane S61).
    static let terminationGracePeriod = CLIProcessLauncher.operationGrace
    /// How long the run waits for a descendant that holds the command's output open after the
    /// command exited, the launcher's ``CLIProcessLauncher/operationDrain``.
    static let drainGracePeriod = CLIProcessLauncher.operationDrain

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
                terminationGracePeriod: Self.terminationGracePeriod,
                drainGracePeriod: Self.drainGracePeriod,
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

    /// Stops the command, whether it is running or about to start. It returns at once, from any thread.
    nonisolated func cancel() {
        transport.cancel()
    }

    private static func isNativeBundlePath(_ path: String) -> Bool {
        isNativeBundleExtension(URL(fileURLWithPath: path).pathExtension)
    }

    private static func isNativeBundleURL(_ url: URL) -> Bool {
        isNativeBundleExtension(url.pathExtension)
    }

    /// The bundle kinds an `msa` action can return as its output. A run that returns one of them
    /// completes with a bundle URL, and every other output completes as a plain file URL.
    private static let nativeBundleOutputKinds: Set<BundleKindID> = [
        .multipleSequenceAlignment, .reference, .phylogeneticTree,
    ]

    /// Reads the kind through the registry's lowercased lookup, as this runner always lowercased the extension.
    private static func isNativeBundleExtension(_ pathExtension: String) -> Bool {
        guard let kind = BundleKindRegistry.descriptor(forLowercasedExtension: pathExtension)?.id else {
            return false
        }
        return nativeBundleOutputKinds.contains(kind)
    }
}
