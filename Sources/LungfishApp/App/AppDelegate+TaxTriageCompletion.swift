// AppDelegate+TaxTriageCompletion.swift - The end of a TaxTriage run, moved out of AppDelegate+Classification.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishIO
import LungfishKit
import LungfishWorkflow
import os

/// The end of a TaxTriage launch lives here, so that AppDelegate+Classification.swift, which is at
/// its size baseline, does not hold it. `completeTaxTriageRun` builds the database and finishes the
/// row, `finishTaxTriageOperation` logs the run's warnings and moves the row to its terminal state,
/// and `writeTaxTriageCrossRefSidecars` writes the cross-reference files into the source bundles.
extension AppDelegate {
    /// The end of a TaxTriage launch. It builds the database from the finished run's outputs,
    /// completes the provenance record, then finishes the row and writes its follow-ups on the
    /// main actor. It runs on the launch's detached task, off the main actor.
    nonisolated static func completeTaxTriageRun(
        opID: UUID,
        result: TaxTriageResult,
        config: TaxTriageConfig,
        routeContext: OperationRouteContext?,
        viewerController: ViewerViewController,
        materializeTempDir: URL
    ) async throws {
        // Build the SQLite database from the Nextflow outputs before the
        // operation completes, so the batch can be opened immediately.
        var dbBuildErrorDescription: String?
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // The runner reported 1.0 when its last sample ended, and a bar never moves back,
                // so the database build keeps the bar there when the row already shows more than 0.95.
                let shown = OperationCenter.shared.items.first { $0.id == opID }?.progress ?? 0
                _ = OperationCenter.shared.update(
                    id: opID,
                    progress: max(shown, 0.95),
                    detail: "Building TaxTriage database\u{2026}"
                )
                OperationCenter.shared.log(id: opID, level: .info, message: "Building taxtriage.sqlite from TaxTriage outputs")
            }
        }
        do {
            try await LungfishCLIRunner.buildClassifierDatabase(tool: "taxtriage", resultURL: result.outputDirectory, force: true)
        } catch {
            dbBuildErrorDescription = error.localizedDescription
            appDelegateLogger.warning(
                "runTaxTriage: Failed to build taxtriage.sqlite - \(error.localizedDescription, privacy: .public)"
            )
        }

        _ = try MetagenomicsBatchProvenanceWriter.ensureTaxTriageProvenanceIfPossible(
            resultDirectory: result.outputDirectory
        )

        // Covered by the `defer` from creation; do not fail
        // an otherwise-successful run over a cleanup error.
        try? FileManager.default.removeItem(at: materializeTempDir)
        let capturedResult = result
        let capturedConfig = config
        let capturedDBBuildError = dbBuildErrorDescription
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                viewerController.hideProgress()
                if let dbError = capturedDBBuildError {
                    OperationCenter.shared.log(
                        id: opID,
                        level: .warning,
                        message: Self.classificationDatabaseBuildWarning(dbError)
                    )
                }
                Self.writeTaxTriageCrossRefSidecars(result: capturedResult, config: capturedConfig)
                guard Self.finishTaxTriageOperation(
                    id: opID,
                    result: capturedResult,
                    center: OperationCenter.shared
                ) else { return }
                // Write cross-reference sidecars into each source bundle so
                // the sidebar discovers TaxTriage results under all contributors.

                // Record in batch run history log
                BatchRunHistory.recordRun(result: capturedResult, config: capturedConfig)

                // Reload sidebar so the new result bundle appears
                AppDelegate.shared?.targetMainWindowController(routeContext: routeContext)?
                    .mainSplitViewController?
                    .sidebarController.requestReloadFromFilesystem()

                // Record analysis in source bundle manifests
                for sample in capturedConfig.samples {
                    if let bundleURL = Self.findSourceBundle(for: [sample.fastq1] + (sample.fastq2.map { [$0] } ?? [])) {
                        let entry = AnalysisManifestEntry(
                            tool: "taxtriage",
                            analysisDirectoryName: Self.analysisManifestDirectoryName(
                                for: capturedConfig.outputDirectory,
                                projectURL: routeContext?.projectURL
                            ),
                            displayName: "TaxTriage Classification",
                            parameters: capturedConfig.summaryParameters(),
                            summary: capturedResult.summary,
                            status: .completed
                        )
                        do { try AnalysisManifestStore.recordAnalysis(entry, bundleURL: bundleURL) } catch { appDelegateLogger.warning("Failed to record analysis manifest: \(error.localizedDescription, privacy: .public)") }
                    }
                }
            }
        }
    }

    /// Logs a finished TaxTriage run's errored tasks and failed samples and
    /// moves its operation to a terminal state.
    ///
    /// Nextflow exits 0 when TaxTriage ignores an errored task (for example
    /// MINIMAP2_ALIGN killed for memory), so a run with errored tasks or failed
    /// samples finishes with a warning ("Completed with Warnings") whose
    /// detail names the process, never as a plain "Completed".
    ///
    /// - Returns: `false` when the operation was no longer active (cancelled).
    @MainActor
    @discardableResult
    static func finishTaxTriageOperation(
        id opID: UUID,
        result: TaxTriageResult,
        center: OperationCenter
    ) -> Bool {
        if let erroredProcessesMessage = result.erroredProcessesMessage {
            center.log(id: opID, level: .warning, message: erroredProcessesMessage)
        }
        if result.hasSampleFailures {
            let preview = result.sampleFailures
                .prefix(5)
                .map { failure in "\(failure.sampleID): \(failure.errorDescription)" }
                .joined(separator: "; ")
            let suffix = result.sampleFailures.count > 5
                ? "; +\(result.sampleFailures.count - 5) more"
                : ""
            center.log(
                id: opID,
                level: .warning,
                message: "\(result.sampleFailures.count) TaxTriage samples failed (\(preview)\(suffix))"
            )
        }

        var warningSummaries: [String] = []
        if let headline = result.erroredProcessesHeadline {
            warningSummaries.append(headline)
        }
        if result.hasSampleFailures {
            warningSummaries.append("\(result.sampleFailures.count) failed samples")
        }
        guard result.completedWithErrors, !warningSummaries.isEmpty else {
            return center.complete(id: opID, detail: result.summary)
        }
        let detail = "\(warningSummaries.joined(separator: "; ")) (\(result.reportFiles.count) reports)"
        return center.completeWithWarning(id: opID, detail: detail)
    }

    /// Writes TaxTriage cross-reference sidecars into each source bundle directory.
    ///
    /// After a multi-sample TaxTriage batch run, each contributing source bundle
    /// gets a `taxtriage-ref-{runId}.json` so the sidebar can discover the result
    /// under every bundle, not just the one containing the output directory.
    private static func writeTaxTriageCrossRefSidecars(result: TaxTriageResult, config: TaxTriageConfig) {
        guard let sourceBundleURLs = result.sourceBundleURLs, sourceBundleURLs.count > 1 else { return }

        let runId = result.outputDirectory.lastPathComponent
        let now = Date()

        for (index, bundleURL) in sourceBundleURLs.enumerated() {
            // Determine which sample(s) came from this bundle
            let sampleId: String
            if index < config.samples.count {
                sampleId = config.samples[index].sampleId
            } else {
                sampleId = "sample-\(index)"
            }

            let ref = TaxTriageCrossRef(
                resultDirectory: result.outputDirectory.path,
                runId: runId,
                sampleId: sampleId,
                createdAt: now,
                batchSampleCount: config.samples.count
            )

            do {
                try MetagenomicsBatchResultStore.saveTaxTriageRef(ref, to: bundleURL)
                debugLog("Wrote TaxTriage cross-ref sidecar to \(bundleURL.lastPathComponent) for sample \(sampleId)")
            } catch {
                debugLog("Failed to write TaxTriage cross-ref to \(bundleURL.lastPathComponent): \(error)")
            }
        }
    }
}
