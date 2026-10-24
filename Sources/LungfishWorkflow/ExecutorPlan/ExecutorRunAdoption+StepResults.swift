// ExecutorRunAdoption+StepResults.swift - The adopted sidecar's recipe step results, in the Mac's order and fields (CHTC C4 lane A)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

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
            let recorded = run.record.steps.filter { $0.kind == .recipe }
            let consumed = Set(run.plan.steps.flatMap(\.inputs))
            var used = 0
            for (index, plannedStep) in planned.enumerated() {
                if case .formatConversion = plannedStep { continue }
                // The emitter's ids: `recipe-<n>` for a planned step's process and `recipe-<n>-<m>` for its second one.
                let id = "recipe-\(index + 1)"
                let runs = recorded.filter { $0.id == id || $0.id.hasPrefix(id + "-") }
                var components: [RecipeLogicalComponent] = []
                if case .fusedFastp(_, _, _, let fused) = plannedStep { components = fused }
                results += turnedOff.before(plannedStep)
                for (runIndex, step) in runs.enumerated() {
                    results.append(recipeStepResult(
                        step, plan: run.plan, engine: engine, components: components,
                        // The Mac keeps a fastp step's read files and every file of a step's second process.
                        keepsOutputs: runIndex > 0 || step.tool?.id == NativeTool.fastp.executableName, consumed: consumed
                    ))
                }
                used += runs.count
            }
            results += turnedOff.remaining()
            guard used == recorded.count else {
                throw refusal(
                    "steps",
                    "The run record holds recipe steps that this build's plan of recipe \(recipe.id) does not hold. Nothing was imported."
                )
            }
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

    /// One recorded process as the Mac records it: the engine's quoting of its argv, the fused step's components, its
    /// read files by digest when the Mac keeps them (an output a later plan step reads, so never a report), and each
    /// database the plan pins whose path its argv names.
    static func recipeStepResult(
        _ step: ExecutorStepRecord, plan: ExecutionPlan, engine: RecipeEngine, components: [RecipeLogicalComponent],
        keepsOutputs: Bool, consumed: Set<String>
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
            commandArguments: step.argv, inputReadCount: step.inputReadCount.map(Int.init),
            outputReadCount: step.outputReadCount.map(Int.init), durationSeconds: step.wallSeconds,
            logicalComponents: components, executionOutputFiles: outputs, exitStatus: step.toolExitCode.map(Int.init),
            startedAt: date(step.startedAt), completedAt: date(step.endedAt), databases: databases
        )
    }
}
