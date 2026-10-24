// ExecutorRunAdoption+StepResults.swift - The adopted sidecar's recipe step results, in the Mac's order and fields (CHTC C4 lane A)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishPortable

extension ExecutorRunAdoption {
    /// The sidecar's step results as `RecipeEngine.execute` lists them on the Mac: the engine's own plan of the recipe
    /// walks the record's recipe steps, each step a switch turned off goes where it would have run (`tool` `none` and
    /// its `turnedOffBy`), and the storage result ends the list. The Mac's statistics result never reaches its sidecar,
    /// so none is written here.
    static func recipeStepResults(
        _ run: ExecutorAdoptedRun, recipe: Recipe?, paired: Bool, ingestionResult: FASTQIngestionResult, optimizeStorage: Bool
    ) throws -> [RecipeStepResult] {
        var results: [RecipeStepResult] = []
        if let recipe {
            // The Mac plans a recipe for a sample with an R2 as paired and for any other as single.
            let engine = RecipeEngine()
            let planned = try engine.plan(recipe: recipe, inputFormat: paired ? .pairedR1R2 : .single)
            var turnedOff = engine.turnedOffStepRecords(for: recipe)
            // The preflight refuses a record whose recipe steps this build's plan does not hold, through the same function.
            try claimedRecipeSteps(run, recipe: recipe, paired: paired)
            let recorded = run.record.steps.filter { $0.kind == .recipe }
            let consumed = Set(run.plan.steps.flatMap(\.inputs))
            for (index, plannedStep) in planned.enumerated() {
                if case .formatConversion = plannedStep { continue }
                // The emitter's ids: `recipe-<n>` for a planned step's process and `recipe-<n>-<m>` for its second one.
                let id = "recipe-\(index + 1)"
                let runs = recorded.filter { $0.id == id || $0.id.hasPrefix(id + "-") }
                var components: [RecipeLogicalComponent] = []
                if case .fusedFastp(_, _, _, let fused) = plannedStep { components = fused }
                results += turnedOff.before(plannedStep)
                for (runIndex, step) in runs.enumerated() {
                    // The Mac counts a logical step of several processes over its whole input on its first result, each
                    // mate of a paired process a read, and gives a later process no counts (QV-12, QV-13).
                    let counts: (input: Int?, output: Int?) = runs.count == 1
                        ? (step.inputReadCount.map(Int.init), step.outputReadCount.map(Int.init))
                        : runIndex == 0
                            ? (logicalReadCount(runs) { $0.inputReadCount.map(Int.init) },
                               logicalReadCount(runs) { $0.outputReadCount.map(Int.init) })
                            : (nil, nil)
                    let reports = try recordedReports(step, folder: run.folder, consumed: consumed)
                    results.append(recipeStepResult(
                        step, plan: run.plan, engine: engine, components: components,
                        // The Mac keeps a fastp step's read files and every file of a step's second process.
                        keepsOutputs: runIndex > 0 || step.tool?.id == NativeTool.fastp.executableName, consumed: consumed,
                        counts: counts, reports: reports
                    ))
                }
            }
            results += turnedOff.remaining()
        }
        if let storage = run.record.steps.first(where: { $0.kind == .storage }) {
            results.append(RecipeStepResult(
                stepName: optimizeStorage ? "Optimize storage + Compress" : "Compress",
                tool: ingestionResult.processingTool ?? "compression", toolVersion: ingestionResult.processingToolVersion,
                commandLine: ingestionResult.processingCommandLine, durationSeconds: storage.wallSeconds
            ))
        }
        return results
    }

    /// QV-7: a recipe process's reports, the record outputs no later plan step reads, as absolute paths in the returned
    /// folder. Each is read through the resolver the payload uses (AMV2 SWIFT fix 1): a relative path with no dot
    /// component, a real path inside the folder, a regular file of the record's size and SHA-256, so the bundle never keeps
    /// bytes the node did not write, and a path out of the folder or a link is refused. A report the folder lacks is refused
    /// as well (AMV2 SWIFT fix 2, BIO fix 1), as the Mac's import refuses a recipe run whose report is missing: the CHTC
    /// submit file returns every report at its `work/` path.
    static func recordedReports(_ step: ExecutorStepRecord, folder: URL, consumed: Set<String>) throws -> [String] {
        let resolver: PlanResourceResolver
        do {
            resolver = try PlanResourceResolver(workRoot: folder)
        } catch {
            throw refusal("folder", "The folder \(folder.lastPathComponent) cannot be read. \(error.localizedDescription)")
        }
        return try step.outputs.filter { !consumed.contains($0.path) }.map { output in
            let name = "The report \(output.path) of step \(step.id)"
            let verified: URL
            do {
                verified = try resolver.verify(
                    PlanEntry(role: .input, relativePath: output.path, sha256: output.sha256, size: Int64(clamping: output.bytes))
                )
            } catch let error as PlanResourceRefusal {
                switch error {
                case .missing:
                    throw refusal(
                        "steps",
                        "\(name) is in the run record but not in the returned folder. The Mac's import refuses a recipe run "
                            + "whose report is missing, so nothing was imported."
                    )
                case .digestMismatch, .sizeMismatch:
                    throw refusal(
                        "steps",
                        "\(name) does not hold the bytes the run record states (SHA-256 \(output.sha256)). Nothing was imported."
                    )
                default:
                    throw refusal("steps", "\(name) cannot be adopted. \(error.reason) Nothing was imported.")
                }
            }
            // The copy's name and the argv rewrite are keyed by the record's path, so a link is refused and never followed.
            guard verified.path == resolver.workRoot + "/" + output.path else {
                throw refusal("steps", "\(name) is a symbolic link. Nothing was imported.")
            }
            return folder.appendingPathComponent(output.path).path
        }
    }

    /// The preflight's read of every report the run record names for a recipe step (AMV2 BIO fix 1, ARCH Optional 2), through
    /// `recordedReports`, so the dry run refuses a run whose report is missing, linked or changed, as the adopt does before it
    /// copies any report.
    static func checkRecipeReports(_ run: ExecutorAdoptedRun) throws {
        let consumed = Set(run.plan.steps.flatMap(\.inputs))
        for step in run.record.steps where step.kind == .recipe {
            _ = try recordedReports(step, folder: run.folder, consumed: consumed)
        }
    }

    /// The Mac keys each report's rewrite by the argv token that named the report, its absolute work path. The node's
    /// argv names a report by its work-relative record path, so the adopt keys each rewrite by that path, and
    /// `durableReplayArgv` then names the bundle's copy as the Mac's does (QV-7).
    static func rewritesKeyedByRecordPath(_ results: [RecipeStepResult], folder: URL) -> [RecipeStepResult] {
        results.map { result in
            guard !result.auxiliaryCommandPathRewrites.isEmpty else { return result }
            let rewrites = Dictionary(
                result.auxiliaryCommandPathRewrites.map { key, value in
                    (CanonicalFilePath.relativePath(of: URL(fileURLWithPath: key), within: folder) ?? key, value)
                },
                uniquingKeysWith: { first, _ in first }
            )
            return result.replacingAuxiliaryOutputs(paths: result.auxiliaryOutputPaths, commandPathRewrites: rewrites)
        }
    }

    /// One recorded process as the Mac records it: the engine's quoting of its argv, the fused step's components, its
    /// read files by digest when the Mac keeps them (an output a later plan step reads, so never a report), its reports
    /// (absolute paths in the returned folder until the bundle copies them), and each database the plan pins whose path
    /// its argv names.
    static func recipeStepResult(
        _ step: ExecutorStepRecord, plan: ExecutionPlan, engine: RecipeEngine, components: [RecipeLogicalComponent],
        keepsOutputs: Bool, consumed: Set<String>, counts: (input: Int?, output: Int?), reports: [String] = []
    ) -> RecipeStepResult {
        let databases = plan.entries.compactMap { entry -> RecipeDatabaseRecord? in
            guard entry.role == .database, let identity = entry.database, step.argv.contains(entry.relativePath) else {
                return nil
            }
            return RecipeDatabaseRecord(
                id: identity.id, version: identity.version, fileName: URL(fileURLWithPath: entry.relativePath).lastPathComponent,
                indexFormat: Int(identity.format), kmerLength: identity.kmerLength, windowSize: identity.windowSize,
                sha256: entry.sha256, sizeBytes: Int64(entry.size), path: entry.relativePath,
                lockPinned: identity.lockPinned ?? false, buildSourceSHA256: identity.buildSourceSHA256,
                buildSourceSizeBytes: identity.buildSourceSizeBytes, buildToolVersion: identity.buildToolVersion
            )
        }
        let outputs = keepsOutputs ? step.outputs.filter { consumed.contains($0.path) }.map {
            RecipeStepOutputFile(path: $0.path, checksumSHA256: $0.sha256, sizeBytes: $0.bytes)
        } : []
        return RecipeStepResult(
            stepName: plan.steps.first { $0.id == step.id }?.title ?? step.id, tool: step.tool?.id ?? executorBinaryName,
            toolVersion: step.tool?.version, commandLine: step.argv.map(engine.shellEscapeForRecipeCommand).joined(separator: " "),
            commandArguments: step.argv, inputReadCount: counts.input,
            outputReadCount: counts.output, durationSeconds: step.wallSeconds, auxiliaryOutputPaths: reports,
            logicalComponents: components, executionOutputFiles: outputs, exitStatus: step.toolExitCode.map(Int.init),
            startedAt: date(step.startedAt), completedAt: date(step.endedAt), databases: databases
        )
    }

    /// A logical step's read count over its processes, as the Mac counts the step over its whole input: a process that
    /// reads a pair of files (`-I`) counts each pair as two reads. Nil when a process has no count.
    static func logicalReadCount(_ runs: [ExecutorStepRecord], _ count: (ExecutorStepRecord) -> Int?) -> Int? {
        var total = 0
        for step in runs {
            guard let value = count(step) else { return nil }
            total += step.argv.contains("-I") || step.argv.contains("--in2") ? 2 * value : value
        }
        return total
    }
}
