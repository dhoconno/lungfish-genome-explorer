// Kraken2AnalysisRunTool+Finalize.swift - The run-level artifacts of a Kraken2 run (phase P3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension CLIEventArtifact.Role {
    /// Kraken2's report of a sample, `classification.kreport`.
    public static let classificationReport = "classification-report"
    /// Kraken2's per-read output, compressed.
    public static let classificationOutput = "classification-output"
    /// Bracken's abundance profile.
    public static let brackenProfile = "bracken-profile"
    /// `classification-result.json`, which the viewer loads.
    public static let classificationResult = "classification-result"
    /// The viewer's index of the result, such as `kraken2.sqlite`.
    public static let classificationDatabase = "classification-database"
    /// A batch's summary table.
    public static let batchSummary = "batch-summary"
    /// A batch's manifest.
    public static let batchManifest = "batch-manifest"
}

extension Kraken2AnalysisRunTool {
    /// The batch summary table's name, as the app has always written it.
    public static let batchSummaryFilename = "classification-batch-summary.tsv"

    /// The warning of a batch whose viewer index could not be built, as the app has always
    /// logged it (`AppDelegate.classificationDatabaseBuildWarning`).
    public static func batchIndexWarning(_ detail: String) -> String {
        "Database build failed: \(detail) \u{2014} batch will rebuild lazily on open"
    }

    /// The batch row's detail while the viewer index builds, as EsViritu's finalize reports
    /// `Building EsViritu database…`. The app's row logs today's `Building kraken2.sqlite from N
    /// sample(s)` line itself.
    public static let batchIndexMessage = "Building Kraken2 database\u{2026}"

    /// Phase P3. A plain one-folder result keeps today's command-line set. A `--project` result
    /// also gets the viewer index and the source bundle record (UX D19). A batch root always gets
    /// the summary table, the manifest and the viewer index over its completed samples. Under
    /// `--project` each completed sample's bundle records the batch, with the app's words.
    public func finalize(
        _ units: [AnalysisUnitReport<Kraken2UnitResult>],
        context: AnalysisRunFinalizeContext
    ) async throws -> AnalysisRunFinalization {
        switch context.layout {
        case .batchRoot:
            return try await finalizeBatch(units, context: context)
        case .singleFolder, .sharedBatchRoot:
            return try await finalizeOneFolder(units, context: context)
        }
    }

    private func finalizeOneFolder(
        _ units: [AnalysisUnitReport<Kraken2UnitResult>],
        context: AnalysisRunFinalizeContext
    ) async throws -> AnalysisRunFinalization {
        guard let unitResult = units.lazy.compactMap({ $0.outcome.result }).first else {
            throw Kraken2RunRefusal(message: "No sample completed.", exitCode: AnalysisRunExitCode.workflowError)
        }
        let result = unitResult.result
        let metadata = ClassificationBatchOutcomePolicy.singleResultMetadata(for: result)
        var finalization = AnalysisRunFinalization(
            outputs: Kraken2RunRecordOptions.outputs(for: result),
            artifacts: Self.artifacts(for: result),
            completionDetail: metadata.completionDetail
        )
        guard unitResult.destinationIsProject else { return finalization }
        do {
            try await add(context.buildIndex(), to: &finalization)
        } catch {
            finalization.warnings.append(
                "The viewer index could not be built: \(error.localizedDescription). The viewer builds it when the result opens."
            )
        }
        if let bundle = unitResult.sourceBundle {
            finalization.sourceRecords = [AnalysisManifestSourceRecord(
                bundleURL: bundle,
                displayName: "Kraken2 Classification",
                parameters: metadata.analysisParameters,
                summary: metadata.analysisSummary
            )]
        }
        return finalization
    }

    private func finalizeBatch(
        _ units: [AnalysisUnitReport<Kraken2UnitResult>],
        context: AnalysisRunFinalizeContext
    ) async throws -> AnalysisRunFinalization {
        let root = context.rootDirectory
        let completed = units.compactMap { report in report.outcome.result.map { (report: report, value: $0) } }
        guard let first = completed.first?.value.result.config else {
            throw Kraken2RunRefusal(message: "No sample completed.", exitCode: AnalysisRunExitCode.workflowError)
        }
        let returnedRows = completed.map { ClassificationBatchOutcomePolicy.row(sampleId: $0.report.sampleName, result: $0.value.result) }
        let failedRows = units.compactMap { report -> ClassificationBatchSummaryRow? in
            guard case .failed(let reason) = report.outcome else { return nil }
            return ClassificationBatchOutcomePolicy.failedRow(sampleId: report.sampleName, message: reason)
        }
        let rows = returnedRows + failedRows
        let evaluation = ClassificationBatchOutcomePolicy.evaluate(rows: rows, sqliteWarning: nil)
        let summaryURL = root.appendingPathComponent(Self.batchSummaryFilename)
        let manifest = ClassificationBatchResultManifest(
            header: MetagenomicsBatchManifestHeader(schemaVersion: 2, createdAt: Date(), sampleCount: units.count),
            goal: first.goal.rawValue,
            databaseName: first.databaseName,
            databaseVersion: first.databaseVersion,
            summaryTSV: summaryURL.lastPathComponent,
            samples: zip(completed, returnedRows).map { item, row in
                MetagenomicsBatchSampleRecord(
                    sampleId: item.report.sampleName,
                    resultDirectory: item.report.directory.lastPathComponent,
                    inputFiles: item.value.inputURLs.map(\.path),
                    isPairedEnd: item.value.result.config.isPairedEnd,
                    status: row.status,
                    message: row.message.isEmpty ? nil : row.message
                )
            },
            completedCount: evaluation.completedCount,
            degradedCount: evaluation.degradedCount,
            failedCount: evaluation.failedCount
        )
        try ClassificationBatchOutcomePolicy.summaryTSV(rows: rows).write(to: summaryURL, atomically: true, encoding: .utf8)
        try MetagenomicsBatchResultStore.saveClassification(manifest, to: root)
        let manifestURL = root.appendingPathComponent(ClassificationBatchResultManifest.filename)

        var finalization = AnalysisRunFinalization(
            outputs: [
                AnalysisRunOutput(url: summaryURL, format: .text, role: .report),
                AnalysisRunOutput(url: manifestURL, format: .json, role: .report),
            ],
            artifacts: [
                CLIEventArtifact(kind: "tsv", path: summaryURL.path, role: CLIEventArtifact.Role.batchSummary),
                CLIEventArtifact(kind: "json", path: manifestURL.path, role: CLIEventArtifact.Role.batchManifest),
            ]
        )
        var indexError: String?
        context.progress(Self.batchIndexMessage)
        do {
            try await add(context.buildIndex(), to: &finalization)
        } catch {
            indexError = error.localizedDescription
            finalization.warnings.append(Self.batchIndexWarning(error.localizedDescription))
        }
        finalization.completionDetail = ClassificationCompletionDetail.kraken2Batch(
            successCount: completed.count,
            sampleCount: units.count,
            evaluation: ClassificationBatchOutcomePolicy.evaluate(rows: rows, sqliteWarning: indexError)
        )
        // Only a result in a project goes into its inputs' analysis history, as for one folder.
        guard completed.contains(where: { $0.value.destinationIsProject }) else { return finalization }
        finalization.sourceRecords = completed.compactMap { item in
            item.value.sourceBundle.map { bundle in
                let metadata = ClassificationBatchOutcomePolicy.singleResultMetadata(for: item.value.result)
                return AnalysisManifestSourceRecord(
                    bundleURL: bundle,
                    displayName: "Kraken2 Batch",
                    parameters: metadata.analysisParameters,
                    summary: metadata.analysisSummary
                )
            }
        }
        return finalization
    }

    /// Copies an index build's outputs, steps and warnings into the finalization, so the root
    /// record names the index.
    private func add(_ index: AnalysisResultIndex, to finalization: inout AnalysisRunFinalization) {
        finalization.outputs += index.outputs
        finalization.steps += index.steps
        finalization.warnings += index.warnings
        finalization.artifacts += index.outputs.map {
            CLIEventArtifact(kind: "sqlite", path: $0.url.path, role: CLIEventArtifact.Role.classificationDatabase)
        }
    }

    /// The typed artifacts of a one-folder result's `complete` event.
    static func artifacts(for result: ClassificationResult) -> [CLIEventArtifact] {
        var artifacts = [
            CLIEventArtifact(kind: "kreport", path: result.reportURL.path, role: CLIEventArtifact.Role.classificationReport),
            CLIEventArtifact(kind: "kraken", path: result.outputURL.path, role: CLIEventArtifact.Role.classificationOutput),
        ]
        if let bracken = result.brackenURL {
            artifacts.append(CLIEventArtifact(kind: "bracken", path: bracken.path, role: CLIEventArtifact.Role.brackenProfile))
        }
        let sidecar = result.config.outputDirectory.appendingPathComponent(ClassificationResult.sidecarFilename)
        artifacts.append(CLIEventArtifact(kind: "json", path: sidecar.path, role: CLIEventArtifact.Role.classificationResult))
        return artifacts.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
