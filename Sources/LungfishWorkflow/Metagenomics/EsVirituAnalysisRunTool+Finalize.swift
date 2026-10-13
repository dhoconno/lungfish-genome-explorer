// EsVirituAnalysisRunTool+Finalize.swift - The run-level artifacts of an EsViritu run, phase P3
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension EsVirituAnalysisRunTool {
    /// Writes what the app's EsViritu runs write at the end of a run.
    ///
    /// A one-folder result, a plain `--output` run, keeps the files `esviritu detect` has always
    /// left (E2), and the root record names EsViritu's tables and the result sidecar as its outputs.
    /// A batch root, a `--project` or `--batch` run, gets the batch summary, the batch manifest and
    /// `esviritu.sqlite` through the index builder (E6), and each sample's source bundle gets the
    /// entry the app writes, in the app's words. A database that cannot be built is a warning of
    /// the run, which still completes, as in the app.
    public func finalize(
        _ units: [AnalysisUnitReport<EsVirituSampleResult>],
        context: AnalysisRunFinalizeContext
    ) async throws -> AnalysisRunFinalization {
        let completed = units.compactMap { report in report.outcome.result.map { (report: report, sample: $0) } }
        switch context.layout {
        case .singleFolder, .sharedBatchRoot:
            guard let sample = completed.first?.sample else {
                return AnalysisRunFinalization()
            }
            return AnalysisRunFinalization(
                outputs: Self.sampleOutputs(of: sample.result),
                artifacts: [
                    CLIEventArtifact(kind: "esviritu-detections", path: sample.result.detectionURL.path, role: ArtifactRole.detections),
                    CLIEventArtifact(
                        kind: "esviritu-result",
                        path: sample.config.outputDirectory.appendingPathComponent("esviritu-result.json").path,
                        role: ArtifactRole.resultSidecar
                    ),
                ],
                completionDetail: ClassificationCompletionDetail.esVirituDetection(
                    virusCount: sample.detectionCount,
                    familyCount: sample.familyCount
                )
            )
        case .batchRoot:
            return try await finalizeBatchRoot(units, completed: completed.map(\.sample), context: context)
        }
    }

    private func finalizeBatchRoot(
        _ units: [AnalysisUnitReport<EsVirituSampleResult>],
        completed: [EsVirituSampleResult],
        context: AnalysisRunFinalizeContext
    ) async throws -> AnalysisRunFinalization {
        let root = context.rootDirectory
        context.progress("Writing the EsViritu batch summary\u{2026}")
        let summaryURL = root.appendingPathComponent(Self.summaryFilename)
        try Self.summaryText(for: units).write(to: summaryURL, atomically: true, encoding: .utf8)

        let manifest = EsVirituBatchResultManifest(
            header: MetagenomicsBatchManifestHeader(schemaVersion: 1, createdAt: Date(), sampleCount: units.count),
            summaryTSV: summaryURL.lastPathComponent,
            samples: completed.map { sample in
                MetagenomicsBatchSampleRecord(
                    sampleId: sample.config.outputDirectory.lastPathComponent,
                    resultDirectory: sample.config.outputDirectory.lastPathComponent,
                    inputFiles: sample.inputs.map(\.path),
                    isPairedEnd: sample.config.readFormat.runsAsPairs
                )
            }
        )
        try MetagenomicsBatchResultStore.saveEsViritu(manifest, to: root)
        let manifestURL = root.appendingPathComponent(EsVirituBatchResultManifest.filename)

        var outputs = [
            AnalysisRunOutput(url: summaryURL, format: .text),
            AnalysisRunOutput(url: manifestURL, format: .json),
        ]
        var artifacts = [
            CLIEventArtifact(kind: "tsv", path: summaryURL.path, role: ArtifactRole.batchSummary),
            CLIEventArtifact(kind: "json", path: manifestURL.path, role: ArtifactRole.batchManifest),
        ]
        var warnings: [String] = []
        if !completed.isEmpty {
            context.progress("Building EsViritu database\u{2026}")
            do {
                // The build's steps reach the root record through the context as the build ends.
                let index = try await context.buildIndex()
                outputs += index.outputs
                warnings += index.warnings
                if let database = index.outputs.first {
                    artifacts.insert(
                        CLIEventArtifact(kind: "esviritu-database", path: database.url.path, role: ArtifactRole.database),
                        at: 0
                    )
                }
            } catch {
                // The words of the app's row, whose batch view builds the database when it opens.
                warnings.append("Database build failed: \(error.localizedDescription) \u{2014} batch will rebuild lazily on open")
            }
        }

        let failureCount = units.count - completed.count
        return AnalysisRunFinalization(
            outputs: outputs,
            sourceRecords: sourceRecords(for: completed, root: root, projectURL: context.projectURL),
            artifacts: artifacts,
            completionDetail: groupsSamples
                ? ClassificationCompletionDetail.esVirituBatch(
                    successCount: completed.count,
                    failureCount: failureCount,
                    sampleCount: units.count
                )
                : ClassificationCompletionDetail.esVirituDetection(
                    virusCount: completed.first?.detectionCount ?? 0,
                    familyCount: completed.first?.familyCount ?? 0
                ),
            warnings: warnings
        )
    }

    /// The batch summary as the app writes it, a row for each sample that completed and then one
    /// for each that failed, joined without a final line break.
    static func summaryText(for units: [AnalysisUnitReport<EsVirituSampleResult>]) -> String {
        var lines = ["sample_id\tstatus\tvirus_count\tfamilies\tspecies\terror"]
        for report in units {
            guard let sample = report.outcome.result else { continue }
            lines.append([
                ClassificationBatchOutcomePolicy.tsvField(report.sampleName),
                "ok",
                String(sample.result.virusCount),
                String(sample.familyCount),
                String(sample.speciesCount),
                "",
            ].joined(separator: "\t"))
        }
        for report in units {
            guard case .failed(let reason) = report.outcome else { continue }
            lines.append([
                ClassificationBatchOutcomePolicy.tsvField(report.sampleName),
                "failed",
                "",
                "",
                "",
                ClassificationBatchOutcomePolicy.tsvField(reason),
            ].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    /// EsViritu's tables and the result sidecar, in the order the pipeline's record lists them.
    static func sampleOutputs(of result: EsVirituResult) -> [AnalysisRunOutput] {
        let tables = [result.detectionURL, result.assemblyURL, result.taxProfileURL, result.coverageURL].compactMap { $0 }
        return tables.map { AnalysisRunOutput(url: $0, format: .text) }
            + [AnalysisRunOutput(url: result.config.outputDirectory.appendingPathComponent("esviritu-result.json"), format: .json)]
    }

    /// The source bundle entries of a batch root, in the app's words. A run of one sample names its
    /// sample folder, as the app's EsViritu run does, and a `--batch` run names the batch root, as
    /// the app's EsViritu batch does.
    private func sourceRecords(
        for completed: [EsVirituSampleResult],
        root: URL,
        projectURL: URL?
    ) -> [any AnalysisSourceRecord] {
        completed.compactMap { sample -> (any AnalysisSourceRecord)? in
            guard let bundleURL = Self.sourceBundle(for: sample.inputs) else { return nil }
            if groupsSamples {
                return EsVirituSourceRecord(
                    bundleURL: bundleURL,
                    sampleFolder: nil,
                    displayName: "EsViritu Batch",
                    parameters: sample.config.summaryParameters(),
                    summary: "\(sample.detectionCount) viruses in \(sample.familyCount) families"
                )
            }
            return EsVirituSourceRecord(
                bundleURL: bundleURL,
                sampleFolder: sample.config.outputDirectory.lastPathComponent,
                displayName: "EsViritu Detection",
                parameters: sample.config.summaryParameters(),
                summary: "\(sample.detectionCount) viruses detected in \(sample.familyCount) families"
            )
        }
    }

    /// The bundle a sample's inputs come from, a FASTQ bundle or a reference bundle, as the app finds it.
    static func sourceBundle(for inputs: [URL]) -> URL? {
        for url in inputs {
            if let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: url) {
                return bundleURL
            }
            if let referenceBundleURL = SequenceInputResolver.enclosingReferenceBundleURL(for: url) {
                return referenceBundleURL
            }
        }
        return nil
    }
}

/// An `analyses-manifest.json` entry of an EsViritu run. A run of one sample in a batch root names
/// its sample folder, `<batch root>/<sample>`, as the app's EsViritu run always has.
struct EsVirituSourceRecord: AnalysisSourceRecord {
    let bundleURL: URL
    /// The sample folder the entry names inside the result folder, or nil for the result folder.
    let sampleFolder: String?
    let displayName: String
    let parameters: [String: AnalysisParameterValue]
    let summary: String

    func write(_ context: AnalysisSourceRecordContext) throws {
        var directoryName = context.analysisDirectoryName
        if let sampleFolder {
            let folder = context.analysisDirectory.appendingPathComponent(sampleFolder, isDirectory: true)
            directoryName = context.projectURL.flatMap {
                AnalysisManifestStore.analysisDirectoryPath(for: folder, projectURL: $0)
            } ?? folder.lastPathComponent
        }
        try AnalysisManifestStore.recordAnalysis(
            AnalysisManifestEntry(
                tool: context.toolID.rawValue,
                analysisDirectoryName: directoryName,
                displayName: displayName,
                parameters: parameters,
                summary: summary,
                status: .completed
            ),
            bundleURL: bundleURL
        )
    }
}
