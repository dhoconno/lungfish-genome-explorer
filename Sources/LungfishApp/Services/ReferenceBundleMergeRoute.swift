// ReferenceBundleMergeRoute.swift - The sidebar's reference bundle merge, run as lungfish-cli bundle merge
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

/// Runs the sidebar's Merge into New Bundle for reference bundles as `lungfish-cli bundle merge` (Phase 2.11
/// lane A49 M2, plan decisions C4 and C5), on `CLIBundleBuildRunner`, for the app's Operations row.
///
/// The command stages the merged bundle in the project's `.tmp` folder, publishes it under its name with one
/// rename and writes its record, and the app writes nothing after it exits. The row keeps the words it had
/// when the merge ran in the app, and records the command. Cancel goes through the transport, so the command
/// gets SIGTERM and the runner's grace to stop before it publishes.
///
/// The parity of the in-process merge and the command declares no difference
/// (`ReferenceBundleMergeParityReplayTests`), so the route keeps no hidden key and no in-process row (plan C4).
enum ReferenceBundleMergeRoute {
    /// What a run of the command gives back to the row, the bundles it published and its `complete` message.
    struct Run: Sendable {
        let outputs: [String]
        let message: String?
    }

    /// Runs `arguments`, the argv after `lungfish-cli`, for the row `operationID`.
    typealias Launch = @MainActor (_ arguments: [String], _ operationID: UUID) async throws -> Run

    struct RouteError: LocalizedError {
        var errorDescription: String? { "The merge command did not name the merged bundle." }
    }

    /// The argv after `lungfish-cli` that merges `sourceBundleURLs` into `outputDirectory`. A name the person
    /// typed is passed as one `--name=` word, so a name that starts with a hyphen stays a value.
    static func arguments(sourceBundleURLs: [URL], outputDirectory: URL, bundleName: String) -> [String] {
        ["bundle", "merge"] + sourceBundleURLs.map(\.path)
            + ["--name=\(bundleName)", "--output-directory", outputDirectory.path, "--format", "json"]
    }

    /// The command on `CLIBundleBuildRunner`, whose Cancel goes through the transport.
    static let launchCommand: Launch = { arguments, operationID in
        let result = try await CLIBundleBuildRunner.launch(arguments: arguments, operationID: operationID)
        return Run(outputs: result.outputs, message: result.message)
    }

    /// Merges the bundles and returns the merged bundle, throwing `OperationRefusedError`, having written
    /// nothing, when the row is refused, and `CancellationError` once a cancel is acknowledged on the row.
    @MainActor
    static func merge(
        sourceBundleURLs: [URL],
        outputDirectory: URL,
        bundleName: String,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: Launch = ReferenceBundleMergeRoute.launchCommand
    ) async throws -> URL {
        let arguments = Self.arguments(sourceBundleURLs: sourceBundleURLs, outputDirectory: outputDirectory, bundleName: bundleName)
        let command = OperationCenter.buildCLICommand(subcommand: "bundle merge", args: Array(arguments.dropFirst(2)))
        let operationID = try reporter.begin(
            title: "Merge Reference Bundles",
            detail: "Preparing to merge \(sourceBundleURLs.count) reference bundles\u{2026}",
            operationType: .bundleBuild,
            cliCommand: command
        ).requireStarted()
        reporter.log(
            id: operationID,
            level: .info,
            message: "Merging \(sourceBundleURLs.count) reference bundles into \"\(bundleName)\"."
        )
        do {
            let run = try await launch(arguments, operationID)
            guard let path = run.outputs.first else { throw RouteError() }
            let mergedURL = URL(fileURLWithPath: path, isDirectory: true)
            reporter.log(id: operationID, level: .info, message: "Merged bundle written to \(mergedURL.lastPathComponent).")
            reporter.complete(
                id: operationID,
                detail: run.message ?? "Merged \(sourceBundleURLs.count) reference bundles",
                bundleURLs: [mergedURL]
            )
            return mergedURL
        } catch is CancellationError {
            // The runner acknowledged the cancel on the row, and the command published nothing.
            throw CancellationError()
        } catch {
            reporter.log(
                id: operationID,
                level: .error,
                message: "Reference bundle merge failed: \(error.localizedDescription)"
            )
            reporter.fail(
                id: operationID,
                detail: "Reference bundle merge failed",
                errorMessage: error.localizedDescription
            )
            throw error
        }
    }
}
