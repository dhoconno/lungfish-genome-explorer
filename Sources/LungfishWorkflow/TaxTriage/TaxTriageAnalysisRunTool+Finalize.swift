// TaxTriageAnalysisRunTool+Finalize.swift - The run-level artifacts of a TaxTriage run on the executor (phase P3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension TaxTriageAnalysisRunTool {
    /// The words of the bar while the finalize builds the viewer index, as the app's TaxTriage row has them.
    package static let databaseStageMessage = "Building TaxTriage database\u{2026}"

    /// The finalize's share of the progress range for a result that gets a viewer index, the descriptor's
    /// (W3). The engine moves the bar to 0.9 and the viewer index takes it from there to the end.
    package var finalizeProgressShare: Double {
        NextflowWorkflowDescriptor.taxTriage.finalizeProgressShare
    }

    /// The share the executor reads once the plan is known (W1 of Phase 2.10, Q-U33). A plain `--output`
    /// result (``AnalysisRunLayout/singleFolder``) keeps its folder as the command has always left it,
    /// and its finalize returns before it builds anything, so its engine takes the whole bar and ends
    /// at 100 percent. A result in a project or a batch root keeps the descriptor's tenth for the index.
    package func finalizeProgressShare(for layout: AnalysisRunLayout) -> Double {
        layout == .singleFolder ? 0 : finalizeProgressShare
    }

    /// Phase P3. A result folder's launch already handed its step, with the digests of its outputs, to
    /// the root record. A batch root's samples each keep their own record, so the root names each
    /// completed sample's outputs with the digest and size that record took, and hashes nothing again
    /// (S2). Those the cleanup then removes drop out of the run level, which names only kept files.
    /// A batch root also gets the aggregate `taxtriage-result.json` the app's serial batch writes
    /// (``publishAggregateResult(of:planned:root:)``, T5, X3), which the root record names with its
    /// digest after the viewer index, so `taxtriage.sqlite` stays the run's output at every layout. A cancel
    /// before or during the viewer index leaves none, as the app's serial batch writes none (2.9 T10).
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
    /// analysis history (``sourceRecords(for:context:destinationIsProject:batchSummary:)``, X4), which
    /// the executor writes after the root record.
    package func finalize(
        _ units: [AnalysisUnitReport<TaxTriageUnitResult>],
        context: AnalysisRunFinalizeContext
    ) async throws -> AnalysisRunFinalization {
        var finalization = AnalysisRunFinalization()
        var aggregate: TaxTriageResult?
        if context.layout == .batchRoot {
            finalization.recordedFiles = units
                .filter { $0.outcome.result != nil }
                .compactMap { ProvenanceRecorder.loadEnvelope(from: $0.directory)?.outputs }
                .flatMap { $0 }
            // A failed sample keeps its place with the sample the plan gave its launch, read again here
            // because a failed launch hands back no result.
            let planned = units.contains { !$0.outcome.completed } ? try? plannedSamples() : nil
            aggregate = Task.isCancelled ? nil : try Self.publishAggregateResult(of: units, planned: planned, root: context.rootDirectory)
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
            finalization.warnings.append(ClassificationCompletionDetail.viewerIndexWarning(error.localizedDescription))
        }
        if aggregate != nil, Task.isCancelled {
            // 2.9 T10. A cancelled batch keeps no aggregate result, as the app's serial batch writes none, and the
            // executor names none of the finalize's outputs then (E5).
            try? FileManager.default.removeItem(at: Self.resultURL(in: context.rootDirectory))
            aggregate = nil
        }
        if aggregate != nil {
            finalization.outputs.append(AnalysisRunOutput(url: Self.resultURL(in: context.rootDirectory), format: .json))
        }
        finalization.sourceRecords = Self.sourceRecords(
            for: units,
            context: context,
            destinationIsProject: request.destinationIsProject,
            batchSummary: aggregate?.summary
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
    /// sample records nothing, as the app's in-process route does since U38 M1 (BIO 4). A
    /// sample whose reads belong to no bundle records nothing, and so does a result outside the
    /// project's `Analyses/` folder, whose entry would name a folder the project does not list.
    ///
    /// The entry carries the sample's settings as the app's does (``TaxTriageConfig/summaryParameters()``)
    /// and a summary as the app writes it, `TaxTriageResult.summary` with the runtime it measured (B30
    /// ruling Q1, vote V-B30), which the TaxTriage parity masks. A batch root's entries carry
    /// `batchSummary`, its aggregate result's, as the app's carry its serial batch's, so a batch that
    /// lost a sample says so in each bundle (BIO ruling Q1 note). Any other entry carries its sample's.
    static func sourceRecords(
        for units: [AnalysisUnitReport<TaxTriageUnitResult>],
        context: AnalysisRunFinalizeContext,
        destinationIsProject: Bool,
        batchSummary: String? = nil
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
                    summary: batchSummary ?? result.summary
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

    // MARK: - The aggregate result (X3)

    /// The name of a TaxTriage result, a sample's own and the aggregate at a batch root.
    static let resultFilename = "taxtriage-result.json"

    static func resultURL(in folder: URL) -> URL {
        folder.appendingPathComponent(resultFilename)
    }

    /// T5. Publishes the aggregate result of a batch root as `taxtriage-result.json` through
    /// `DurableReplace`, so the name holds a whole file at every step on every volume (SWIFT), and returns
    /// it, or nil when no sample completed. The finalize runs before the root record, which names it. The
    /// bytes are those `TaxTriageResult.save()` writes.
    static func publishAggregateResult(
        of units: [AnalysisUnitReport<TaxTriageUnitResult>],
        planned: [TaxTriageSample]?,
        root: URL
    ) throws -> TaxTriageResult? {
        guard let aggregate = aggregateResult(of: units, planned: planned, root: root) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try DurableReplace.replace(try encoder.encode(aggregate), named: resultFilename, in: root)
        return aggregate
    }

    /// The aggregate result of a batch root, in the shape of the app's serial batch result
    /// (the legacy route, whose runner went in 2.13 K1b), which the viewer, the row and the batch overview's control column
    /// read (T4). It holds no fact the samples' results lack (T5, BIO), in request order. Its settings are
    /// the first completed sample's, which every launch shared but the platform, with the batch root as its
    /// folder. Each completed sample keeps the sample its result holds, platform and control mark included.
    /// Each failed sample keeps its place with the sample `planned` gave its launch, when `planned` still
    /// names it at the unit's index, and is a sample failure with its folder and the reason its launch
    /// failed, which its own record keeps, so the batch reads Completed with Warnings (BIO 4). The files,
    /// the ignored task failures and the source bundles are the completed samples', with no launch's log or
    /// trace, and the runtime is the sum of their runtimes, where the app's batch times itself. Nil when no
    /// sample completed.
    static func aggregateResult(
        of units: [AnalysisUnitReport<TaxTriageUnitResult>],
        planned: [TaxTriageSample]?,
        root: URL
    ) -> TaxTriageResult? {
        let results = units.compactMap { $0.outcome.result?.result }
        guard let first = results.first else { return nil }
        let folder = URL(fileURLWithPath: root.path, isDirectory: true)
        var failures: [TaxTriageSampleFailure] = []
        var config = first.config
        config.outputDirectory = folder
        config.samples = units.flatMap { unit -> [TaxTriageSample] in
            if let result = unit.outcome.result?.result {
                return result.config.samples
            }
            if case .failed(let reason) = unit.outcome {
                failures.append(TaxTriageSampleFailure(sampleID: unit.label, outputDirectory: unit.directory, errorDescription: reason))
            }
            guard let planned, planned.indices.contains(unit.index), planned[unit.index].sampleId == unit.label else { return [] }
            return [planned[unit.index]]
        }
        let bundles = uniqued(results.flatMap { $0.sourceBundleURLs ?? [] })
        config.sourceBundleURLs = bundles.isEmpty ? nil : bundles
        let files = TaxTriageOutputArtifactPolicy.filterRetainedOutputFiles(results.flatMap(\.allOutputFiles), outputDirectory: folder)
        return TaxTriageResult(
            config: config,
            runtime: results.map(\.runtime).reduce(0, +),
            exitCode: 0,
            outputDirectory: folder,
            reportFiles: uniqued(results.flatMap(\.reportFiles)),
            metricsFiles: uniqued(results.flatMap(\.metricsFiles)),
            kronaFiles: uniqued(results.flatMap(\.kronaFiles)),
            allOutputFiles: uniqued(files + [resultURL(in: folder)]),
            sourceBundleURLs: config.sourceBundleURLs,
            ignoredFailures: results.flatMap(\.ignoredFailures),
            sampleFailures: failures
        )
    }

    /// `urls` in their order, each path once.
    private static func uniqued(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
