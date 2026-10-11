// Kraken2AnalysisRunTool+Unit.swift - One Kraken2 sample under the analysis run executor (phase P2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension Kraken2AnalysisRunTool {
    /// Phase P2. Materializes the sample's virtual inputs into the result folder's
    /// `.lungfish-classify-inputs/` and keeps them (E3), plans its read set, runs Kraken2 and, for a
    /// profile, Bracken.
    ///
    /// In a one-folder run the root record replaces the pipeline's record, so the unit hands every
    /// fact of it to the root record as soon as it has it: the materialization steps, the options
    /// with the read-set plan (E13), the replay argv that names the kept materialization, then the
    /// pipeline's steps and the Bracken outcome. In a batch the sample's folder keeps the pipeline's
    /// record, and the unit hands the root record only the materialization steps, which wrote into
    /// the batch root.
    public func run(
        _ unit: AnalysisRunUnit<Kraken2RunUnit>,
        context: AnalysisRunUnitContext
    ) async throws -> AnalysisUnitOutcome<Kraken2UnitResult> {
        let value = unit.value
        let sample = value.request
        let clock = ProvenanceRunClock()
        let materializationDirectory = context.rootDirectory
            .appendingPathComponent(KrakenReadSetPlanner.inputsDirectoryName, isDirectory: true)
        var stage = "materialization"
        var config: ClassificationConfig?
        do {
            let resolved = try await ResolvedSequenceInputs.resolvePreflighted(
                inputURLs: value.inputURLs,
                operationName: "classification",
                materializationDirectory: materializationDirectory,
                materializer: services.materializer,
                progress: { message in context.log(.info, message) }
            )
            if resolved.didMaterialize {
                let started = resolved.materializationStartedAt ?? clock.startedAt
                let steps = try CLISequenceInputMaterialization.materializationProvenanceSteps(
                    workflowVersion: LungfishAppVersion.short,
                    originalInputURLs: resolved.originalInputURLs,
                    executionInputURLs: resolved.executionInputURLs,
                    startedAt: started,
                    endedAt: resolved.materializationEndedAt ?? started
                )
                steps.forEach(context.recordStep)
            }

            stage = "readSetPlanning"
            var made = sample.applyingThresholdOverrides(to: sample.makeConfig(
                inputURLs: resolved.executionInputURLs,
                readFormat: value.readFormat,
                databaseInfo: value.database,
                databasePath: value.databasePath,
                inputFormat: value.inputFormat,
                outputDirectory: unit.directory,
                extraArguments: value.extraArguments
            ))
            made.originalInputFiles = value.inputURLs
            made.sampleDisplayName = value.sampleDisplayName
            let planned = try await sample.planReadSet(
                inputURLs: value.inputURLs,
                executionInputURLs: resolved.executionInputURLs,
                config: &made,
                materializationDirectory: materializationDirectory
            )
            config = made
            let executionInputs = planned?.executionInputURLs ?? resolved.executionInputURLs
            let originalInputs = planned?.originalInputURLs ?? resolved.originalInputURLs
            if value.handsFactsToRoot {
                context.recordOptions(Kraken2RunRecordOptions.rootOptions(
                    config: made,
                    outcome: .notRequested,
                    request: sample,
                    argv: value.commandLine,
                    originalInputURLs: originalInputs,
                    executionInputURLs: executionInputs
                ))
                // A planned read set names its own files, so only a run of the files as resolved
                // replays through the kept materialization.
                if planned == nil, let replay = CLISequenceInputMaterialization.durableReplayArgv(
                    argv: value.commandLine,
                    originalInputArguments: resolved.argumentsPerExecutionFile(sample.inputArguments),
                    originalInputURLs: resolved.originalInputURLs,
                    executionInputURLs: resolved.executionInputURLs
                ) {
                    context.recordDurableReplayArgv(replay)
                }
            }

            stage = "pipeline"
            services.presentation.configured?(made)
            let presentation = services.presentation
            let result = try await services.runPipeline(made) { fraction, message in
                context.progress(fraction, message)
                presentation.pipelineProgress?(message)
            }

            if value.handsFactsToRoot {
                let descriptors = try CLISequenceInputMaterialization.originalAndExecutionInputs(
                    originalInputURLs: originalInputs,
                    executionInputURLs: executionInputs
                ).map { try CLISequenceInputMaterialization.executionInputDescriptor(originalURL: $0.originalURL, executionURL: $0.executionURL) }
                let steps = try Kraken2RunRecordOptions.steps(
                    for: result,
                    pipelineEnvelope: ProvenanceRecorder.loadEnvelope(from: unit.directory),
                    executionInputs: descriptors,
                    startedAt: clock.startedAt,
                    endedAt: clock.now
                )
                steps.forEach(context.recordStep)
                context.recordOptions(Kraken2RunRecordOptions.rootOptions(
                    config: result.config,
                    outcome: result.profileOutcome,
                    request: sample,
                    argv: value.commandLine,
                    originalInputURLs: originalInputs,
                    executionInputURLs: executionInputs
                ))
            } else {
                try Self.convergeSampleRecord(in: unit.directory)
            }
            let unitResult = Kraken2UnitResult(
                result: result,
                sourceBundle: Self.sourceBundle(of: value.inputURLs),
                inputURLs: value.inputURLs,
                destinationIsProject: value.destinationIsProject
            )
            if let reason = Self.warning(for: result) {
                return .completedWithWarning(unitResult, reason: reason)
            }
            if let reason = Self.failure(for: result) {
                return .failed(reason: reason)
            }
            return .completed(unitResult)
        } catch {
            // A cancel kills the tool child too, which can end the pipeline with a plain error
            // before the task sees the cancel, so the cancel request decides (E5, SWIFT X2).
            let cancelled = error is CancellationError || Task.isCancelled || services.cancelRequested()
            if value.handsFactsToRoot {
                if stage == "pipeline", let config {
                    Kraken2RunRecordOptions.stepsOfFailedPipeline(
                        in: config.outputDirectory,
                        startedAt: clock.startedAt,
                        endedAt: clock.now
                    ).forEach(context.recordStep)
                }
                context.recordOptions(AnalysisRootRecordOptions(resolved: [
                    "profileState": .string(cancelled ? "cancelled" : "failed"),
                    "failureStage": .string(stage),
                ]))
            } else {
                Self.convergeStoppedSampleRecord(
                    in: unit.directory,
                    startedAt: clock.startedAt,
                    endedAt: clock.now,
                    cancelled: cancelled
                )
            }
            throw error
        }
    }

    /// A batch sample whose pipeline failed or was cancelled keeps the record the pipeline wrote
    /// during this run, converged as ``convergeSampleRecord(in:)`` converges a completed sample's,
    /// so the result holds one defaults table and one home of the read-set plan (E12, E13, D8). A
    /// cancel also sets the record's status and `profileState` to cancelled and its exit status to
    /// 125, from the cancel request and never from how the child ended, as the root record of the
    /// run says (E5). Its steps keep the exit status each child ended with. Nothing is hashed, and
    /// a record that cannot be rewritten stays as the pipeline left it, so the unit throws its own
    /// error.
    static func convergeStoppedSampleRecord(in directory: URL, startedAt: Date, endedAt: Date, cancelled: Bool) {
        guard let envelope = Kraken2RunRecordOptions.pipelineRecordOfThisRun(
            in: directory,
            startedAt: startedAt,
            endedAt: endedAt
        ) else {
            return
        }
        var options = Kraken2RunRecordOptions.convergedSampleOptions(envelope.options)
        if cancelled {
            var resolved = options.resolvedDefaults
            resolved["profileState"] = .string("cancelled")
            options = ProvenanceOptions(explicit: options.explicit, defaults: options.defaults, resolvedDefaults: resolved)
        }
        let converged = envelope.with { record in
            record.options = options
            if cancelled {
                record.status = .cancelled
                record.exitStatus = Int(AnalysisRunExitCode.cancelled)
            }
        }
        _ = try? ProvenanceWriter().write(converged, to: directory)
    }

    /// A batch sample keeps the pipeline's record in its folder. Its options converge on the rules
    /// of the root record (``Kraken2RunRecordOptions/convergedSampleOptions(_:)``), so one result
    /// holds one defaults table and one home of the read-set plan (E12, E13, D8).
    static func convergeSampleRecord(in directory: URL) throws {
        guard let envelope = ProvenanceRecorder.loadEnvelope(from: directory),
              Kraken2RunRecordOptions.pipelineWorkflowNames.contains(envelope.workflowName) else {
            return
        }
        let converged = envelope.with { $0.options = Kraken2RunRecordOptions.convergedSampleOptions($0.options) }
        _ = try ProvenanceWriter().write(converged, to: directory)
    }

    /// The warning a usable result ends with, a Bracken profile that degraded (E4).
    static func warning(for result: ClassificationResult) -> String? {
        guard result.profileOutcome.state == .degraded else { return nil }
        let detail = result.profileOutcome.message ?? result.profileOutcome.reason?.rawValue ?? "unknown profiling failure"
        return "Kraken classification completed, but Bracken profiling did not complete: \(detail)"
    }

    /// Why a result fails its sample: a profile that ran without a recorded Bracken outcome.
    static func failure(for result: ClassificationResult) -> String? {
        guard result.profileOutcome.state == .notRequested, result.config.goal == .profile else { return nil }
        return "Kraken classification completed, but Bracken profiling has no recorded outcome."
    }

    /// The bundle the sample was read from, a `.lungfishfastq` bundle or a reference bundle.
    static func sourceBundle(of inputURLs: [URL]) -> URL? {
        for url in inputURLs {
            if let bundle = SequenceInputResolver.enclosingFASTQBundleURL(for: url)
                ?? SequenceInputResolver.enclosingReferenceBundleURL(for: url) {
                return bundle
            }
        }
        return nil
    }
}
