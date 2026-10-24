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
    /// The envelope's argv and its import step's command, the adopt command (CLI-EQUIVALENCE, "Same provenance").
    var argv: [String]
    /// The run-level identity, with the image `staging.json` names and the launcher's site facts.
    var runtime: ProvenanceRuntimeIdentity
    /// The environment the signing key is read from.
    var signingEnvironment: [String: String]
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
    static func writeBundle(
        _ run: ExecutorAdoptedRun, projectDirectory: URL, force: Bool, argv: [String], signingEnvironment: [String: String]
    ) async throws -> URL {
        let plan = run.plan
        let record = run.record
        let (pair, inputs, bundleURL) = try plannedBundle(run, projectDirectory: projectDirectory, force: force)
        let r1 = inputs[0]
        let recipe = try resolvedRecipe(plan.recipe)
        // The platform as the Mac decides it for a sample: the plan's request, resolved against the plan's inputs.
        let config = FASTQBatchImporter.sampleConfig(
            for: pair,
            config: importConfig(plan, recipe: recipe, projectDirectory: projectDirectory, paired: inputs.count > 1, force: force),
            log: nil
        )
        let metadataPairs = Dictionary(plan.sample.sampleSheet.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
        guard let statisticsTable = record.steps.first(where: { $0.kind == .statistics })?.standardOutput?.text else {
            throw refusal("steps", "The run record holds no seqkit stats output, so the bundle would hold no statistics. Nothing was imported.")
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
        // The mixed layout the node counted where it wrote the mixed file (the `interleave` step of a merging recipe).
        let mixed = record.steps.last { $0.storage?.mixedLayout != nil }?.storage?.mixedLayout.map {
            RecipeMixedLayoutCounts(mergedReads: $0.mergedReads, pairs: $0.pairs, unpairedReads: $0.unpairedReads)
        }
        let imported = FASTQBatchImporter.recordedPairing(
            pairing: config.pairing, r1: inputs.count > 1 ? r1 : stagedFASTQ, hasR2: inputs.count > 1
        )
        let pairing = recordedPairing(imported: imported, recipeRan: recipe != nil, mixedLayout: mixed)
        var metadata = PersistedFASTQMetadata()
        metadata.ingestion = IngestionMetadata(
            isClumpified: ingestionResult.wasClumpified, isCompressed: true, pairingMode: pairing.mode,
            pairingSource: pairing.source, qualityBinning: ingestionResult.qualityBinning.rawValue,
            originalFilenames: plan.sample.originalFilenames, ingestionDate: Date(),
            originalSizeBytes: plan.sample.originalSizeBytes, storageInputSizeBytes: ingestionResult.originalSizeBytes,
            storageOutputSizeBytes: ingestionResult.finalSizeBytes
        )
        // The Mac's read classification of the stored file, from the node's mixed layout.
        metadata.readClassification = FASTQBatchImporter.readClassification(
            forMixedLayout: FASTQBatchImporter.storedMixedLayout(mixed, removing: ingestionResult.readsRemovedByStorage),
            bundleFASTQName: fastqName
        )
        FASTQBatchImporter.applyPlatformMetadata(to: &metadata, config: config)
        // QV-18: each node step's envelope step carries the components and databases of its sidecar result, as the Mac's.
        var recipeOptions: [[String]: [String: ParameterValue]] = [:]
        if let recipe {
            let stepResults = try recipeStepResults(
                run, recipe: recipe, paired: inputs.count > 1, ingestionResult: ingestionResult, optimizeStorage: config.optimizeStorage
            )
            for result in stepResults {
                if let argv = result.commandArguments, !argv.isEmpty,
                   let options = FASTQBatchImporter.recipeResolvedOptions(for: result) { recipeOptions[argv] = options }
            }
            metadata.ingestion?.recipeApplied = RecipeAppliedInfo(
                recipeID: recipe.id, recipeName: recipe.name, appliedDate: Date(),
                stepResults: stepResults,
                recipeSHA256: recipe.sourceSHA256, recipeFormatVersion: recipe.formatVersion,
                requestedName: recipe.requestedName, presetID: recipe.resolution?.preset?.id,
                presetName: recipe.resolution?.preset?.name, switchSettings: recipe.switches.isEmpty ? nil : recipe.switchSettings
            )
        }
        FASTQMetadataStore.save(metadata, for: stagedFASTQ)
        // BIO O1: the record's statistics table and Q20 and Q30 counts through the Mac's own parse and count rule.
        let counts = record.steps.first { $0.kind == .qualityCount }?.qualityCounts
        try await FASTQBatchImporter.cacheStatistics(
            for: stagedFASTQ, seqkitStdout: statisticsTable,
            fractions: counts.map { FASTQQualityFractions(baseCount: $0.baseCount, q20Count: $0.q20Count, q30Count: $0.q30Count) }
        )

        let executorStep = executorStepExecution(record)
        let titles = Dictionary(plan.steps.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let nodeSteps = record.steps.flatMap { step in
            storageLaunchSteps(step, parent: executorStep.id)
                ?? [nodeStepExecution(step, parent: executorStep.id, title: titles[step.id], recipeOptions: recipeOptions[step.argv])]
        }
        try await FASTQBatchImporter.writeImportProvenance(
            pair: pair, processingPair: pair, materializationSteps: nodeSteps + [executorStep], unpairedReads: nil,
            config: config, importedPairing: pairing, stagingBundleURL: staging, stagingBundleFASTQURL: stagedFASTQ,
            publishedBundleURL: bundleURL, publishedBundleFASTQURL: bundleURL.appendingPathComponent(fastqName),
            sourceIngestionOutputURL: stagedFASTQ, ingestionResult: ingestionResult, recipeStepResults: [],
            runClock: ProvenanceRunClock(), statsStartedAt: Date(), statsCompletedAt: Date(), statsError: nil,
            adoption: ExecutorAdoptionProvenance(
                resolvedParameters: adoptedParameters(ingestionResult), childStepIDs: Set(nodeSteps.map(\.id)),
                argv: argv, runtime: runtimeIdentity(run), signingEnvironment: signingEnvironment
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
            // QV-24: the sample's own file names as the plan records them, never the plan folder's `inputs/` names.
            "originalFilenames": .array(result.originalFilenames.map(ParameterValue.string)),
        ]
    }

    /// QV-5: the pairing as the Mac records it after a recipe, of the recipe's output and not of its input. A recipe whose
    /// node wrote a mixed file records a detected `single_end` when the file holds any single read, so no tool pairs it
    /// by position, and a detected `interleaved` for pairs alone; any other run keeps the import's own record.
    static func recordedPairing(
        imported: FASTQBatchImporter.RecordedPairing, recipeRan: Bool, mixedLayout: RecipeMixedLayoutCounts?
    ) -> FASTQBatchImporter.RecordedPairing {
        guard recipeRan, let mixedLayout else { return imported }
        return FASTQBatchImporter.recordedPairing(afterRecipeOutput: .mixed, mixedLayout: mixedLayout, importedAs: imported)
    }

    /// The storage command as the Mac records it (QV-14): the clumpify launches joined by ` && `, or the step's argv.
    static func processingCommandLine(_ step: ExecutorStepRecord) -> String {
        let clumpify = (step.storage?.launches ?? []).filter { $0.tool.id == NativeTool.clumpify.executableName }
        guard !clumpify.isEmpty else { return step.argv.joined(separator: " ") }
        return clumpify.map { $0.argv.joined(separator: " ") }.joined(separator: " && ")
    }

    /// The storage step's launches as the Mac's envelope holds them (QV-15, QV-19, QV-21): each clumpify launch with its
    /// group count and memory lines, and the writer as `bgzip` with the `> <output>` the Mac's argv adds, each under the
    /// executor's step. The writer probe `-h` is left out, as the Mac's envelope holds none. Nil for a step with no
    /// launches, which keeps its one step.
    static func storageLaunchSteps(_ step: ExecutorStepRecord, parent: UUID) -> [StepExecution]? {
        guard step.kind == .storage, let launches = step.storage?.launches, !launches.isEmpty else { return nil }
        return launches.compactMap { launch -> StepExecution? in
            guard Array(launch.argv.dropFirst()) != ["-h"] else { return nil }
            var options = ProvenanceNodeStepOptions.options(
                toolID: launch.tool.id, version: launch.tool.version, build: launch.tool.build,
                versionSource: launch.tool.versionSource.rawValue, title: nil
            )
            var command = launch.argv
            if launch.tool.id == NativeTool.clumpify.executableName {
                options["clumpifyGroups"] = launch.clumpifyGroups.map(ParameterValue.integer)
                options["clumpifyMemoryEstimateLine"] = launch.clumpifyMemoryEstimateLine.map(ParameterValue.string)
                options["clumpifyMemoryAvailableLine"] = launch.clumpifyMemoryAvailableLine.map(ParameterValue.string)
            } else if launch.tool.id == NativeTool.bgzip.executableName, let output = step.outputs.first?.path {
                command += [">", output]
            }
            // QV-15: a compress launch is its own writer, so it states the record's writer by name, as the Mac's does.
            if let writer = step.storage?.writer, writer.name == launch.tool.id {
                options[FASTQStorageRecordKey.writer] = .dictionary(["name": .string(writer.name)])
            }
            return StepExecution(
                toolName: launch.tool.id, toolVersion: launch.tool.version, command: command, resolvedOptions: options,
                inputs: [], exitCode: launch.toolExitCode ?? (launch.outcome == .succeeded ? 0 : 1), wallTime: launch.wallSeconds,
                peakMemoryBytes: launch.peakResidentBytes, parentStepID: parent, managedToolID: managedToolID(launch.tool.path),
                startTime: date(step.startedAt) ?? Date(), endTime: date(step.endedAt)
            )
        }
    }

    /// The managed environment a tool ran from, the folder after `envs/` in its path (QV-19). The node's path names the
    /// environment the image holds the tool in, so the writer's may differ from the Mac's (QV-OQ1).
    static func managedToolID(_ path: String?) -> ManagedToolID? {
        let parts = (path ?? "").split(separator: "/").map(String.init)
        guard let envs = parts.lastIndex(of: "envs"), envs + 2 < parts.count else { return nil }
        return ManagedToolID(rawValue: parts[envs + 1])
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
            processingCommandLine: step.map(processingCommandLine),
            clumpifyHeapGB: clumpifyRan ? plan.storage.clumpifyHeapGB : nil
        )
    }

    /// The executor's step, the runner of every node step, from the record's `executor` block (XC-8).
    static func executorStepExecution(_ record: ExecutorRunRecord) -> StepExecution {
        StepExecution(
            toolName: executorToolName, toolVersion: record.executor.buildPin?.lgeVersion ?? "unknown",
            command: [executorBinaryName] + record.executorArguments, inputs: [], exitCode: record.exitCode,
            wallTime: record.wallSeconds, startTime: date(record.startedAt) ?? Date(), endTime: date(record.endedAt)
        )
    }

    /// The adopt's sample pair, its inputs and the bundle it publishes, by the import's own URL rule. A bundle already
    /// there is refused without `force`; the dry run calls this too, so it says what the adopt does (review A2 fix 1).
    static func plannedBundle(
        _ run: ExecutorAdoptedRun, projectDirectory: URL, force: Bool
    ) throws -> (pair: SamplePair, inputs: [URL], url: URL) {
        let inputs = run.plan.entries.filter { $0.role == .input }.map { run.folder.appendingPathComponent($0.relativePath) }
        guard let r1 = inputs.first else { throw refusal("entries", "The plan pins no input.") }
        let metadataPairs = Dictionary(run.plan.sample.sampleSheet.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
        let pair = SamplePair(sampleName: run.sampleName, r1: r1, r2: inputs.count > 1 ? inputs[1] : nil, metadata: metadataPairs)
        let url = FASTQBatchImporter.bundleOutputURL(for: pair, in: projectDirectory)
        if FileManager.default.fileExists(atPath: url.path) && !force {
            throw BatchImportError.outputBundleAlreadyExists(url)
        }
        return (pair, inputs, url)
    }

    /// One node step under the executor's step, with the argv, version and times the record states, and its tool in
    /// the record's shape under `resolvedOptions` (lane U, OQ-1), with the plan step's title on a step the executor ran.
    static func nodeStepExecution(
        _ step: ExecutorStepRecord, parent: UUID, title: String?, recipeOptions: [String: ParameterValue]? = nil
    ) -> StepExecution {
        var options = step.tool.map {
            ProvenanceNodeStepOptions.options(
                toolID: $0.id, version: $0.version, build: $0.build, versionSource: $0.versionSource.rawValue,
                title: $0.id == executorBinaryName ? title : nil
            )
        }
        if let recipeOptions { options = (options ?? [:]).merging(recipeOptions) { node, _ in node } }
        return StepExecution(
            toolName: step.tool?.id ?? executorBinaryName, toolVersion: step.tool?.version ?? "unknown", command: step.argv,
            resolvedOptions: options, inputs: [], exitCode: step.toolExitCode ?? (step.outcome == .succeeded ? 0 : 1), wallTime: step.wallSeconds,
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
