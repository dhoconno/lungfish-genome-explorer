// ExecutorRunAdoption+Bundle.swift - The adopt's bundle, written from the plan and the run record by the import's IO code (CHTC C4 lane A)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// What the adopt hands `FASTQBatchImporter.writeImportProvenance` beyond an import's own values.
struct ExecutorAdoptionProvenance: Sendable {
    /// Resolved options that replace the import's: C4-01's null basis keys and XC-13's four source keys at `plan`.
    var resolvedParameters: [String: ParameterValue]
    /// The node's steps, whose parent is the executor's step and never the import step (QA ruling 2, XC-8).
    var childStepIDs: Set<UUID>
}

extension ExecutorRunAdoption {
    /// The executor's step in the envelope, the runner role of the adopt route (QA ruling 2). The record's own Q20 and
    /// Q30 step names the tool `lungfish-executor`, so the runner takes a name of its own and each route holds one.
    static let executorToolName = "lungfish-executor run"
    /// The executor binary, the tool of a node step that names none of its own.
    static let executorBinaryName = "lungfish-executor"

    /// Builds the import's in-process values from the plan and the record, then writes the bundle through
    /// `FASTQMetadataStore.save` and `FASTQBatchImporter.writeImportProvenance` and publishes it by one rename. The
    /// envelope is signed on the Mac as an import's is.
    static func writeBundle(_ run: ExecutorAdoptedRun, projectDirectory: URL, force: Bool) async throws -> URL {
        let plan = run.plan
        let record = run.record
        let inputs = plan.entries.filter { $0.role == .input }.map { run.folder.appendingPathComponent($0.relativePath) }
        guard let r1 = inputs.first else { throw refusal("entries", "The plan pins no input.") }
        let recipe = try resolvedRecipe(plan.recipe)
        let config = importConfig(plan, recipe: recipe, projectDirectory: projectDirectory, paired: inputs.count > 1, force: force)
        let metadataPairs = Dictionary(plan.sample.sampleSheet.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
        let pair = SamplePair(sampleName: run.sampleName, r1: r1, r2: inputs.count > 1 ? inputs[1] : nil, metadata: metadataPairs)
        let bundleURL = FASTQBatchImporter.bundleOutputURL(for: pair, in: projectDirectory)
        if FileManager.default.fileExists(atPath: bundleURL.path) && !force {
            throw BatchImportError.outputBundleAlreadyExists(bundleURL)
        }

        try FASTQBatchImporter.prepareFASTQBundleParent(for: bundleURL)
        let staging = try FASTQBatchImporter.makeStagingFASTQBundleURL(for: bundleURL)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: staging) } }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let fastqName = "\(pair.sampleName).fastq.gz"
        let stagedFASTQ = staging.appendingPathComponent(fastqName)
        try FileManager.default.copyItem(at: run.payloadURL, to: stagedFASTQ)
        if !metadataPairs.isEmpty {
            var csv = metadataPairs
            csv["sample"] = pair.sampleName
            try FASTQBundleCSVMetadata.save(FASTQBundleCSVMetadata(keyValuePairs: csv), to: staging)
        }

        let ingestionResult = ingestionResult(run, outputFile: stagedFASTQ, paired: inputs.count > 1)
        let pairing = FASTQBatchImporter.recordedPairing(
            pairing: config.pairing, r1: inputs.count > 1 ? r1 : stagedFASTQ, hasR2: inputs.count > 1
        )
        var metadata = PersistedFASTQMetadata()
        metadata.ingestion = IngestionMetadata(
            isClumpified: ingestionResult.wasClumpified, isCompressed: true, pairingMode: pairing.mode,
            pairingSource: pairing.source, qualityBinning: ingestionResult.qualityBinning.rawValue,
            originalFilenames: plan.sample.originalFilenames, ingestionDate: Date(),
            originalSizeBytes: plan.sample.originalSizeBytes, storageInputSizeBytes: ingestionResult.originalSizeBytes,
            storageOutputSizeBytes: ingestionResult.finalSizeBytes
        )
        FASTQBatchImporter.applyPlatformMetadata(to: &metadata, config: config)
        if let recipe {
            metadata.ingestion?.recipeApplied = RecipeAppliedInfo(
                recipeID: recipe.id, recipeName: recipe.name, appliedDate: Date(),
                stepResults: recipeStepResults(run, ingestionResult: ingestionResult, optimizeStorage: config.optimizeStorage),
                recipeSHA256: recipe.sourceSHA256, recipeFormatVersion: recipe.formatVersion,
                requestedName: recipe.requestedName, presetID: recipe.resolution?.preset?.id,
                presetName: recipe.resolution?.preset?.name, switchSettings: recipe.switches.isEmpty ? nil : recipe.switchSettings
            )
        }
        FASTQMetadataStore.save(metadata, for: stagedFASTQ)

        let executorStep = executorStepExecution(record)
        let nodeSteps = record.steps.map { nodeStepExecution($0, parent: executorStep.id) }
        try await FASTQBatchImporter.writeImportProvenance(
            pair: pair, processingPair: pair, materializationSteps: nodeSteps + [executorStep], unpairedReads: nil,
            config: config, importedPairing: pairing, stagingBundleURL: staging, stagingBundleFASTQURL: stagedFASTQ,
            publishedBundleURL: bundleURL, publishedBundleFASTQURL: bundleURL.appendingPathComponent(fastqName),
            sourceIngestionOutputURL: stagedFASTQ, ingestionResult: ingestionResult, recipeStepResults: [],
            runClock: ProvenanceRunClock(), statsStartedAt: Date(), statsCompletedAt: Date(), statsError: nil,
            adoption: ExecutorAdoptionProvenance(
                resolvedParameters: adoptedParameters(ingestionResult), childStepIDs: Set(nodeSteps.map(\.id))
            )
        )
        try Task.checkCancellation()
        try FASTQBatchImporter.publishFASTQBundle(from: staging, to: bundleURL, replaceExisting: force)
        published = true
        return bundleURL
    }

    /// C4-01 and XC-13. No decision of the plan used an input estimate, a host's memory or a threshold, so the three
    /// basis keys are null for a plan that names a tool as well as for `auto` (XC-7), and each source key is `plan`.
    static func adoptedParameters(_ result: FASTQIngestionResult) -> [String: ParameterValue] {
        let plan = ParameterValue.string(ImportSettingSource.plan.rawValue)
        return [
            "clumpingEstimatedInputBytes": .null,
            "clumpingPhysicalMemoryBytes": .null,
            "clumpingThresholdBytes": .null,
            "threadsSource": plan,
            "clumpifyHeapSource": result.clumpifyHeapGB == nil ? .null : plan,
            "resolvedClumpingToolSource": plan,
            "qualityBinningSource": plan,
        ]
    }

    /// The recipe the plan ran, resolved in this build by the name and switch options the plan states. A recipe whose
    /// file differs from the plan's is refused, so the record never names a recipe that did not run.
    static func resolvedRecipe(_ identity: PlanRecipeIdentity?) throws -> Recipe? {
        guard let identity else { return nil }
        let options = Dictionary(
            identity.switches.filter { $0.source == "option" }.map { ($0.id, $0.value) }, uniquingKeysWith: { $1 }
        )
        guard let recipe = try RecipeResolver.resolve(
            identity.requestedName, in: RecipeRegistryV2.builtinRecipes(), switchOptions: options
        ), recipe.sourceSHA256 == identity.sourceSHA256 else {
            throw refusal(
                "recipe",
                "This build of LGE holds no recipe \(identity.requestedName) with SHA-256 \(identity.sourceSHA256), the recipe the plan ran."
            )
        }
        return recipe
    }

    /// The import's configuration as the plan fixed it. Threads come from the plan, never from this Mac.
    static func importConfig(
        _ plan: ExecutionPlan, recipe: Recipe?, projectDirectory: URL, paired: Bool, force: Bool
    ) -> FASTQBatchImporter.ImportConfig {
        let level: CompressionLevel = plan.storage.compressionLevel <= 1 ? .fast : (plan.storage.compressionLevel >= 9 ? .maximum : .balanced)
        return FASTQBatchImporter.ImportConfig(
            projectDirectory: projectDirectory,
            platform: plan.sample.platform.flatMap(ImportPlatformRequest.init(cliValue:)) ?? .auto,
            newRecipe: recipe, qualityBinning: plan.storage.qualityBinning,
            optimizeStorage: plan.clumping.requested != .none,
            clumpingTool: ClumpingTool(rawValue: plan.clumping.requested.rawValue), compressionLevel: level,
            threads: plan.storage.threads, forceReimport: force, pairing: paired ? .paired : .auto,
            threadsSource: .plan, clumpifyHeapGB: plan.storage.clumpifyHeapGB
        )
    }

    /// The storage result as the record states it. The basis fields hold zeros that never reach the record, since
    /// `adoptedParameters` writes them null.
    static func ingestionResult(_ run: ExecutorAdoptedRun, outputFile: URL, paired: Bool) -> FASTQIngestionResult {
        let plan = run.plan
        let step = run.record.steps.first { $0.kind == .storage }
        let requested = ClumpingTool(rawValue: plan.clumping.requested.rawValue) ?? .auto
        let resolved = ClumpingTool(rawValue: plan.clumping.resolved.rawValue) ?? .none
        let clumpifyRan = step?.storage?.clumpingRan == true && plan.clumping.resolved == .bbtools
        return FASTQIngestionResult(
            outputFile: outputFile, wasClumpified: step?.storage?.clumpingRan ?? false,
            qualityBinning: step?.storage?.qualityBinning ?? plan.storage.qualityBinning,
            originalFilenames: plan.sample.originalFilenames, originalSizeBytes: step?.storage?.inputBytes ?? 0,
            finalSizeBytes: run.payload.size, pairingMode: paired ? .interleaved : .singleEnd,
            requestedClumpingTool: requested, resolvedClumpingTool: resolved,
            clumpingResolution: ClumpingToolResolution(
                requested: requested, resolved: resolved, estimatedInputBytes: 0, physicalMemoryBytes: 0,
                clumpifyHeapBytes: plan.clumping.heapBytes, thresholdBytes: 0, reason: plan.clumping.reason
            ),
            processingTool: step?.tool?.id, processingToolVersion: step?.tool?.version,
            processingCommandLine: step.map { $0.argv.joined(separator: " ") },
            clumpifyHeapGB: clumpifyRan ? plan.storage.clumpifyHeapGB : nil
        )
    }

    /// The sidecar's step results: each recipe step the node ran, then storage and statistics as the Mac lists them.
    static func recipeStepResults(
        _ run: ExecutorAdoptedRun, ingestionResult: FASTQIngestionResult, optimizeStorage: Bool
    ) -> [RecipeStepResult] {
        var results = run.record.steps.filter { $0.kind == .recipe }.map { step in
            RecipeStepResult(
                stepName: run.plan.steps.first { $0.id == step.id }?.title ?? step.id, tool: step.tool?.id ?? executorBinaryName,
                toolVersion: step.tool?.version, commandArguments: step.argv, inputReadCount: step.inputReadCount.map(Int.init),
                outputReadCount: step.outputReadCount.map(Int.init), durationSeconds: step.wallSeconds,
                exitStatus: step.toolExitCode.map(Int.init), startedAt: date(step.startedAt), completedAt: date(step.endedAt)
            )
        }
        if let storage = run.record.steps.first(where: { $0.kind == .storage }) {
            results.append(RecipeStepResult(
                stepName: optimizeStorage ? "Optimize storage + Compress" : "Compress",
                tool: ingestionResult.processingTool ?? "compression", toolVersion: ingestionResult.processingToolVersion,
                commandLine: ingestionResult.processingCommandLine, durationSeconds: storage.wallSeconds
            ))
        }
        if let statistics = run.record.steps.first(where: { $0.kind == .statistics }) {
            results.append(RecipeStepResult(
                stepName: "Compute statistics", tool: statistics.tool?.id ?? "seqkit", toolVersion: statistics.tool?.version,
                durationSeconds: statistics.wallSeconds
            ))
        }
        return results
    }

    /// The executor's step, the runner of every node step, from the record's `executor` block (XC-8).
    static func executorStepExecution(_ record: ExecutorRunRecord) -> StepExecution {
        StepExecution(
            toolName: executorToolName, toolVersion: record.executor.buildPin?.lgeVersion ?? "unknown",
            command: [executorBinaryName] + record.executorArguments, inputs: [], exitCode: record.exitCode,
            wallTime: record.wallSeconds, startTime: date(record.startedAt) ?? Date(), endTime: date(record.endedAt)
        )
    }

    /// One node step under the executor's step, with the argv, version and times the record states.
    static func nodeStepExecution(_ step: ExecutorStepRecord, parent: UUID) -> StepExecution {
        StepExecution(
            toolName: step.tool?.id ?? executorBinaryName, toolVersion: step.tool?.version ?? "unknown", command: step.argv,
            inputs: [], exitCode: step.toolExitCode ?? (step.outcome == .succeeded ? 0 : 1), wallTime: step.wallSeconds,
            peakMemoryBytes: step.peakResidentBytes, stderr: step.stderrTail.isEmpty ? nil : step.stderrTail,
            parentStepID: parent, startTime: date(step.startedAt) ?? Date(), endTime: date(step.endedAt)
        )
    }

    /// A time as the record states it, ISO 8601 in UTC with milliseconds.
    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
