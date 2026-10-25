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
    /// The sample's input records as the preflight checked them, with the plan's SHA-256 and size, so the import hashes no
    /// input: a CHTC job returns none (ARCH-X3 R-2).
    var inputs: [FileRecord]
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
        // Every refusal that needs no bundle file comes first, and the dry run makes the same call (AMV1 SWIFT fix 1).
        let (pair, inputs, inputRecords, bundleURL, recipe, statisticsTable) = try preflight(
            run, projectDirectory: projectDirectory, force: force
        )
        let r1 = inputs[0]
        // The platform as the Mac decides it for a sample: the plan's request, resolved against the plan's R1. A folder that
        // holds no R1 keeps a named platform and states that no inference ran (review R1-R2 fix 1); the preflight has refused
        // a plan that leaves the platform to inference.
        let config = platformResolved(
            importConfig(plan, recipe: recipe, projectDirectory: projectDirectory, paired: inputs.count > 1, force: force),
            for: pair, readsReturned: holdsItem(at: r1)
        )
        let metadataPairs = Dictionary(plan.sample.sampleSheet.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })

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
        var recipeResults: [[String]: RecipeStepResult] = [:]
        if let recipe {
            // QV-7: the bundle keeps each step's reports where the Mac's import copies them, by the Mac's own code, and
            // each copy takes the sample's name in place of the plan's work stem, as an import's copy does (C4-4 D-3). The
            // step's argv keeps the node's name, and its rewrite maps that name to the copy.
            let stepResults = rewritesKeyedByRecordPath(
                try FASTQBatchImporter.materializeRecipeAuxiliaryOutputs(
                    recipeStepResults(
                        run, recipe: recipe, paired: inputs.count > 1, ingestionResult: ingestionResult,
                        optimizeStorage: config.optimizeStorage
                    ),
                    stagingBundleURL: staging, publishedBundleURL: bundleURL,
                    stem: (work: ExecutorPlanEmitter.workStem, sample: pair.sampleName)
                ),
                folder: run.folder
            )
            for result in stepResults {
                guard let argv = result.commandArguments, !argv.isEmpty else { continue }
                recipeResults[argv] = result
                if let options = FASTQBatchImporter.recipeResolvedOptions(for: result) { recipeOptions[argv] = options }
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
        // C4-4 D-5: the storage writer and the statistics step name the bundle's payload where the node wrote its own.
        let payload: BundlePayload = (path: run.payload.relativePath, bundleFASTQ: stagedFASTQ)
        // QV-23: a recipe step's replay argv, inputs and outputs come from the Mac's one code path for its sidecar result.
        let nodeSteps = record.steps.flatMap { step in
            storageLaunchSteps(step, parent: executorStep.id, payload: step.kind == .storage ? payload : nil) ?? [nodeStepExecution(
                step, parent: executorStep.id, title: titles[step.id], recipeOptions: recipeOptions[step.argv],
                recipeFiles: recipeResults[step.argv].map {
                    FASTQBatchImporter.recipeProvenanceFiles(
                        for: $0, command: step.argv, originalInputURLs: inputs, bundleFASTQURL: stagedFASTQ,
                        stagingBundleURL: staging, publishedBundleURL: bundleURL, inputRecords: inputRecords
                    )
                },
                payload: step.kind == .statistics ? payload : nil
            )]
        }
        try await FASTQBatchImporter.writeImportProvenance(
            pair: pair, processingPair: pair, materializationSteps: nodeSteps + [executorStep], unpairedReads: nil,
            config: config, importedPairing: pairing, stagingBundleURL: staging, stagingBundleFASTQURL: stagedFASTQ,
            publishedBundleURL: bundleURL, publishedBundleFASTQURL: bundleURL.appendingPathComponent(fastqName),
            sourceIngestionOutputURL: stagedFASTQ, ingestionResult: ingestionResult, recipeStepResults: [],
            runClock: ProvenanceRunClock(), statsStartedAt: Date(), statsCompletedAt: Date(), statsError: nil,
            adoption: ExecutorAdoptionProvenance(
                resolvedParameters: adoptedParameters(ingestionResult), childStepIDs: Set(nodeSteps.map(\.id)),
                argv: argv, runtime: runtimeIdentity(run), signingEnvironment: signingEnvironment, inputs: inputRecords
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
    /// executor's step. The writer probe `-h` is left out, as the Mac's envelope holds none. The interleave step's
    /// decompressor launches are steps the same way, one for each gzip input with the plan pin's tool id (C4-3 C-3).
    /// Each step lists the files its launch read and wrote with their SHA-256 (QV-23). Nil for a step with no launches,
    /// which keeps its one step.
    static func storageLaunchSteps(_ step: ExecutorStepRecord, parent: UUID, payload: BundlePayload? = nil) -> [StepExecution]? {
        guard step.kind == .storage || step.kind == .interleave, let launches = step.storage?.launches, !launches.isEmpty else {
            return nil
        }
        func files(_ digests: [ExecutorFileDigest]?, role: FileRole) -> [FileRecord] {
            (digests ?? []).map {
                bundlePayloadFile(
                    FileRecord(path: $0.relativePath, sha256: $0.sha256, sizeBytes: UInt64(clamping: $0.size), format: .fastq, role: role),
                    payload
                )
            }
        }
        // The interleave step's own output, the mixed file, is the recorded output of the decompressor step that ends it (AMV2
        // ARCH fix 4); the earlier ones list none, since a reader writes into a pipe.
        let last = launches.lastIndex { Array($0.argv.dropFirst()) != ["-h"] }
        return launches.enumerated().compactMap { index, launch -> StepExecution? in
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
            } else if step.kind == .storage, launch.tool.id == NativeTool.bgzip.executableName, let output = step.outputs.first?.path {
                // Only the storage writer redirects into its output (AMV2 SWIFT fix 3); a `bgzip -dc` reader writes to a pipe.
                command += [">", output]
            }
            let mixed = step.kind == .interleave && index == last ? step.outputs.map {
                FileRecord(path: $0.path, sha256: $0.sha256, sizeBytes: UInt64(clamping: $0.bytes), format: .fastq, role: .output)
            } : []
            // QV-15: a compress launch is its own writer, so it states the record's writer by name, as the Mac's does.
            if let writer = step.storage?.writer, writer.name == launch.tool.id {
                options[FASTQStorageRecordKey.writer] = .dictionary(["name": .string(writer.name)])
            }
            return StepExecution(
                toolName: launch.tool.id, toolVersion: launch.tool.version, command: command,
                durableReplayArgv: bundlePayloadArgv(command, payload), resolvedOptions: options,
                inputs: files(launch.inputs, role: .input), outputs: files(launch.outputs, role: .output) + mixed,
                exitCode: launch.toolExitCode ?? (launch.outcome == .succeeded ? 0 : 1), wallTime: launch.wallSeconds,
                peakMemoryBytes: launch.peakResidentBytes, parentStepID: parent, managedToolID: managedToolID(launch.tool),
                startTime: date(step.startedAt) ?? Date(), endTime: date(step.endedAt)
            )
        }
    }

    /// The node's payload path, `out/<payload>` as the run record names it, and the bundle's staged payload file.
    typealias BundlePayload = (path: String, bundleFASTQ: URL)

    /// C4-4 D-5 (option 2): the replay argv of a step whose argv names the node's payload, the argv with that token, and
    /// only a token equal to it, naming the bundle's file; nil for a step whose argv does not name it. The storage writer
    /// and the statistics step both call it, and the argv itself stays as the node ran it. The import's staging rewrite
    /// then turns the staged file into the published bundle path, as it does the Mac's own payload, so the record names
    /// where the file now is.
    static func bundlePayloadArgv(_ argv: [String], _ payload: BundlePayload?) -> [String]? {
        guard let payload, argv.contains(payload.path) else { return nil }
        return argv.map { $0 == payload.path ? payload.bundleFASTQ.path : $0 }
    }

    /// A file record of the node's payload path as the bundle's payload, with its own digest, size, format and role; any
    /// other record is kept. The run's own output names the same staged file, so the envelope lists the payload once.
    static func bundlePayloadFile(_ file: FileRecord, _ payload: BundlePayload?) -> FileRecord {
        guard let payload, file.path == payload.path else { return file }
        return FileRecord(path: payload.bundleFASTQ.path, sha256: file.sha256, sizeBytes: file.sizeBytes, format: file.format, role: file.role)
    }

    /// The lock entry a tool ran from (QV-19). A program of the form `<tool-root>/envs/<name>/bin/<tool>` names its
    /// environment (C4-3 C-4, AMV2 SWIFT fix 5). A tool whose version and build the node read from the image manifest names
    /// the one linux-64 lock entry that lists the tool and pins that version and build (ARCH-X3 R-1). Any other tool names
    /// none: a `planPin` version, a tool under `/usr/bin` and a build the lock does not pin.
    static func managedToolID(_ tool: ExecutorToolRecord?) -> ManagedToolID? {
        guard let tool else { return nil }
        let parts = tool.path.split(separator: "/").map(String.init)
        if let envs = parts.lastIndex(of: "envs"), envs + 3 < parts.count, parts[envs + 2] == "bin" {
            return ManagedToolID(rawValue: parts[envs + 1])
        }
        // The image holds every tool at one path, so the lock names the environment. A plan pin is the plan's word and not
        // what the node read (XC-4 B), and the version and build keep `java`, which the bbtools entry lists, off that entry.
        guard tool.versionSource == .imageManifest, let lock = ManagedToolLock.bundledLinux64Resource?.lock else { return nil }
        let entries = lock.tools.filter { entry in
            // `<channel>::<package>=<version>=<build>`, the spec of one conda package.
            let fields = (entry.packageSpec.components(separatedBy: "::").last ?? "").components(separatedBy: "=")
            return entry.executables.contains(tool.id) && fields.count == 3 && fields[1] == tool.version && fields[2] == tool.build
        }
        return entries.count == 1 ? ManagedToolID(rawValue: entries[0].id) : nil
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
            platform: platformRequest(plan),
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

    /// Every refusal of the adopt that needs no bundle file, in the order the adopt meets them, for the dry run and the adopt
    /// alike (AMV1 SWIFT fix 1, BIO fix 2): the bundle's place, each input against the plan's pin (ARCH-X3 R-2), the reads an
    /// automatic platform is inferred from (review R1-R2 fix 1), the recipe this build holds, the record's seqkit table (present, and a table the Mac's parse reads, refused with the statistics
    /// step's index) and the recipe steps the plan claims. It writes nothing, so a run it passes can still fail on a write
    /// but never on a record it could have read.
    static func preflight(
        _ run: ExecutorAdoptedRun, projectDirectory: URL, force: Bool
    ) throws -> (pair: SamplePair, inputs: [URL], inputRecords: [FileRecord], url: URL, recipe: Recipe?, statistics: String) {
        let (pair, inputs, url) = try plannedBundle(run, projectDirectory: projectDirectory, force: force)
        let inputRecords = try checkedInputs(run, inputs: inputs)
        try requireReadsForInferredPlatform(run, inputs: inputs)
        let recipe = try resolvedRecipe(run.plan.recipe)
        let index = run.record.steps.firstIndex { $0.kind == .statistics }
        let field = index.map { "steps[\($0)]" } ?? "steps"
        guard let index, let statistics = run.record.steps[index].standardOutput?.text else {
            throw refusal(field, "The run record holds no seqkit stats output, so the bundle would hold no statistics.")
        }
        do {
            _ = try FASTQBatchImporter.parseRequiredSeqkitStats(stdout: statistics)
        } catch {
            throw refusal(field, "The run record's seqkit stats output is not a table the import reads. \(error.localizedDescription)")
        }
        if let recipe {
            try claimedRecipeSteps(run, recipe: recipe, paired: inputs.count > 1)
            // AMV2 BIO fix 1: a report the run record names must be in the folder with the record's bytes, as the adopt demands.
            try checkRecipeReports(run)
        }
        return (pair, inputs, inputRecords, url, recipe, statistics)
    }

    /// ARCH-X3 R-2: each input's file record at the path the adopt names, with the plan's SHA-256 and size. A CHTC job reads
    /// its inputs from /staging and returns none, so the digest and size come from the record's checked input of the same
    /// path, which must be the plan's pin. A file the folder holds there is hashed, and must be the pin too, so the Mac
    /// replay and a folder with copied inputs keep the check; no other input is read. The field is the plan's input index.
    static func checkedInputs(_ run: ExecutorAdoptedRun, inputs: [URL]) throws -> [FileRecord] {
        let pins = run.plan.entries.filter { $0.role == .input }
        return try zip(pins, inputs).enumerated().map { index, item -> FileRecord in
            let (pin, url) = item
            let field = "inputs[\(index)]"
            let stated = run.record.inputs.first { $0.relativePath == pin.relativePath }
            if let stated, stated.sha256 != pin.sha256 || stated.size != pin.size {
                throw refusal(
                    field,
                    "The run record states SHA-256 \(stated.sha256) and \(stated.size) bytes for the input \(pin.relativePath), "
                        + "and the plan pins \(pin.sha256) and \(pin.size) bytes."
                )
            }
            let record = FileRecord(
                path: url.path, sha256: pin.sha256, sizeBytes: UInt64(clamping: pin.size),
                format: FASTQBatchImporter.provenanceFormat(for: url), role: .input
            )
            // Any item at the path is present, a link that leads nowhere as well, so it is read and never passed over.
            guard holdsItem(at: url) else {
                guard stated != nil else {
                    throw refusal(
                        field,
                        "The run record states no digest for the input \(pin.relativePath), and the folder does not hold it. "
                            + "Copy the file the plan pins (SHA-256 \(pin.sha256), \(pin.size) bytes) to \(url.path) and adopt again."
                    )
                }
                return record
            }
            let file: ProvenanceFileDescriptor
            do {
                file = try ProvenanceFileDescriptor.file(url: url, role: .input)
            } catch {
                throw refusal(
                    field,
                    "The file \(url.path) cannot be read. Remove it, and the adopt takes the input's digest from the run record, "
                        + "or make it readable."
                )
            }
            let digest = file.checksumSHA256 ?? "none"
            let size = file.fileSize.map { Int64(clamping: $0) } ?? -1
            guard digest == pin.sha256, size == pin.size else {
                throw refusal(
                    field,
                    "The file \(url.path) has SHA-256 \(digest) and \(size) bytes, and the plan pins \(pin.sha256) and \(pin.size) "
                        + "bytes. Remove it, or replace it with the plan's input, and adopt again."
                )
            }
            return record
        }
    }

    /// Whether any item sits at `url`. A link that leads nowhere counts, because `attributesOfItem` is an lstat, so the inputs
    /// check, the platform check and the platform's resolution agree on which inputs the folder holds.
    static func holdsItem(at url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// The platform the plan requests: its `--platform` value, and `auto` when the plan states none the import reads.
    static func platformRequest(_ plan: ExecutionPlan) -> ImportPlatformRequest {
        plan.sample.platform.flatMap(ImportPlatformRequest.init(cliValue:)) ?? .auto
    }

    /// Review R1-R2 fix 1 (a), BIO 4. The Mac decides an automatic platform from the first reads of R1, and a CHTC job returns
    /// none, so the adopt would record an Unknown platform with no read class and print nothing. It refuses instead and names
    /// the file to copy. A plan that names the platform needs no read here (`platformResolved`). The dry run takes this
    /// refusal by calling `preflight`.
    static func requireReadsForInferredPlatform(_ run: ExecutorAdoptedRun, inputs: [URL]) throws {
        guard case .auto = platformRequest(run.plan), let r1 = inputs.first, !holdsItem(at: r1),
              let pin = run.plan.entries.first(where: { $0.role == .input }) else { return }
        throw refusal(
            "platform",
            "The plan leaves the platform to be inferred from the reads, and the folder does not hold \(r1.path). "
                + "Copy the file the plan pins (SHA-256 \(pin.sha256), \(pin.size) bytes) there and adopt again."
        )
    }

    /// What the envelope's `platformEvidence` and the sidecar's `platformAssignment` say when a plan named the platform and the
    /// folder holds no R1 to infer it from.
    static let platformNotInferredEvidence = "The returned folder holds no reads, so the platform was not inferred from them."

    /// The import's configuration with the sample's platform decided: as the Mac decides it, from the plan's request and R1
    /// (`sampleConfig`), unless R1 is absent from the folder and the plan names the platform (review R1-R2 fix 1 (b), BIO 4).
    /// Then the platform stays the plan's, with the read class it implies and the source `given`, and the inference is stated
    /// as not run: confidence `none`, one evidence line, no vendor detail and no sampled record. The Mac's own inference is
    /// held by no record, so none is taken from anywhere, and the evidence of a missing file ("No complete FASTQ records
    /// could be read.") is not left to read as a damaged one.
    static func platformResolved(
        _ config: FASTQBatchImporter.ImportConfig, for pair: SamplePair, readsReturned: Bool
    ) -> FASTQBatchImporter.ImportConfig {
        guard !readsReturned, case .given(let platform) = config.platformRequest else {
            return FASTQBatchImporter.sampleConfig(for: pair, config: config, log: nil)
        }
        return config.resolved(with: ImportPlatformResolution(
            platform: platform, readClass: FASTQAssemblyReadType(sequencingPlatform: platform), source: .given,
            inference: PlatformInference(
                platform: .unknown, readClass: nil, confidence: .none, evidence: [platformNotInferredEvidence], sampledRecords: 0
            ),
            contradiction: nil
        ))
    }

    /// The recipe steps the plan claims: the engine's plan of the recipe, as the Mac plans it for this sample, takes the record's
    /// `recipe-<n>` process for each planned step and its `recipe-<n>-<m>` second one, and a record that holds a recipe step no
    /// planned step takes is refused. The preflight and `recipeStepResults` both call it.
    static func claimedRecipeSteps(_ run: ExecutorAdoptedRun, recipe: Recipe, paired: Bool) throws {
        let planned = try RecipeEngine().plan(recipe: recipe, inputFormat: paired ? .pairedR1R2 : .single)
        let recorded = run.record.steps.filter { $0.kind == .recipe }
        var used = 0
        for (index, plannedStep) in planned.enumerated() {
            if case .formatConversion = plannedStep { continue }
            let id = "recipe-\(index + 1)"
            used += recorded.filter { $0.id == id || $0.id.hasPrefix(id + "-") }.count
        }
        guard used == recorded.count else {
            throw refusal(
                "steps",
                "The run record holds recipe steps that this build's plan of recipe \(recipe.id) does not hold. Nothing was imported."
            )
        }
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
    /// A recipe step takes its replay argv, inputs and outputs from `FASTQBatchImporter.recipeProvenanceFiles`. The
    /// statistics step takes `payload` (C4-4 D-5): its replay argv names the bundle's payload, and it lists the file it
    /// read, the record's `inputFile`, as its input at that path, as the Mac's statistics step lists the payload.
    static func nodeStepExecution(
        _ step: ExecutorStepRecord, parent: UUID, title: String?, recipeOptions: [String: ParameterValue]? = nil,
        recipeFiles: (durableReplayArgv: [String]?, inputs: [FileRecord], outputs: [FileRecord])? = nil,
        payload: BundlePayload? = nil
    ) -> StepExecution {
        let payloadInput = payload == nil ? [] : (step.inputFile.map {
            [bundlePayloadFile(
                FileRecord(path: $0.relativePath, sha256: $0.sha256, sizeBytes: UInt64(clamping: $0.size), format: .fastq, role: .input),
                payload
            )]
        } ?? [])
        var options = step.tool.map {
            ProvenanceNodeStepOptions.options(
                toolID: $0.id, version: $0.version, build: $0.build, versionSource: $0.versionSource.rawValue,
                title: $0.id == executorBinaryName ? title : nil
            )
        }
        if let recipeOptions { options = (options ?? [:]).merging(recipeOptions) { node, _ in node } }
        return StepExecution(
            toolName: step.tool?.id ?? executorBinaryName, toolVersion: step.tool?.version ?? "unknown", command: step.argv,
            durableReplayArgv: recipeFiles?.durableReplayArgv ?? bundlePayloadArgv(step.argv, payload), resolvedOptions: options,
            inputs: recipeFiles?.inputs ?? payloadInput,
            outputs: recipeFiles?.outputs ?? [], exitCode: step.toolExitCode ?? (step.outcome == .succeeded ? 0 : 1), wallTime: step.wallSeconds,
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
