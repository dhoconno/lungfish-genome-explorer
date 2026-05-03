// DeaconRiboFilterStep.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

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
        guard let r2 = input.r2 else {
            throw RecipeEngineError.formatMismatch(
                expected: .pairedR1R2,
                got: input.format,
                step: Self.typeID
            )
        }

        let dbPath: URL
        do {
            dbPath = try await DatabaseRegistry.shared.requiredDatabasePath(for: databaseID)
        } catch let error as HumanScrubberDatabaseError {
            throw error
        } catch {
            throw RecipeEngineError.databaseNotFound(id: databaseID, step: Self.typeID)
        }

        let outR1 = context.workspace.appendingPathComponent(
            "\(context.sampleName)_norrna_R1.fastq.gz"
        )
        let outR2 = context.workspace.appendingPathComponent(
            "\(context.sampleName)_norrna_R2.fastq.gz"
        )

        let args = [
            "filter",
            "--deplete",
            "-a", "\(absoluteThreshold)",
            "-r", "\(relativeThreshold)",
            dbPath.path,
            input.r1.path,
            r2.path,
            "-o", outR1.path,
            "-O", outR2.path,
            "-t", "\(context.threads)",
        ]

        let result = try await context.runner.run(
            .deacon,
            arguments: args,
            timeout: context.recipeToolTimeout(for: .deacon, input: input)
        )
        if result.exitCode != 0 {
            throw RecipeEngineError.toolFailed(
                tool: "deacon",
                step: Self.typeID,
                stderr: result.stderr
            )
        }

        return StepOutput(
            r1: outR1,
            r2: outR2,
            format: .pairedR1R2,
            tool: .deacon,
            arguments: args
        )
    }
}
