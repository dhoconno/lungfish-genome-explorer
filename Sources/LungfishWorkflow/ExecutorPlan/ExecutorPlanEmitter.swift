// ExecutorPlanEmitter.swift - The executor plan of one sample, from the recipe engine's own planned steps (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishPortable

/// The host's facts the plan writer is handed. It has no default that reads `ProcessInfo`, so a test can show that two
/// Macs write the same plan (QA round 3, N2-T2). The plan's rule reads neither value for `auto`.
package struct ExecutorPlanHostFacts: Sendable, Equatable {
    package var physicalMemoryBytes: Int64
    package var processorCount: Int

    package init(physicalMemoryBytes: Int64, processorCount: Int) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.processorCount = processorCount
    }
}

/// A file on the Mac that the plan folder will hold, with the SHA-256 and size the plan pins.
package struct ExecutorPlanSourceFile: Sendable, Equatable {
    package var url: URL
    package var sha256: String
    package var size: Int64

    package init(url: URL, sha256: String, size: Int64) {
        self.url = url
        self.sha256 = sha256
        self.size = size
    }

    /// Reads `url` once for its SHA-256 and size.
    package static func measuring(_ url: URL) throws -> ExecutorPlanSourceFile {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let digest = try PortableDigest.sha256Hex(reading: handle)
        let size = try handle.seekToEnd()
        return ExecutorPlanSourceFile(url: url, sha256: digest, size: Int64(size))
    }
}

/// A database index file the plan folder will hold, with the identity its `database` entry carries. It is made only
/// from the engine's `RecipeDatabaseRecord`, which `RecipeDatabaseIdentity.record(databaseID:at:)` checks against the
/// bundled lock, so a stale or stand-in index under a pinned id is refused before any plan exists (BIO review fix 5).
package struct ExecutorPlanDatabaseFile: Sendable, Equatable {
    package var file: ExecutorPlanSourceFile
    package var identity: PlanDatabaseIdentity

    package init(record: RecipeDatabaseRecord) {
        file = ExecutorPlanSourceFile(url: URL(fileURLWithPath: record.path), sha256: record.sha256, size: record.sizeBytes)
        identity = PlanDatabaseIdentity(
            id: record.id, version: record.version, format: record.indexFormat.map { String($0) } ?? "unknown",
            kmerLength: record.kmerLength, windowSize: record.windowSize, lockPinned: record.lockPinned,
            buildSourceSHA256: record.buildSourceSHA256, buildSourceSizeBytes: record.buildSourceSizeBytes,
            buildToolVersion: record.buildToolVersion
        )
    }
}

/// The storage values the user's import settled, before the plan writer fixes the clumping tool.
package struct ExecutorPlanStorageRequest: Sendable, Equatable {
    package var requestedClumpingTool: ClumpingTool
    package var clumpifyHeapGB: Int
    package var threads: Int
    package var compressor: PlanCompressor
    package var qualityBinning: QualityBinningScheme
    package var compressionLevel: Int
    package var threadsSource: ImportSettingSource
    package var clumpifyHeapSource: ImportSettingSource
    package var compressorSource: ImportSettingSource
    package var qualityBinningSource: ImportSettingSource

    package init(
        requestedClumpingTool: ClumpingTool, clumpifyHeapGB: Int, threads: Int,
        compressor: PlanCompressor, qualityBinning: QualityBinningScheme, compressionLevel: Int,
        threadsSource: ImportSettingSource, clumpifyHeapSource: ImportSettingSource,
        compressorSource: ImportSettingSource, qualityBinningSource: ImportSettingSource
    ) {
        self.requestedClumpingTool = requestedClumpingTool
        self.clumpifyHeapGB = clumpifyHeapGB
        self.threads = threads
        self.compressor = compressor
        self.qualityBinning = qualityBinning
        self.compressionLevel = compressionLevel
        self.threadsSource = threadsSource
        self.clumpifyHeapSource = clumpifyHeapSource
        self.compressorSource = compressorSource
        self.qualityBinningSource = qualityBinningSource
    }
}

/// Each step's deadline and the grace the plan fixes (tally-r2 K4-06), never the Mac's input-size rule.
package struct ExecutorPlanDeadlines: Sendable, Equatable {
    package var recipeStepSeconds: Double
    package var storageSeconds: Double
    package var statisticsSeconds: Double
    package var graceSeconds: Double

    package init(recipeStepSeconds: Double, storageSeconds: Double, statisticsSeconds: Double, graceSeconds: Double) {
        self.recipeStepSeconds = recipeStepSeconds
        self.storageSeconds = storageSeconds
        self.statisticsSeconds = statisticsSeconds
        self.graceSeconds = graceSeconds
    }
}

/// Everything the plan of one sample is made from, the template request of its recipe and its sample row together
/// (`templateRequest` and `sampleRow()` in ExecutorPlanFill.swift). `imageManifest` is the image tool manifest's
/// `{sha256, size}` and `imageTools` its tools, which the caller reads from the manifest (SWIFT round 3, Q-K4-1).
package struct ExecutorPlanRequest: Sendable {
    package var sample: PlanSampleValues
    /// R1 then R2, or the one file.
    package var inputs: [ExecutorPlanSourceFile]
    package var inputFormat: RecipeFileFormat
    /// The resolved recipe, with the switches and preset `RecipeResolver` set, or nil for an import with no recipe.
    /// The emitter plans it with the engine's own `RecipeEngine.plan(recipe:inputFormat:)` and states its identity.
    package var recipe: Recipe?
    /// The recipe's file, which the plan pins as its `recipe` entry. It is given with `recipe` or not at all.
    package var recipeFile: ExecutorPlanSourceFile?
    package var storage: ExecutorPlanStorageRequest
    package var executorFile: ExecutorPlanSourceFile
    package var executorBuild: PlanExecutorBuild
    package var imageManifest: PlanImageManifestPin
    package var imageTools: [PlanToolPin]
    package var deadlines: ExecutorPlanDeadlines
    /// Each database a recipe step reads, by the step's database id, such as the Deacon panhuman and ribokmers indexes.
    package var databases: [String: ExecutorPlanDatabaseFile]

    package init(
        sample: PlanSampleValues, inputs: [ExecutorPlanSourceFile], inputFormat: RecipeFileFormat,
        recipe: Recipe?, recipeFile: ExecutorPlanSourceFile?,
        storage: ExecutorPlanStorageRequest, executorFile: ExecutorPlanSourceFile, executorBuild: PlanExecutorBuild,
        imageManifest: PlanImageManifestPin, imageTools: [PlanToolPin], deadlines: ExecutorPlanDeadlines,
        databases: [String: ExecutorPlanDatabaseFile] = [:]
    ) {
        self.databases = databases
        self.sample = sample
        self.inputs = inputs
        self.inputFormat = inputFormat
        self.recipe = recipe
        self.recipeFile = recipeFile
        self.storage = storage
        self.executorFile = executorFile
        self.executorBuild = executorBuild
        self.imageManifest = imageManifest
        self.imageTools = imageTools
        self.deadlines = deadlines
    }
}

/// Why the Mac cannot write a plan, naming the field.
package struct ExecutorPlanError: Error, Equatable, Sendable, LocalizedError {
    package var field: String
    package var reason: String

    package init(field: String, reason: String) {
        self.field = field
        self.reason = reason
    }

    package var errorDescription: String? { reason }
}

/// A plan and the Mac file each of its entries is staged from. The plan itself holds no Mac path.
package struct ExecutorPlanEmission: Sendable {
    package let plan: ExecutionPlan
    /// Entry `relativePath` to the Mac file the folder writer copies there.
    package let sources: [String: URL]
}

/// Builds the plan of one sample from the recipe engine's `[PlannedStep]`. It reads no file and writes nothing
/// (ARCH round 3, ruling 2), and the folder writer stages and writes what it returns.
package enum ExecutorPlanEmitter {
    /// The stem of every work file, so the plans of two samples differ only in their sample values and digests.
    package static let workStem = "sample"
    package static let executorPath = "bin/lungfish-executor"
    package static let payloadPath = "out/\(workStem).fastq.gz"
    package static let statisticsPath = "out/\(workStem).seqkit-stats.tsv"
    static let root = URL(fileURLWithPath: "/lungfish-plan-root", isDirectory: true)
    static let workspace = root.appendingPathComponent("work", isDirectory: true)

    /// The platform a plan names, or nil when it names none (`--platform auto`, which the plan writer cannot decide
    /// without reading the reads), so the platform restricts nothing and `auto` clumps as it does for short reads.
    static func namedPlatform(_ name: String?) -> LungfishIO.SequencingPlatform? {
        guard let name, case .given(let platform)? = ImportPlatformRequest(cliValue: name) else { return nil }
        return platform
    }

    /// The clumping entry, from the one rule the Mac's import calls too, `ClumpingTool.resolve`, at the plan's pinned
    /// heap (C5 O49, D5, D8 B). `auto` is decided platform first: short reads clump with BBTools clumpify at the clumpify
    /// heap with no estimate, and ONT, PacBio and Unknown reads clump nothing, both with source `default`. A named
    /// `bbtools`, `trim-galore` or `none` wins on every platform with source `option`, and Trim Galore's entry carries
    /// the notice the local import logs before its storage step (ARCH A5).
    package static func clumpingChoice(
        requested: ClumpingTool, heapGB: Int, host: ExecutorPlanHostFacts,
        platform: LungfishIO.SequencingPlatform? = nil
    ) throws -> PlanClumpingChoice {
        // The estimate is read by no decision of the plan, so 0 decides nothing and the plan carries none of it.
        let resolution = requested.resolve(
            estimatedInputBytes: 0, physicalMemoryBytes: host.physicalMemoryBytes, pinnedHeapGB: heapGB,
            platform: platform
        )
        guard let request = PlanClumpingRequest(rawValue: resolution.requested.rawValue),
              let resolved = PlanClumpingTool(rawValue: resolution.resolved.rawValue) else {
            throw ExecutorPlanError(field: "storage.clumpingTool", reason: "The clumping tool \(requested.rawValue) has no plan form.")
        }
        return PlanClumpingChoice(
            requested: request, resolved: resolved, resolvedSource: resolution.resolvedSource,
            heapBytes: resolution.clumpifyHeapBytes, reason: resolution.reason,
            operationNotice: resolution.resolved.operationNotice
        )
    }

    /// The plan, checked by the decoder's own rules, so the Mac refuses what the node would.
    package static func emit(_ request: ExecutorPlanRequest, host: ExecutorPlanHostFacts) throws -> ExecutionPlan {
        try emission(request, host: host).plan
    }

    /// One sample's plan: the template of the request's recipe, filled with the request's sample (ARCH-fill F5).
    package static func emission(_ request: ExecutorPlanRequest, host: ExecutorPlanHostFacts) throws -> ExecutorPlanEmission {
        let recipeTemplate = try Self.template(request.templateRequest, host: host)
        return try recipeTemplate.emission(for: request.sampleRow())
    }

    /// The template of one recipe for every sample of one input shape (V5): the engine's planned steps, the tool pins,
    /// the settings and the executor, recipe and database entries, with one slot per input. It reads no input file.
    package static func template(_ request: ExecutorPlanTemplateRequest, host: ExecutorPlanHostFacts) throws -> ExecutorPlanTemplate {
        let settings = request.storage
        let clumping = try clumpingChoice(
            requested: settings.requestedClumpingTool, heapGB: settings.clumpifyHeapGB, host: host,
            platform: namedPlatform(request.platform)
        )
        let plannedSteps: [PlannedStep]
        let recipeIdentity: PlanRecipeIdentity?
        switch (request.recipe, request.recipeFile) {
        case (nil, nil):
            plannedSteps = []
            recipeIdentity = nil
        case (let recipe?, let file?):
            plannedSteps = try RecipeEngine().plan(recipe: recipe, inputFormat: request.inputFormat)
            recipeIdentity = PlanRecipeIdentity(recipe: recipe, sourceSHA256: file.sha256)
        default:
            throw ExecutorPlanError(field: "recipe", reason: "A plan request gives a recipe and its file together, or neither.")
        }
        var sources: [String: URL] = [executorPath: request.executorFile.url]
        var entries = [PlanEntry(role: .executor, relativePath: executorPath, sha256: request.executorFile.sha256, size: request.executorFile.size)]
        if let recipeIdentity, let file = request.recipeFile {
            let path = "recipe/\(recipeIdentity.id).recipe.json"
            entries.append(PlanEntry(role: .recipe, relativePath: path, sha256: file.sha256, size: file.size))
            sources[path] = file.url
        }
        var slots: [PlanInputSlot] = []
        var inputURLs: [URL] = []
        for (index, suffix) in request.inputSuffixes.enumerated() {
            let path = "inputs/R\(index + 1)\(suffix)"
            slots.append(PlanInputSlot(relativePath: path))
            inputURLs.append(root.appendingPathComponent(path))
        }
        guard let first = inputURLs.first else {
            throw ExecutorPlanError(field: "entries", reason: "A plan needs at least one input file.")
        }
        var current = StepInput(
            r1: first, r2: inputURLs.count > 1 ? inputURLs[1] : nil, r3: inputURLs.count > 2 ? inputURLs[2] : nil,
            format: request.inputFormat
        )
        var tools = ToolPins(available: request.imageTools)
        var steps: [PlanStep] = []
        var databaseURLs: [String: URL] = [:]
        for (index, planned) in plannedSteps.enumerated() {
            if case .singleStep(let executor, _) = planned, let plannable = executor as? any RecipePlannableStep {
                for databaseID in plannable.plannedDatabaseIDs where databaseURLs[databaseID] == nil {
                    guard let database = request.databases[databaseID] else {
                        throw ExecutorPlanError(field: "entries", reason: "The recipe step \(type(of: executor).typeID) reads the database \(databaseID), which the plan request does not hold.")
                    }
                    let path = "databases/\(databaseID)/\(database.file.url.lastPathComponent)"
                    entries.append(PlanEntry(role: .database, relativePath: path, sha256: database.file.sha256,
                                             size: database.file.size, database: database.identity))
                    sources[path] = database.file.url
                    databaseURLs[databaseID] = root.appendingPathComponent(path)
                }
            }
            let built = try recipeStep(planned, input: current, threads: settings.threads, databases: databaseURLs)
            for (runIndex, run) in built.runs.enumerated() {
                // A step with a second process (the length filter's pair pass) gets one plan step per process, as
                // the in-process run gets one record per process.
                let id = runIndex == 0 ? "recipe-\(index + 1)" : "recipe-\(index + 1)-\(runIndex + 1)"
                steps.append(PlanStep(
                    id: id, title: run.title, kind: run.kind, tool: try (run.toolID == "gzip" ? tools.pinDecompressor(stepID: id) : tools.pin(run.toolID, stepID: id)),
                    arguments: run.arguments.map(withoutPlanRoot), deadlineSeconds: request.deadlines.recipeStepSeconds,
                    inputs: run.inputs, outputs: run.outputs
                ))
            }
            current = built.output
        }
        let storageTool: String
        switch clumping.resolved {
        case .bbtools: storageTool = NativeTool.clumpify.executableName
        case .none: storageTool = settings.qualityBinning == .none ? settings.compressor.rawValue : NativeTool.reformat.executableName
        case .trimGalore:
            storageTool = NativeTool.trimGalore.executableName
            // The Trim Galore route interleaves a paired output with reformat.sh (PortableStorageStep+TrimGalore).
            _ = try tools.pin(NativeTool.reformat.executableName, stepID: "storage")
        }
        // Every route pins the compressor (BIO N3). clumpify.sh and reformat.sh write through bgzip, a mixed file's
        // clumped halves are joined by it (PortableStorageStep.clumpify), the Trim Galore route compresses plain or
        // joined output with it, and the route none with no binning stores with it alone. A repeated pin is skipped.
        _ = try tools.pin(settings.compressor.rawValue, stepID: "storage")
        let heapOption = PlanEnvironmentVariable(name: "_JAVA_OPTIONS", value: "-Xmx\(settings.clumpifyHeapGB)g")
        // The executor builds the storage argv on the node through PortableStorageStep, the builder the Mac uses,
        // once it has read the layout of the recipe's output, which no plan can know.
        steps.append(PlanStep(
            id: "storage", title: "Store reads", kind: .storage, tool: try tools.pin(storageTool, stepID: "storage"),
            arguments: [], environment: clumping.resolved == .bbtools ? [heapOption] : [],
            deadlineSeconds: request.deadlines.storageSeconds, inputs: files(of: current), outputs: [payloadPath]
        ))
        steps.append(PlanStep(
            id: "statistics", title: "Compute statistics", kind: .statistics,
            tool: try tools.pin(NativeTool.seqkit.executableName, stepID: "statistics"),
            // The Mac's own call, `FASTQBatchImporter.computeAndCacheStatistics`, passes no `-j`, so neither does the
            // plan, and seqkit's own default starts one worker for the one file.
            arguments: ["stats", "-a", "-T", payloadPath],
            deadlineSeconds: request.deadlines.statisticsSeconds, inputs: [payloadPath], outputs: [],
            standardOutput: statisticsPath
        ))
        steps.append(PlanStep(
            id: "quality-count", title: "Count Q20 and Q30 bases", kind: .qualityCount, tool: nil, arguments: [],
            deadlineSeconds: request.deadlines.statisticsSeconds, inputs: [payloadPath], outputs: []
        ))
        let planTemplate = PlanTemplate(
            entries: entries, inputs: slots, executor: request.executorBuild, imageManifest: request.imageManifest,
            tools: tools.used, recipe: recipeIdentity, platform: request.platform,
            storage: PlanStorageSettings(
                clumpingTool: clumping.resolved, compressor: settings.compressor, qualityBinning: settings.qualityBinning,
                threads: settings.threads, clumpifyHeapGB: settings.clumpifyHeapGB, compressionLevel: settings.compressionLevel,
                threadsSource: settings.threadsSource, clumpifyHeapSource: settings.clumpifyHeapSource,
                clumpingToolSource: clumping.resolvedSource, compressorSource: settings.compressorSource,
                qualityBinningSource: settings.qualityBinningSource
            ),
            clumping: clumping,
            graceSeconds: request.deadlines.graceSeconds, steps: steps
        )
        // The fill checks the plan by the decoder's own rules once a sample's values are in it.
        return ExecutorPlanTemplate(template: planTemplate, sources: sources)
    }

    /// One process of a recipe step, as one plan step.
    private struct BuiltRun {
        var title: String
        var kind: PlanStepKind
        var toolID: String
        var arguments: [String]
        /// Paths relative to the work root.
        var inputs: [String]
        /// The reads it leaves, then its reports, relative to the work root.
        var outputs: [String]

        init(title: String, kind: PlanStepKind, toolID: String, arguments: [String], input: StepInput,
             output: StepInput, auxiliary: [URL] = []) {
            self.init(title: title, kind: kind, toolID: toolID, arguments: arguments,
                      inputs: ExecutorPlanEmitter.files(of: input),
                      outputs: ExecutorPlanEmitter.files(of: output) + auxiliary.map { ExecutorPlanEmitter.withoutPlanRoot($0.path) })
        }

        init(title: String, kind: PlanStepKind, toolID: String, arguments: [String], inputs: [String], outputs: [String]) {
            self.title = title
            self.kind = kind
            self.toolID = toolID
            self.arguments = arguments
            self.inputs = inputs
            self.outputs = outputs
        }
    }

    private struct BuiltStep {
        var runs: [BuiltRun]
        var output: StepInput
    }

    private static func recipeStep(
        _ planned: PlannedStep, input: StepInput, threads: Int, databases: [String: URL]
    ) throws -> BuiltStep {
        switch planned {
        case .singleStep(let executor, let label):
            guard let plannable = executor as? any RecipePlannableStep else {
                throw ExecutorPlanError(field: "steps", reason: "The recipe step \(type(of: executor).typeID) has no plan form yet, so this recipe cannot run from a plan.")
            }
            let run = try plannable.plannedRun(
                input: input, workspace: workspace, sampleName: workStem, threads: threads, databases: databases
            )
            let runs = run.invocations.map { invocation in
                BuiltRun(
                    title: invocation.label.map { "\(label) (\($0))" } ?? label, kind: .recipe,
                    toolID: invocation.tool.executableName, arguments: invocation.arguments,
                    inputs: invocation.inputs.map { withoutPlanRoot($0.path) },
                    outputs: files(of: invocation.output) + invocation.auxiliaryOutputs.map { withoutPlanRoot($0.path) }
                )
            }
            return BuiltStep(runs: runs, output: run.output)
        case .fusedFastp(let extraArgs, _, let label, _):
            guard let r2 = input.r2 else {
                throw RecipeEngineError.formatMismatch(expected: .pairedR1R2, got: input.format, step: "fused-fastp")
            }
            let (outR1, outR2) = RecipeEngine.fusedFastpOutputs(workspace: workspace, sampleName: workStem)
            let report = workspace.appendingPathComponent("\(workStem)_fused_fastp_report.json")
            let arguments = RecipeEngine.fusedFastpArguments(
                extraArgs: extraArgs, r1: input.r1, r2: r2, outR1: outR1, outR2: outR2, report: report, threads: threads
            )
            let output = StepInput(r1: outR1, r2: outR2, format: .pairedR1R2)
            return BuiltStep(runs: [BuiltRun(
                title: label, kind: .recipe, toolID: NativeTool.fastp.executableName, arguments: arguments,
                input: input, output: output, auxiliary: [report]
            )], output: output)
        case .formatConversion(.pairedR1R2, .interleaved):
            guard let r2 = input.r2 else {
                throw RecipeEngineError.formatMismatch(expected: .pairedR1R2, got: input.format, step: "format-conversion")
            }
            let file = RecipeEngine.interleavedOutput(workspace: workspace, sampleName: workStem)
            let output = StepInput(r1: file, format: .interleaved)
            return BuiltStep(runs: [BuiltRun(
                title: "Format conversion (pairedR1R2 → interleaved)", kind: .interleave,
                toolID: NativeTool.reformat.executableName,
                arguments: RecipeEngine.pairedToInterleavedArguments(r1: input.r1, r2: r2, output: file, threads: threads),
                input: input, output: output
            )], output: output)
        case .formatConversion(.merged, .mixed):
            // The executor writes the mixed file with PortableMixedLayout, which reads each input through `gzip -dc`.
            let output = StepInput(r1: RecipeEngine.mixedOutput(workspace: workspace, sampleName: workStem), format: .mixed)
            return BuiltStep(runs: [BuiltRun(
                title: "Format conversion (merged → mixed)", kind: .interleave, toolID: "gzip", arguments: [],
                input: input, output: output
            )], output: output)
        case .formatConversion(let from, let to):
            throw ExecutorPlanError(field: "steps", reason: "The conversion from \(from.rawValue) to \(to.rawValue) has no plan form yet, so this recipe cannot run from a plan.")
        }
    }

    /// The tools the plan pins, in the order its steps first run them.
    private struct ToolPins {
        let available: [PlanToolPin]
        var used: [PlanToolPin] = []

        mutating func pin(_ id: String, stepID: String) throws -> PlanToolPin {
            guard let pin = available.first(where: { $0.id == id }) else {
                throw ExecutorPlanError(field: "tools", reason: "The image's tool manifest lists no \(id), which step \(stepID) runs.")
            }
            if !used.contains(pin) { used.append(pin) }
            // A BBTools wrapper finds its Java through PATH, so the plan pins the manifest's java beside it, and an image
            // with none is refused before a plan is written (SWIFT Q-K4-3).
            if id.hasSuffix(".sh") { _ = try self.pin("java", stepID: stepID) }
            return pin
        }

        /// The merged-to-mixed step reads its inputs through `<decompressor> -dc`. The executor takes the manifest's
        /// gzip, else its pigz (`RunCommand`), so the plan pins the same tool. The C0 image and the Mac's managed
        /// environments hold pigz and no conda gzip (lane K4, M5b).
        mutating func pinDecompressor(stepID: String) throws -> PlanToolPin {
            try pin(available.contains { $0.id == "gzip" } ? "gzip" : "pigz", stepID: stepID)
        }
    }

    private static func files(of input: StepInput) -> [String] {
        [input.r1, input.r2, input.r3].compactMap { $0 }.map { withoutPlanRoot($0.path) }
    }

    /// Removes the plan's placeholder work root from an argument string, including a value such as `in=<root>/work/x`.
    /// The root is a name that is not on disk, so no URL helper applies (SWIFT N8).
    static func withoutPlanRoot(_ argument: String) -> String {
        argument.replacingOccurrences(of: root.path + "/", with: "")
    }
}

extension PlanRecipeIdentity {
    /// The identity of the resolved `recipe` as the Mac's import record states it: the name passed, the preset, each
    /// switch's value and source, and each step a switch turned off (BIO-r3 R8, BIO review fix 1 of K4 part A).
    init(recipe: Recipe, sourceSHA256: String) {
        self.init(
            id: recipe.id, name: recipe.name, requestedName: recipe.requestedName, formatVersion: recipe.formatVersion,
            sourceSHA256: sourceSHA256, presetID: recipe.resolution?.preset?.id, presetName: recipe.resolution?.preset?.name,
            switches: recipe.switchSettings.map {
                PlanRecipeSwitch(id: $0.id, label: $0.label, value: $0.value, source: "\($0.source)")
            },
            turnedOffSteps: recipe.turnedOffSteps.map {
                PlanTurnedOffStep(
                    stepType: $0.step.type, label: $0.step.label, activeStepsBefore: $0.activeStepsBefore, switchID: $0.setting.id
                )
            }
        )
    }
}
