// DeaconScrubStep.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// Recipe step that removes human reads using Deacon.
///
/// Resolves the Deacon database path via `DatabaseRegistry` at execution time,
/// allowing the user to override the default bundled database.
///
/// Executes via `NativeTool.deacon`; the database is resolved at runtime.
public struct DeaconScrubStep: RecipeStepExecutor {

    // MARK: - RecipeStepExecutor

    public static let typeID: String = "deacon-scrub"
    public static let displayName: String = "Human Read Removal"

    public var inputFormat: RecipeFileFormat { .pairedR1R2 }
    public var outputFormat: RecipeFileFormat { .pairedR1R2 }

    // MARK: - Parameters

    /// Identifier passed to `DatabaseRegistry` to locate the Deacon index.
    public let databaseID: String

    // MARK: - Init

    public init(params: [String: AnyCodableValue]?) throws {
        databaseID = params?["database"]?.stringValue ?? DeaconPanhumanDatabaseInstaller.databaseID
    }

    // MARK: - Execute

    public func execute(input: StepInput, context: StepContext) async throws -> StepOutput {
        guard input.r2 != nil else {
            throw RecipeEngineError.formatMismatch(
                expected: .pairedR1R2, got: input.format, step: Self.typeID)
        }

        let dbPath = try await context.recipeDatabasePath(for: databaseID, step: Self.typeID)
        let database = try await RecipeDatabaseIdentity.shared.record(databaseID: databaseID, at: dbPath)

        // The argv an executor plan names too (RecipePlannedInvocation.swift).
        let invocation = try plannedInvocation(
            input: input, databasePath: dbPath, workspace: context.workspace, sampleName: context.sampleName,
            threads: context.threads
        )
        let (outR1, outR2) = (invocation.output.r1, invocation.output.r2)
        let summary = invocation.auxiliaryOutputs[0]

        let deaconClock = ProvenanceRunClock()
        let result = try await context.runner.run(
            .deacon,
            arguments: invocation.arguments,
            timeout: context.recipeToolTimeout(for: .deacon, input: input)
        )
        let completedAt = deaconClock.now
        if result.exitCode != 0 {
            throw RecipeEngineError.toolFailed(
                tool: "deacon", step: Self.typeID, stderr: result.stderr)
        }

        let counts = RecipeToolReportCounts.deaconPairs(summaryAt: summary)
        // Vote C4-3 C-1: the exit status, standard error and times of the run, as every other recipe step records them.
        return StepOutput(
            r1: outR1,
            r2: outR2,
            format: .pairedR1R2,
            readCount: counts?.output,
            inputReadCount: counts?.input,
            tool: .deacon,
            arguments: result.arguments,
            auxiliaryOutputs: [summary],
            exitStatus: Int(result.exitCode),
            stderr: result.stderr,
            startedAt: deaconClock.startedAt,
            completedAt: completedAt,
            databases: [database]
        )
    }
}
