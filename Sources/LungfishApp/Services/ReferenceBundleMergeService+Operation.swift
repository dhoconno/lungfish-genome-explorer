// ReferenceBundleMergeService+Operation.swift - The merge's row in the Operations panel
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

extension ReferenceBundleMergeService {
    /// Reports the run through `reporter`, and throws `OperationRefusedError`,
    /// having written nothing, when `begin` is refused.
    @MainActor
    static func merge(
        sourceBundleURLs: [URL],
        outputDirectory: URL,
        bundleName: String,
        reporter: any OperationReporting = OperationCenter.shared
    ) async throws -> URL {
        let operationID = try reporter.begin(
            title: "Merge Reference Bundles",
            detail: "Preparing to merge \(sourceBundleURLs.count) reference bundles\u{2026}",
            operationType: .bundleBuild,
            cliCommand: nil // cli-parity-gap: reference-bundle-merge. No command merges bundles. The closest is `bundle create`.
        ).requireStarted()
        reporter.log(
            id: operationID,
            level: .info,
            message: "Merging \(sourceBundleURLs.count) reference bundles into \"\(bundleName)\"."
        )

        // The progress sink is the ONLY thing that touches the main actor. Everything else
        // runs on the cooperative pool -- see `runDetached`.
        let progressReporter = ProgressReporter { progress, detail, log in
            await MainActor.run {
                _ = reporter.update(id: operationID, progress: progress, detail: detail)
                if let log {
                    reporter.log(id: operationID, level: log.level == .warning ? .warning : .info, message: log.message)
                }
            }
        }

        do {
            let mergedURL = try await runDetached(
                sourceBundleURLs: sourceBundleURLs,
                outputDirectory: outputDirectory,
                bundleName: bundleName,
                provenanceWriter: .live,
                reporter: progressReporter
            )
            reporter.log(
                id: operationID,
                level: .info,
                message: "Merged bundle written to \(mergedURL.lastPathComponent)."
            )
            reporter.complete(
                id: operationID,
                detail: "Merged \(sourceBundleURLs.count) reference bundles",
                bundleURLs: [mergedURL]
            )
            return mergedURL
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
