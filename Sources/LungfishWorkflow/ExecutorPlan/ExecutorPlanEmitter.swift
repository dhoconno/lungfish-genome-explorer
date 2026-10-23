// ExecutorPlanEmitter.swift - The executor plan of one sample, from the recipe engine's own planned steps (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
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

/// The storage values the user's import settled, before the plan writer fixes the clumping tool.
package struct ExecutorPlanStorageRequest: Sendable, Equatable {
    package var requestedClumpingTool: ClumpingTool
    package var clumpifyHeapGB: Int
    package var threads: Int
    package var statisticsThreads: Int
    package var compressor: PlanCompressor
    package var qualityBinning: QualityBinningScheme
    package var compressionLevel: Int
    package var threadsSource: ImportSettingSource
    package var clumpifyHeapSource: ImportSettingSource
    package var compressorSource: ImportSettingSource
    package var qualityBinningSource: ImportSettingSource

    package init(
        requestedClumpingTool: ClumpingTool, clumpifyHeapGB: Int, threads: Int, statisticsThreads: Int,
        compressor: PlanCompressor, qualityBinning: QualityBinningScheme, compressionLevel: Int,
        threadsSource: ImportSettingSource, clumpifyHeapSource: ImportSettingSource,
        compressorSource: ImportSettingSource, qualityBinningSource: ImportSettingSource
    ) {
        self.requestedClumpingTool = requestedClumpingTool
        self.clumpifyHeapGB = clumpifyHeapGB
        self.threads = threads
        self.statisticsThreads = statisticsThreads
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

/// Everything the plan of one sample is made from. `imageManifest` is the image tool manifest's `{sha256, size}` and
/// `imageTools` its tools, which the caller reads from the manifest (SWIFT round 3, Q-K4-1).
package struct ExecutorPlanRequest: Sendable {
    package var sample: PlanSampleValues
    /// R1 then R2, or the one file.
    package var inputs: [ExecutorPlanSourceFile]
    package var inputFormat: RecipeFileFormat
    package var recipe: PlanRecipeIdentity?
    package var recipeFile: ExecutorPlanSourceFile?
    /// The engine's own plan, `RecipeEngine.plan(recipe:inputFormat:)`, or none for an import with no recipe.
    package var plannedSteps: [PlannedStep]
    package var storage: ExecutorPlanStorageRequest
    package var executorFile: ExecutorPlanSourceFile
    package var executorBuild: PlanExecutorBuild
    package var imageManifest: PlanImageManifestPin
    package var imageTools: [PlanToolPin]
    package var deadlines: ExecutorPlanDeadlines

    package init(
        sample: PlanSampleValues, inputs: [ExecutorPlanSourceFile], inputFormat: RecipeFileFormat,
        recipe: PlanRecipeIdentity?, recipeFile: ExecutorPlanSourceFile?, plannedSteps: [PlannedStep],
        storage: ExecutorPlanStorageRequest, executorFile: ExecutorPlanSourceFile, executorBuild: PlanExecutorBuild,
        imageManifest: PlanImageManifestPin, imageTools: [PlanToolPin], deadlines: ExecutorPlanDeadlines
    ) {
        self.sample = sample
        self.inputs = inputs
        self.inputFormat = inputFormat
        self.recipe = recipe
        self.recipeFile = recipeFile
        self.plannedSteps = plannedSteps
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
    /// UX's round 3 sentence, the reason of every automatic clumping choice, never composed per sample.
    package static let automaticClumpingReason = "The automatic clumping choice names BBTools clumpify for every sample, at the plan's heap and with no size estimate, because clumpify's groups=auto compares its memory estimate for each input with the memory available in that heap and splits a large input into more groups."
    /// Tally K4.9, refused before any plan or batch.
    package static let trimGaloreRefusal = "Trim Galore storage does not run on CHTC yet. Choose Automatic, BBTools clumpify or Skip for a run on CHTC."
    /// The stem of every work file, so the plans of two samples differ only in their sample values and digests.
    package static let workStem = "sample"
    package static let executorPath = "bin/lungfish-executor"
    package static let payloadPath = "out/\(workStem).fastq.gz"
    package static let statisticsPath = "out/\(workStem).seqkit-stats.tsv"
    static let root = URL(fileURLWithPath: "/lungfish-plan-root", isDirectory: true)
    static let workspace = root.appendingPathComponent("work", isDirectory: true)

    /// The clumping entry. `auto` names `bbtools` at the plan's heap with no estimate and source `default`. A named
    /// `bbtools` or `none` goes through the Mac's own `ClumpingTool.resolve` at the pinned heap, source `option`.
    package static func clumpingChoice(
        requested: ClumpingTool, heapGB: Int, host: ExecutorPlanHostFacts
    ) throws -> PlanClumpingChoice {
        switch requested {
        case .auto:
            return PlanClumpingChoice(
                requested: .auto, resolved: .bbtools, resolvedSource: .default,
                heapBytes: Int64(heapGB) * 1_073_741_824, reason: automaticClumpingReason
            )
        case .trimGalore:
            throw ExecutorPlanError(field: "storage.clumpingTool", reason: trimGaloreRefusal)
        case .bbtools, .none:
            // A named tool reads no estimate, so 0 decides nothing and the plan carries none of it.
            let resolution = requested.resolve(
                estimatedInputBytes: 0, physicalMemoryBytes: host.physicalMemoryBytes, pinnedHeapGB: heapGB
            )
            guard let request = PlanClumpingRequest(rawValue: resolution.requested.rawValue),
                  let resolved = PlanClumpingTool(rawValue: resolution.resolved.rawValue) else {
                throw ExecutorPlanError(field: "storage.clumpingTool", reason: "The clumping tool \(requested.rawValue) has no plan form.")
            }
            return PlanClumpingChoice(
                requested: request, resolved: resolved, resolvedSource: .option,
                heapBytes: resolution.clumpifyHeapBytes, reason: resolution.reason
            )
        }
    }

    /// The plan, checked by the decoder's own rules, so the Mac refuses what the node would.
    package static func emit(_ request: ExecutorPlanRequest, host: ExecutorPlanHostFacts) throws -> ExecutionPlan {
        try emission(request, host: host).plan
    }

    package static func emission(_ request: ExecutorPlanRequest, host: ExecutorPlanHostFacts) throws -> ExecutorPlanEmission {
        let settings = request.storage
        let clumping = try clumpingChoice(requested: settings.requestedClumpingTool, heapGB: settings.clumpifyHeapGB, host: host)
        var sources: [String: URL] = [executorPath: request.executorFile.url]
        var entries = [PlanEntry(role: .executor, relativePath: executorPath, sha256: request.executorFile.sha256, size: request.executorFile.size)]
        if let recipe = request.recipe, let file = request.recipeFile {
            let path = "recipe/\(recipe.id).recipe.json"
            entries.append(PlanEntry(role: .recipe, relativePath: path, sha256: file.sha256, size: file.size))
            sources[path] = file.url
        }
        var inputURLs: [URL] = []
        for (index, file) in request.inputs.enumerated() {
            let path = "inputs/R\(index + 1)\(fastqSuffix(of: file.url.lastPathComponent))"
            entries.append(PlanEntry(role: .input, relativePath: path, sha256: file.sha256, size: file.size))
            sources[path] = file.url
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
        for (index, planned) in request.plannedSteps.enumerated() {
            let id = "recipe-\(index + 1)"
            let built = try recipeStep(planned, id: id, input: current, threads: settings.threads)
            let pin = try tools.pin(built.toolID, stepID: id)
            steps.append(PlanStep(
                id: id, title: built.title, kind: built.kind, tool: pin, arguments: built.arguments.map(relative),
                deadlineSeconds: request.deadlines.recipeStepSeconds, inputs: files(of: current),
                outputs: files(of: built.output) + built.auxiliary.map { relative($0.path) }
            ))
            current = built.output
        }
        let storageTool: String
        switch clumping.resolved {
        case .bbtools: storageTool = NativeTool.clumpify.executableName
        case .none: storageTool = settings.qualityBinning == .none ? settings.compressor.rawValue : NativeTool.reformat.executableName
        case .trimGalore: throw ExecutorPlanError(field: "storage.clumpingTool", reason: trimGaloreRefusal)
        }
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
            arguments: ["stats", "-a", "-T", "-j", "\(settings.statisticsThreads)", payloadPath],
            deadlineSeconds: request.deadlines.statisticsSeconds, inputs: [payloadPath], outputs: [],
            standardOutput: statisticsPath
        ))
        steps.append(PlanStep(
            id: "quality-count", title: "Count Q20 and Q30 bases", kind: .qualityCount, tool: nil, arguments: [],
            deadlineSeconds: request.deadlines.statisticsSeconds, inputs: [payloadPath], outputs: []
        ))
        let plan = ExecutionPlan(
            entries: entries, executor: request.executorBuild, imageManifest: request.imageManifest, tools: tools.used,
            recipe: request.recipe, sample: request.sample,
            storage: PlanStorageSettings(
                clumpingTool: clumping.resolved, compressor: settings.compressor, qualityBinning: settings.qualityBinning,
                threads: settings.threads, clumpifyHeapGB: settings.clumpifyHeapGB, compressionLevel: settings.compressionLevel,
                threadsSource: settings.threadsSource, clumpifyHeapSource: settings.clumpifyHeapSource,
                clumpingToolSource: clumping.resolvedSource, compressorSource: settings.compressorSource,
                qualityBinningSource: settings.qualityBinningSource
            ),
            clumping: clumping, statistics: PlanStatisticsSettings(threads: settings.statisticsThreads),
            graceSeconds: request.deadlines.graceSeconds, steps: steps
        )
        try plan.validate()
        return ExecutorPlanEmission(plan: plan, sources: sources)
    }

    private struct BuiltStep {
        var title: String
        var kind: PlanStepKind
        var toolID: String
        var arguments: [String]
        var output: StepInput
        var auxiliary: [URL] = []
    }

    private static func recipeStep(_ planned: PlannedStep, id: String, input: StepInput, threads: Int) throws -> BuiltStep {
        switch planned {
        case .singleStep(let executor, let label):
            guard let plannable = executor as? any RecipePlannableStep else {
                throw ExecutorPlanError(field: "steps", reason: "The recipe step \(type(of: executor).typeID) has no plan form yet, so this recipe cannot run from a plan.")
            }
            let run = try plannable.plannedInvocation(input: input, workspace: workspace, sampleName: workStem, threads: threads)
            return BuiltStep(title: label, kind: .recipe, toolID: run.tool.executableName, arguments: run.arguments,
                             output: run.output, auxiliary: run.auxiliaryOutputs)
        case .fusedFastp(let extraArgs, _, let label, _):
            guard let r2 = input.r2 else {
                throw RecipeEngineError.formatMismatch(expected: .pairedR1R2, got: input.format, step: "fused-fastp")
            }
            let (outR1, outR2) = RecipeEngine.fusedFastpOutputs(workspace: workspace, sampleName: workStem)
            let report = workspace.appendingPathComponent("\(workStem)_fused_fastp_report.json")
            let arguments = RecipeEngine.fusedFastpArguments(
                extraArgs: extraArgs, r1: input.r1, r2: r2, outR1: outR1, outR2: outR2, report: report, threads: threads
            )
            return BuiltStep(title: label, kind: .recipe, toolID: NativeTool.fastp.executableName, arguments: arguments,
                             output: StepInput(r1: outR1, r2: outR2, format: .pairedR1R2), auxiliary: [report])
        case .formatConversion(.pairedR1R2, .interleaved):
            guard let r2 = input.r2 else {
                throw RecipeEngineError.formatMismatch(expected: .pairedR1R2, got: input.format, step: "format-conversion")
            }
            let output = RecipeEngine.interleavedOutput(workspace: workspace, sampleName: workStem)
            return BuiltStep(
                title: "Format conversion (pairedR1R2 → interleaved)", kind: .interleave,
                toolID: NativeTool.reformat.executableName,
                arguments: RecipeEngine.pairedToInterleavedArguments(r1: input.r1, r2: r2, output: output, threads: threads),
                output: StepInput(r1: output, format: .interleaved)
            )
        case .formatConversion(.merged, .mixed):
            // The executor writes the mixed file with PortableMixedLayout, which reads each input through `gzip -dc`.
            let output = RecipeEngine.mixedOutput(workspace: workspace, sampleName: workStem)
            return BuiltStep(title: "Format conversion (merged → mixed)", kind: .interleave, toolID: "gzip",
                             arguments: [], output: StepInput(r1: output, format: .mixed))
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
            return pin
        }
    }

    private static func files(of input: StepInput) -> [String] {
        [input.r1, input.r2, input.r3].compactMap { $0 }.map { relative($0.path) }
    }

    /// An argument with the plan's work root removed, so every path in it is relative to the root (SWIFT N8).
    static func relative(_ argument: String) -> String {
        argument.replacingOccurrences(of: root.path + "/", with: "")
    }

    /// The FASTQ suffix of a file name, kept so a tool sees the compression it expects.
    static func fastqSuffix(of name: String) -> String {
        let lower = name.lowercased()
        for suffix in [".fastq.gz", ".fq.gz", ".fastq.bgz", ".fastq", ".fq", ".gz"] where lower.hasSuffix(suffix) {
            return suffix
        }
        return ".fastq"
    }
}
