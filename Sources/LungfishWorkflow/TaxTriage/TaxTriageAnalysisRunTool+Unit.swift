// TaxTriageAnalysisRunTool+Unit.swift - One TaxTriage launch on the analysis run executor (phase P2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension TaxTriageAnalysisRunTool {
    /// Phase P2. One TaxTriage launch in the folder the executor made for it.
    ///
    /// The unit resolves each `--input` sample to the files TaxTriage reads, as the command always
    /// has, materializing a virtual bundle into the unit folder's kept inputs folder (O1). It then
    /// runs the pipeline body both routes share, with the pin from the lock its services hold (N4),
    /// so the launch's argv and samplesheet come from A16's descriptor and builder and the engine is
    /// S9's.
    ///
    /// A `.singleFolder` or `.sharedBatchRoot` unit's folder is the result folder, so the pipeline
    /// saves no record of its own and hands every step, input and option to the root record
    /// (``TaxTriageRecording/rootRecord(_:)``, ARCH 3). A `.batchRoot` unit keeps the sample's own
    /// record in its folder, and hands the root only run-level values, the database the batch used
    /// (``TaxTriageRecording/unitRecord(_:)``, B12 row 256).
    package func run(
        _ unit: AnalysisRunUnit<TaxTriageRunUnit>,
        context: AnalysisRunUnitContext
    ) async throws -> AnalysisUnitOutcome<TaxTriageUnitResult> {
        let value = unit.value
        var config = value.config
        // The plan's output folder is the destination, which under --project is the project itself.
        config.outputDirectory = unit.directory
        let recording: TaxTriageRecording = value.handsFactsToRoot ? .rootRecord(context) : .unitRecord(context)
        if !value.handsFactsToRoot {
            context.recordOptions(AnalysisRootRecordOptions(
                resolved: TaxTriageRecordFacts.databaseIdentity(at: config.kraken2DatabasePath)
            ))
        }

        // The database as its install receipt vouches for it is a reference input of the run, with the receipt as its
        // source provenance (DB-IDENTITY, 3.1). A database with no receipt that adds up records none.
        if let databasePath = config.kraken2DatabasePath,
           let reference = MetagenomicsDatabaseReceiptReference.resolve(databasePath: databasePath)?.reference {
            context.recordInput(reference)
        }

        // A samplesheet names the files TaxTriage reads, and --input names files or bundles that
        // the command has always resolved first (TaxTriageReadSetPlanner, READ-PAIRING.md).
        if request.samplesheet == nil {
            let materializationDirectory = unit.directory.appendingPathComponent(
                TaxTriageReadSetPlanner.materializationDirectoryName,
                isDirectory: true
            )
            var resolved: [TaxTriageSample] = []
            for sample in config.samples {
                resolved.append(try await TaxTriageReadSetPlanner.resolve(
                    sample,
                    materializationDirectory: materializationDirectory,
                    materializer: services.materializer,
                    progress: { message in context.progress(0, message) }
                ))
            }
            config.samples = resolved
        }
        services.presentation.configured?(config)

        let pipeline = services.makePipeline()
        do {
            let result = try await pipeline.run(
                config: config,
                recording: recording,
                lock: services.lock,
                progress: { fraction, message in context.progress(fraction, message) }
            )
            let unitResult = TaxTriageUnitResult(result: result)
            // Nextflow ended 0 but TaxTriage ignored errored tasks, Completed with Warnings (2.8 T8).
            if let warning = result.erroredProcessesMessage {
                return .completedWithWarning(unitResult, reason: warning)
            }
            return .completed(unitResult)
        } catch let error as TaxTriagePipelineError {
            if case .pipelineFailed(_, let stderr, _) = error, !stderr.isEmpty {
                context.recordFailureDetail(stderr)
            }
            throw error
        }
    }
}
