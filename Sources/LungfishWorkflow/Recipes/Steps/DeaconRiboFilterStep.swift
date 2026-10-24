// DeaconRiboFilterStep.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// Recipe step that removes ribosomal reads using Deacon and the BBMap ribokmers index.
public struct DeaconRiboFilterStep: RecipeStepExecutor {

    // MARK: - RecipeStepExecutor

    public static let typeID: String = "deacon-ribo-filter"
    public static let displayName: String = "Ribosomal RNA Removal"

    public var inputFormat: RecipeFileFormat { .pairedR1R2 }
    public var outputFormat: RecipeFileFormat { .pairedR1R2 }

    // MARK: - Parameters

    public let databaseID: String
    public let absoluteThreshold: Int
    public let relativeThreshold: Double

    // MARK: - Init

    public init(params: [String: AnyCodableValue]?) throws {
        databaseID = params?["database"]?.stringValue ?? DeaconRibokmersDatabaseInstaller.databaseID

        let absoluteThreshold = params?["absoluteThreshold"]?.intValue
            ?? params?["absThreshold"]?.intValue
            ?? 1
        guard absoluteThreshold > 0 else {
            throw RecipeEngineError.invalidParam(
                step: Self.typeID,
                param: "absoluteThreshold",
                value: "\(absoluteThreshold)"
            )
        }
        self.absoluteThreshold = absoluteThreshold

        let relativeThresholdValue = params?["relativeThreshold"] ?? params?["relThreshold"]
        let relativeThreshold = relativeThresholdValue?.doubleValue
            ?? relativeThresholdValue?.intValue.map(Double.init)
            ?? 0
        guard relativeThreshold >= 0, relativeThreshold <= 1 else {
            throw RecipeEngineError.invalidParam(
                step: Self.typeID,
                param: "relativeThreshold",
                value: "\(relativeThreshold)"
            )
        }
        self.relativeThreshold = relativeThreshold
    }

    // MARK: - Execute

    public func execute(input: StepInput, context: StepContext) async throws -> StepOutput {
        guard input.r2 != nil else {
            throw RecipeEngineError.formatMismatch(
                expected: .pairedR1R2,
                got: input.format,
                step: Self.typeID
            )
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
                tool: "deacon",
                step: Self.typeID,
                stderr: result.stderr
            )
        }

        let counts = RecipeToolReportCounts.deaconPairs(summaryAt: summary)
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
