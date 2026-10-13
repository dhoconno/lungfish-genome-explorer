// TaxTriageAnalysisRunTool+Finalize.swift - The run-level artifacts of a TaxTriage run on the executor (phase P3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension TaxTriageAnalysisRunTool {
    /// The words of the bar while the finalize builds the viewer index, as the app's TaxTriage row has them.
    static let databaseStageMessage = "Building TaxTriage database\u{2026}"

    /// The finalize's share of the progress range, the descriptor's (W3). The engine moves the bar to 0.9
    /// and the viewer index takes it from there to the end.
    package var finalizeProgressShare: Double {
        NextflowWorkflowDescriptor.taxTriage.finalizeProgressShare
    }

    /// Phase P3. A result folder's launch already handed its step, with the digests of its outputs, to
    /// the root record. A batch root's samples each keep their own record, so the root names each
    /// completed sample's outputs with the digest and size that record took, and hashes nothing again
    /// (S2). Those the cleanup then removes drop out of the run level, which names only kept files.
    ///
    /// A result in a project or a batch root then gets its viewer index in process, `taxtriage.sqlite`
    /// through the index builder the executor was given. The build's steps and the recorded removal
    /// step of its cleanup reach the root record through the context as the build ends (2.9 R6). The
    /// cleanup keeps `top/` (2.8 T5 and row 258, B12 M2) and names each removed file with the digest
    /// a record already holds (T5 as amended in 2.9). A plain `--output` keeps its folder as the
    /// command has always left it, with no index and no cleanup, as a Kraken2 result outside a
    /// project does. An index that cannot be built leaves a warning and the result, since the viewer
    /// builds the index when the result opens.
    ///
    /// Each completed sample of a `--project` result then records the run in its source bundle's
    /// analysis history (``sourceRecords(for:context:destinationIsProject:)``, X4), which the executor
    /// writes after the root record.
    package func finalize(
        _ units: [AnalysisUnitReport<TaxTriageUnitResult>],
        context: AnalysisRunFinalizeContext
    ) async throws -> AnalysisRunFinalization {
        var finalization = AnalysisRunFinalization()
        if context.layout == .batchRoot {
            finalization.recordedFiles = units
                .filter { $0.outcome.result != nil }
                .compactMap { ProvenanceRecorder.loadEnvelope(from: $0.directory)?.outputs }
                .flatMap { $0 }
        }
        guard context.layout != .singleFolder else { return finalization }

        context.progress(0, Self.databaseStageMessage)
        do {
            // T5 as amended. The cleanup names each file it removes with the digest a record already
            // holds, the steps the units handed to the root record or a batch sample's own record,
            // which the cleanup reads in the sample's folder. It hashes nothing.
            let recorded = context.recordedSteps.flatMap { $0.inputs + $0.outputs }
            let index = try await context.buildIndex(recordedFiles: recorded)
            finalization.outputs += index.outputs
            finalization.warnings += index.warnings
        } catch {
            finalization.warnings.append(
                "The viewer index could not be built: \(error.localizedDescription). The viewer builds it when the result opens."
            )
        }
        finalization.sourceRecords = Self.sourceRecords(
            for: units,
            context: context,
            destinationIsProject: request.destinationIsProject
        )
        context.progress(1, Self.databaseStageMessage)
        return finalization
    }

    // MARK: - Source bundles (X4)

    /// The name of the run in a source bundle's analysis history, the one the app's TaxTriage run writes.
    static let sourceRecordDisplayName = "TaxTriage Classification"

    /// X4, as Kraken2's finalize records a result in a project. Each completed sample of a `--project`
    /// result gets one entry in its source bundle's `analyses-manifest.json`, which names the result
    /// folder, so the bundle keeps its link to the result (BIO 6). A plain `--output` result records
    /// nothing, with or without `--batch` and wherever its folder sits, as Kraken2's does, since a
    /// folder the run did not make for the project may hold another result (B30 ruling Q2). A failed
    /// sample records nothing, where the app's in-process route records every sample of the request. A
    /// sample whose reads belong to no bundle records nothing, and so does a result outside the
    /// project's `Analyses/` folder, whose entry would name a folder the project does not list.
    ///
    /// The entry carries the sample's settings as the app's does (``TaxTriageConfig/summaryParameters()``)
    /// and the summary of the sample's result as the app writes it, `TaxTriageResult.summary` with the
    /// runtime it measured (B30 ruling Q1, vote V-B30). The TaxTriage parity masks only that number.
    static func sourceRecords(
        for units: [AnalysisUnitReport<TaxTriageUnitResult>],
        context: AnalysisRunFinalizeContext,
        destinationIsProject: Bool
    ) -> [any AnalysisSourceRecord] {
        guard destinationIsProject,
              let projectURL = context.projectURL,
              AnalysisManifestStore.analysisDirectoryPath(for: context.rootDirectory, projectURL: projectURL) != nil else {
            return []
        }
        return units.compactMap(\.outcome.result).flatMap { unitResult -> [any AnalysisSourceRecord] in
            let result = unitResult.result
            return result.config.samples.compactMap { sample -> (any AnalysisSourceRecord)? in
                guard let bundle = sourceBundle(of: sample) else { return nil }
                return AnalysisManifestSourceRecord(
                    bundleURL: bundle,
                    displayName: sourceRecordDisplayName,
                    parameters: result.config.summaryParameters(),
                    summary: result.summary
                )
            }
        }
    }

    /// The bundle a sample's reads come from, as the app's route finds it. A sample the unit planned
    /// from a bundle names the bundle it chose, a virtual one included, whose reads the unit
    /// materialized into the result. Any other sample names the bundle that holds its files.
    static func sourceBundle(of sample: TaxTriageSample) -> URL? {
        if let chosen = sample.readSetPlan?.inputURL,
           let bundle = MappingResultLayoutService.findSourceBundle(for: [chosen]) {
            return bundle
        }
        return MappingResultLayoutService.findSourceBundle(for: sample.allFiles)
    }
}
