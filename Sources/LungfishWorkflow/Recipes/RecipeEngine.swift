// RecipeEngine.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import os.log

// MARK: - RecipeExecutionResult

/// Result of executing a recipe, containing the final output and per-step provenance records.
public struct RecipeExecutionResult: Sendable {
    /// The final output of the last recipe step.
    public let output: StepOutput
    /// Per-step provenance records capturing tool invocations, timing, and read counts.
    public let stepRecords: [RecipeStepResult]
}

// MARK: - PlannedStep

/// A single entry in the execution plan produced by ``RecipeEngine/plan(recipe:inputFormat:)``.
public enum PlannedStep: Sendable {
    /// A regular single-step execution.
    case singleStep(any RecipeStepExecutor, label: String)
    /// Two or more consecutive ``FastpFusible`` steps merged into one fastp invocation.
    case fusedFastp(args: [String], inputFormat: RecipeFileFormat, label: String)
    /// A format-conversion step inserted automatically by the planner.
    case formatConversion(from: RecipeFileFormat, to: RecipeFileFormat)
}

// MARK: - RecipeEngine

/// Validates, plans, and executes ``Recipe`` pipelines.
///
/// The engine supports three major operations:
/// - ``validate(recipe:inputFormat:)`` — static validation (types, format chain).
/// - ``plan(recipe:inputFormat:)`` — produces an optimised ``[PlannedStep]``, fusing
///   consecutive ``FastpFusible`` steps and inserting format-conversion steps where needed.
/// - ``execute(recipe:input:context:)`` — runs the planned steps end-to-end.
public final class RecipeEngine: Sendable {

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.lungfish", category: "RecipeEngine")

    /// Registry mapping step `typeID` → executor metatype.
    private let stepTypes: [String: any RecipeStepExecutor.Type]

    // MARK: - Init

    public init() {
        let types: [any RecipeStepExecutor.Type] = [
            FastpDedupStep.self,
            FastpTrimStep.self,
            DeaconScrubStep.self,
            DeaconRiboFilterStep.self,
            RiboDetectorStep.self,
            FastpMergeStep.self,
            SeqkitLengthFilterStep.self,
        ]
        var registry: [String: any RecipeStepExecutor.Type] = [:]
        for t in types { registry[t.typeID] = t }
        self.stepTypes = registry
    }

    // MARK: - Validate

    /// Validates the recipe against the given input format.
    ///
    /// Checks:
    /// 1. The `inputFormat` satisfies the recipe's ``Recipe/InputRequirement``.
    /// 2. Every step type string is registered.
    /// 3. The format chain is internally consistent (by calling ``plan(recipe:inputFormat:)``).
    ///
    /// - Throws: ``RecipeEngineError`` on any validation failure.
    public func validate(recipe: Recipe, inputFormat: RecipeFileFormat) throws {
        // 1. Input requirement check
        try checkInputRequirement(recipe.requiredInput, actual: inputFormat)

        // 2. All step types must be registered
        for step in recipe.steps {
            guard stepTypes[step.type] != nil else {
                throw RecipeEngineError.unknownStepType(step.type)
            }
        }

        // 3. Validate format chain via planner (discards the result)
        _ = try plan(recipe: recipe, inputFormat: inputFormat)
    }

    // MARK: - Plan

    /// Builds an optimised execution plan for the recipe.
    ///
    /// Consecutive ``FastpFusible`` steps that share the same
    /// `.pairedR1R2 → .pairedR1R2` format are merged into a single
    /// `.fusedFastp` entry.  Format-conversion steps are inserted
    /// automatically whenever the current format does not match what
    /// the next executor expects.
    ///
    /// - Throws: ``RecipeEngineError`` if a step type is unknown or the
    ///   format chain cannot be satisfied.
    public func plan(recipe: Recipe, inputFormat: RecipeFileFormat) throws -> [PlannedStep] {
        // Instantiate all executors
        var executors: [(executor: any RecipeStepExecutor, step: RecipeStep)] = []
        for recipeStep in recipe.steps {
            guard let Type = stepTypes[recipeStep.type] else {
                throw RecipeEngineError.unknownStepType(recipeStep.type)
            }
            let executor = try Type.init(params: recipeStep.params)
            executors.append((executor, recipeStep))
        }

        var plan: [PlannedStep] = []
        var currentFormat = inputFormat
        var i = 0

        while i < executors.count {
            let (executor, step) = executors[i]

            // Determine the format this executor needs
            let neededFormat = effectiveInputFormat(for: executor, currentFormat: currentFormat)

            // Insert a conversion if the current format doesn't match
            if currentFormat != neededFormat {
                guard canConvert(from: currentFormat, to: neededFormat) else {
                    throw RecipeEngineError.incompatibleFormatChain(
                        from: currentFormat, to: neededFormat, step: step.type)
                }
                plan.append(.formatConversion(from: currentFormat, to: neededFormat))
                currentFormat = neededFormat
            }

            // Try to fuse consecutive FastpFusible steps
            if let fusible = executor as? any FastpFusible,
               fusible.inputFormat == .pairedR1R2,
               fusible.outputFormat == .pairedR1R2,
               currentFormat == .pairedR1R2 {

                // Collect as many consecutive fusible steps as possible
                var fusedArgs = fusible.fastpArgs()
                var fusionLabels = [step.label ?? type(of: executor).displayName]
                var j = i + 1

                while j < executors.count {
                    let (nextExecutor, nextStep) = executors[j]
                    guard let nextFusible = nextExecutor as? any FastpFusible,
                          nextFusible.inputFormat == .pairedR1R2,
                          nextFusible.outputFormat == .pairedR1R2 else {
                        break
                    }
                    fusedArgs += nextFusible.fastpArgs()
                    fusionLabels.append(nextStep.label ?? type(of: nextExecutor).displayName)
                    j += 1
                }

                let fusionSpan = j - i
                if fusionSpan > 1 {
                    // Emit a fused step
                    plan.append(.fusedFastp(
                        args: fusedArgs,
                        inputFormat: .pairedR1R2,
                        label: fusionLabels.joined(separator: " + ")
                    ))
                    currentFormat = .pairedR1R2
                    i = j
                    continue
                }
            }

            // Emit a single step
            let label = step.label ?? type(of: executor).displayName
            plan.append(.singleStep(executor, label: label))
            currentFormat = executor.outputFormat
            i += 1
        }

        return plan
    }

    // MARK: - Execute

    /// Executes the recipe against `input`, producing a ``RecipeExecutionResult``
    /// containing the final output and per-step provenance records.
    ///
    /// The engine calls ``plan(recipe:inputFormat:)`` first, then iterates the
    /// plan, converting ``StepOutput`` back to ``StepInput`` between steps.
    /// Intermediate files (inside the workspace) are deleted after each step completes.
    ///
    /// - Throws: ``RecipeEngineError`` or any error thrown by a step executor.
    public func execute(
        recipe: Recipe,
        input: StepInput,
        context: StepContext
    ) async throws -> RecipeExecutionResult {
        let steps = try plan(recipe: recipe, inputFormat: input.format)

        var currentOutput = StepOutput(
            r1: input.r1,
            r2: input.r2,
            r3: input.r3,
            format: input.format
        )

        // Count only non-format-conversion steps for progress reporting
        let reportableStepCount = steps.filter {
            if case .formatConversion = $0 { return false }
            return true
        }.count
        var reportableStepIndex = 0

        var stepRecords: [RecipeStepResult] = []
        var previousReadCount: Int? = nil

        for plannedStep in steps {
            let stepInput = StepInput(
                r1: currentOutput.r1,
                r2: currentOutput.r2,
                r3: currentOutput.r3,
                format: currentOutput.format
            )
            // Capture input files for cleanup after step completes
            let previousFiles = [stepInput.r1, stepInput.r2, stepInput.r3].compactMap { $0 }

            let stepStart = Date()
            var stepLabel: String

            switch plannedStep {
            case .singleStep(let executor, let label):
                stepLabel = label
                logger.debug("Executing step: \(label)")
                let fraction = reportableStepCount > 0
                    ? Double(reportableStepIndex) / Double(reportableStepCount)
                    : 0.0
                context.progress(fraction, label)
                currentOutput = try await executor.execute(input: stepInput, context: context)
                reportableStepIndex += 1

            case .fusedFastp(let extraArgs, _, let label):
                stepLabel = label
                logger.debug("Executing fused fastp: \(label)")
                let fraction = reportableStepCount > 0
                    ? Double(reportableStepIndex) / Double(reportableStepCount)
                    : 0.0
                context.progress(fraction, label)
                currentOutput = try await executeFusedFastp(
                    args: extraArgs,
                    input: stepInput,
                    context: context,
                    label: label
                )
                reportableStepIndex += 1

            case .formatConversion(let from, let to):
                stepLabel = "Format conversion (\(from.rawValue) → \(to.rawValue))"
                logger.debug("Converting format \(from.rawValue) → \(to.rawValue)")
                currentOutput = try await executeFormatConversion(
                    from: from,
                    to: to,
                    input: stepInput,
                    context: context
                )
            }

            let stepDuration = Date().timeIntervalSince(stepStart)

            // Build provenance record (skip format-conversion steps — internal bookkeeping)
            if case .formatConversion = plannedStep {
                // skip recording
            } else {
                let toolName = currentOutput.tool?.executableName ?? "internal"
                let toolVersion: String?
                if let t = currentOutput.tool {
                    toolVersion = await context.runner.getToolVersion(t)
                } else {
                    toolVersion = nil
                }
                let commandLine: String?
                if let args = currentOutput.arguments, let execName = currentOutput.tool?.executableName {
                    commandLine = execName + " " + args.joined(separator: " ")
                } else {
                    commandLine = nil
                }

                stepRecords.append(RecipeStepResult(
                    stepName: stepLabel,
                    tool: toolName,
                    toolVersion: toolVersion,
                    commandLine: commandLine,
                    inputReadCount: previousReadCount,
                    outputReadCount: currentOutput.readCount,
                    durationSeconds: stepDuration
                ))
                previousReadCount = currentOutput.readCount
            }

            // Delete previous step's intermediate files (only those inside the workspace)
            let workspacePath = context.workspace.path
            for file in previousFiles where file.path.hasPrefix(workspacePath) {
                try? FileManager.default.removeItem(at: file)
            }
        }

        return RecipeExecutionResult(output: currentOutput, stepRecords: stepRecords)
    }

    // MARK: - Private helpers

    /// Returns the input format the executor actually expects, accounting for
    /// ``SeqkitLengthFilterStep``'s ability to accept any single-stream format.
    private func effectiveInputFormat(
        for executor: any RecipeStepExecutor,
        currentFormat: RecipeFileFormat
    ) -> RecipeFileFormat {
        // SeqkitLengthFilterStep accepts any single-stream format.
        // If the current format is merged (or single/interleaved), route only r1
        // by converting merged → single first.
        if executor is SeqkitLengthFilterStep {
            switch currentFormat {
            case .single, .interleaved:
                return .single
            case .merged, .pairedR1R2:
                // merged needs explicit conversion; pairedR1R2 needs interleave or concat
                return .single
            }
        }
        return executor.inputFormat
    }

    /// Returns whether the engine can convert between two ``RecipeFileFormat`` values.
    private func canConvert(from: RecipeFileFormat, to: RecipeFileFormat) -> Bool {
        switch (from, to) {
        case (.pairedR1R2, .interleaved): return true
        case (.interleaved, .pairedR1R2): return true
        case (.merged, .single):          return true
        case let (a, b) where a == b:    return true
        default:                          return false
        }
    }

    /// Runs a single fused fastp invocation combining `extraArgs` from multiple steps.
    private func executeFusedFastp(
        args extraArgs: [String],
        input: StepInput,
        context: StepContext,
        label: String
    ) async throws -> StepOutput {
        guard let r2 = input.r2 else {
            throw RecipeEngineError.formatMismatch(
                expected: .pairedR1R2, got: input.format, step: "fused-fastp")
        }

        let outR1 = context.workspace.appendingPathComponent(
            "\(context.sampleName)_fused_R1.fq.gz")
        let outR2 = context.workspace.appendingPathComponent(
            "\(context.sampleName)_fused_R2.fq.gz")

        var args = [
            "-i", input.r1.path,
            "-I", r2.path,
            "-o", outR1.path,
            "-O", outR2.path,
        ]
        args += extraArgs
        args += [
            "-w", "\(context.threads)",
            "-j", "/dev/null",
            "-h", "/dev/null",
        ]

        let result = try await context.runner.run(
            .fastp,
            arguments: args,
            timeout: context.recipeToolTimeout(for: .fastp, input: input)
        )
        if result.exitCode != 0 {
            throw RecipeEngineError.toolFailed(
                tool: "fastp", step: "fused-fastp(\(label))", stderr: result.stderr)
        }

        return StepOutput(r1: outR1, r2: outR2, format: .pairedR1R2, tool: .fastp, arguments: args)
    }

    /// Performs a format conversion between two compatible ``RecipeFileFormat`` values.
    private func executeFormatConversion(
        from: RecipeFileFormat,
        to: RecipeFileFormat,
        input: StepInput,
        context: StepContext
    ) async throws -> StepOutput {
        switch (from, to) {
        case (.pairedR1R2, .interleaved):
            return try await convertPairedToInterleaved(input: input, context: context)

        case (.interleaved, .pairedR1R2):
            return try await convertInterleavedToPaired(input: input, context: context)

        case (.merged, .single):
            return try await convertMergedToSingle(input: input, context: context)

        default:
            throw RecipeEngineError.incompatibleFormatChain(
                from: from, to: to, step: "format-conversion")
        }
    }

    /// reformat.sh: paired R1/R2 → interleaved
    private func convertPairedToInterleaved(
        input: StepInput,
        context: StepContext
    ) async throws -> StepOutput {
        guard let r2 = input.r2 else {
            throw RecipeEngineError.formatMismatch(
                expected: .pairedR1R2, got: input.format, step: "format-conversion")
        }

        let output = context.workspace.appendingPathComponent(
            "\(context.sampleName)_interleaved.fq.gz")

        let env = await bbToolsEnvironment()
        let args = [
            "in=\(input.r1.path)",
            "in2=\(r2.path)",
            "out=\(output.path)",
            "interleaved=t",
            "threads=\(context.threads)",
            "ow=t",
        ]

        let result = try await context.runner.run(
            .reformat,
            arguments: args,
            environment: env,
            timeout: context.recipeToolTimeout(for: .reformat, input: input)
        )
        if result.exitCode != 0 {
            throw RecipeEngineError.toolFailed(
                tool: "reformat.sh", step: "format-conversion(pairedR1R2→interleaved)",
                stderr: result.stderr)
        }

        return StepOutput(r1: output, format: .interleaved, tool: .reformat, arguments: args)
    }

    /// reformat.sh: interleaved → paired R1/R2
    private func convertInterleavedToPaired(
        input: StepInput,
        context: StepContext
    ) async throws -> StepOutput {
        let outR1 = context.workspace.appendingPathComponent(
            "\(context.sampleName)_conv_R1.fq.gz")
        let outR2 = context.workspace.appendingPathComponent(
            "\(context.sampleName)_conv_R2.fq.gz")

        let env = await bbToolsEnvironment()
        let args = [
            "in=\(input.r1.path)",
            "out=\(outR1.path)",
            "out2=\(outR2.path)",
            "threads=\(context.threads)",
            "ow=t",
        ]

        let result = try await context.runner.run(
            .reformat,
            arguments: args,
            environment: env,
            timeout: context.recipeToolTimeout(for: .reformat, input: input)
        )
        if result.exitCode != 0 {
            throw RecipeEngineError.toolFailed(
                tool: "reformat.sh", step: "format-conversion(interleaved→pairedR1R2)",
                stderr: result.stderr)
        }

        return StepOutput(r1: outR1, r2: outR2, format: .pairedR1R2, tool: .reformat, arguments: args)
    }

    /// Concatenates merged.fq.gz + unmerged_R1.fq.gz + unmerged_R2.fq.gz → single.fq.gz.
    ///
    /// Since gzip files may be concatenated to produce a valid multi-stream gzip archive,
    /// this operation simply appends the raw bytes of each non-nil input file.
    private func convertMergedToSingle(
        input: StepInput,
        context: StepContext
    ) async throws -> StepOutput {
        let output = context.workspace.appendingPathComponent(
            "\(context.sampleName)_single.fq.gz")

        let sources = [input.r1, input.r2, input.r3].compactMap { $0 }

        try Self.concatenateStreams(sources, to: output)

        return StepOutput(r1: output, format: .single)
    }

    static func concatenateStreams(_ sources: [URL], to output: URL) throws {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: output)
        defer { try? outputHandle.close() }

        for source in sources {
            let inputHandle = try FileHandle(forReadingFrom: source)
            defer { try? inputHandle.close() }

            while true {
                let chunk = try inputHandle.read(upToCount: 8 * 1024 * 1024) ?? Data()
                if chunk.isEmpty { break }
                try outputHandle.write(contentsOf: chunk)
            }
        }
    }

    private func bbToolsEnvironment() async -> [String: String] {
        let existingPath = ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return CoreToolLocator.bbToolsEnvironment(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            existingPath: existingPath
        )
    }

    // MARK: - Input requirement check

    private func checkInputRequirement(
        _ requirement: Recipe.InputRequirement,
        actual: RecipeFileFormat
    ) throws {
        switch requirement {
        case .any:
            break
        case .paired:
            guard actual == .pairedR1R2 || actual == .interleaved else {
                throw RecipeEngineError.inputRequirementNotMet(required: requirement, actual: actual)
            }
        case .single:
            guard actual == .single else {
                throw RecipeEngineError.inputRequirementNotMet(required: requirement, actual: actual)
            }
        }
    }
}
