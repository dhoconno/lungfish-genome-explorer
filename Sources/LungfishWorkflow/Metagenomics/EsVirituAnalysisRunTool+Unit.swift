// EsVirituAnalysisRunTool+Unit.swift - One EsViritu sample run under the analysis run executor, phase P2
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension EsVirituAnalysisRunTool {
    /// Runs one sample in the folder the executor made for it.
    ///
    /// The inputs resolve as `esviritu detect` has always resolved them. A virtual bundle is
    /// materialized into `<root>/.lungfish-esviritu-inputs/`, which stays (E3), and a planned
    /// sample gets its files and read format from the read-set planner the app runs too. EsViritu's
    /// `-s` is the unit's sample name, which in a batch root is the name of the sample's folder
    /// (R4). Before EsViritu runs, the unit hands the root record the lineage of each input to its
    /// bundle with the payload checksums (D5), so a failed or cancelled run's record holds them.
    /// After it ran, the detection table is parsed and a column change fails the sample (D10), and
    /// the pipeline's steps join the root record. In a one-folder result the root record replaces
    /// the pipeline's record, so the unit also hands over the pipeline's run parameters, with the
    /// read-set plan in its one home (E13).
    public func run(
        _ unit: AnalysisRunUnit<EsVirituSampleUnit>,
        context: AnalysisRunUnitContext
    ) async throws -> AnalysisUnitOutcome<EsVirituSampleResult> {
        let sample = unit.value
        let reporter = reporter
        let materializationDirectory = context.rootDirectory
            .appendingPathComponent(Self.materializationDirectoryName, isDirectory: true)
        // Each line about the inputs is progress at the unit's start, so the app's row shows it as
        // its detail and in the viewer's overlay (A10 review fix 5, UX D5, D14).
        let resolving: @Sendable (String) -> Void = { message in
            reporter?.resolving(message)
            context.progress(0, message)
        }
        let resolved = try await ResolvedSequenceInputs.resolvePreflighted(
            inputURLs: sample.inputs,
            operationName: "EsViritu detection",
            materializationDirectory: materializationDirectory,
            materializer: materializer,
            progress: resolving
        )

        var config = EsVirituConfig(
            inputFiles: resolved.executionInputURLs,
            isPairedEnd: sample.readFormat == .paired,
            sampleName: unit.sampleName,
            outputDirectory: unit.directory,
            databasePath: sample.settings.databasePath,
            qualityFilter: sample.settings.qualityFilter,
            threads: sample.settings.threads,
            extraArguments: sample.settings.extraArguments,
            readFormat: sample.readFormat,
            inputLayout: sample.inputLayout
        )
        // Provenance names the bundle behind each file. Files run as given record nothing more.
        config.recordInputLineage(resolved)
        if sample.plansReadSet {
            try await Self.planReadSet(
                of: sample.inputs,
                into: &config,
                materializedInputs: resolved.executionInputURLs,
                materializationDirectory: materializationDirectory,
                progress: resolving
            )
        }
        if let message = Self.inputCountError(format: config.readFormat, fileCount: config.inputFiles.count) {
            return .failed(reason: message)
        }

        // The read format the user gave is explicit in the root's run options (`runOptions`, SW26 note 4).
        let writesIntoRoot = unit.directory.standardizedFileURL == context.rootDirectory.standardizedFileURL
        if writesIntoRoot {
            context.recordOptions(Self.lineageOptions(of: config))
        }
        for descriptor in Self.inputDescriptors(of: config) {
            context.recordInput(descriptor)
        }
        // The database as its install receipt vouches for it is a reference input of the run, with the receipt
        // as its source provenance (DB-IDENTITY, 3.1). A database with no receipt that adds up records none.
        if let reference = MetagenomicsDatabaseReceiptReference.resolve(
            databasePath: sample.settings.databasePath, allowingParentReceipt: true
        )?.reference {
            context.recordInput(reference)
        }
        if let reason = config.readSetPlan?.singleReadReason {
            context.log(.info, reason)
        }
        let advisory = EsVirituReadLengthAdvisory.evaluate(inputURLs: config.inputFiles)?.wizardMessage
        if let advisory {
            // Warn, never block, as the EsViritu dialog does. It is no warning of the run, because
            // the app's run of the same reads ends Completed.
            context.log(.info, advisory)
        }
        reporter?.willRun(config, inputs: sample.inputs, advisory: advisory)

        let result: EsVirituResult
        do {
            result = try await pipeline.detect(config: config) { fraction, message in
                reporter?.progress(fraction, message)
                context.progress(fraction, message)
            }
        } catch let error as EsVirituPipelineError {
            // EsViritu's own reason, and the last lines of its log (UX D11, D6). In a run of one
            // sample the tail is the failure's detail, which the executor bounds and sends on the
            // run's `failed` line, and the words the app puts in front of it are the app's. A
            // batch goes on past a failed sample or fails with several, so no `failed` line
            // carries the tail. The unit logs it, bounded the same way, as one `error` line headed
            // as the app's batch row has always headed it, and the tail is the only clue when
            // EsViritu reports no error of its own.
            if let logTail = error.logTail {
                if unit.count > 1 {
                    if let bounded = AnalysisRunFailureDetail.bounded(logTail) {
                        context.log(.error, Self.logTailHeading + bounded)
                    }
                } else {
                    context.recordFailureDetail(logTail)
                }
            }
            return .failed(reason: error.localizedDescription)
        }

        // The app's EsViritu runs fail on a column change of the detection table rather than
        // report an empty result as complete (D10). Both routes now parse it here.
        let detections: [ViralDetection]
        do {
            detections = try EsVirituDetectionParser.parse(url: result.detectionURL)
        } catch {
            context.log(.error, "Failed to parse EsViritu detections: \(error.localizedDescription)")
            return .failed(reason: error.localizedDescription)
        }

        if let envelope = ProvenanceRecorder.loadEnvelope(from: unit.directory) {
            for step in envelope.steps {
                context.recordStep(step)
            }
            if writesIntoRoot {
                context.recordOptions(Self.pipelineOptions(of: envelope))
            }
        }
        reporter?.didRun(result)
        return .completed(EsVirituSampleResult(
            inputs: sample.inputs,
            config: config,
            result: result,
            detectionCount: detections.count,
            familyCount: Set(detections.compactMap(\.family)).count,
            speciesCount: Set(detections.compactMap(\.species)).count
        ))
    }

    /// Plans the read set of one input, a bundle or a file, through
    /// ``EsVirituConfig/readSet(for:materializedInputs:materializationDirectory:progress:)``, the function
    /// the app's EsViritu launch runs too, and sets `config` from it. Separate R1 and R2 files run as a
    /// pair, and a sample that mixes pairs and single reads, or holds several files of single reads,
    /// runs `-p unpaired` on one file that holds every read. Any other input keeps `config`.
    ///
    /// - Returns: Whether the plan changed the configuration.
    @discardableResult
    public static func planReadSet(
        of inputs: [URL],
        into config: inout EsVirituConfig,
        materializedInputs: [URL],
        materializationDirectory: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Bool {
        guard let input = SamplesheetReadSetPlanner.plannableInput(inputs) else { return false }
        let readSet = try await EsVirituConfig.readSet(
            for: input,
            materializedInputs: materializedInputs,
            materializationDirectory: materializationDirectory,
            progress: progress
        )
        return config.apply(readSet)
    }

    /// The inputs EsViritu reads, with the bundle behind each file, meaning its manifest, payload
    /// and root FASTQ, as the pipeline's step records them. Taken once here, so a run that stops
    /// later still names them.
    static func inputDescriptors(of config: EsVirituConfig) -> [ProvenanceFileDescriptor] {
        let records = EsVirituPipeline.inputLineageRecords(for: config) ?? config.inputFiles.map { url in
            ProvenanceRecorder.fileRecord(url: url, format: .fastq, role: .input)
        }
        return records.map { ProvenanceFileDescriptor(fileRecord: $0) }
    }

    /// The lineage of a one-folder run's inputs for the root record before EsViritu runs, the inputs
    /// as given and the commands that made each materialized or joined file, with the read-set plan
    /// in its one home.
    static func lineageOptions(of config: EsVirituConfig) -> AnalysisRootRecordOptions {
        AnalysisRootRecordOptions(
            explicit: EsVirituPipeline.inputLineageParameters(for: config),
            readSetPlan: AnalysisRootRecordOptions.readSetPlanValue(of: config.readSetPlan)
        )
    }

    /// The options of the pipeline's record, which a one-folder root record takes over. The pipeline
    /// writes the read-set plan under the resolved options itself (E13, B16), so nothing moves.
    static func pipelineOptions(of envelope: ProvenanceEnvelope) -> AnalysisRootRecordOptions {
        AnalysisRootRecordOptions(
            explicit: envelope.options.explicit,
            defaults: envelope.options.defaults,
            resolved: envelope.options.resolvedDefaults
        )
    }
}
