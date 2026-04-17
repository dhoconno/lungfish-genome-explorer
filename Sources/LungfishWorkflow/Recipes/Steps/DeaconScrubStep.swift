// DeaconScrubStep.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Recipe step that removes human reads using Deacon.
///
/// Resolves the Deacon database path via `DatabaseRegistry` at execution time,
/// allowing the user to override the default bundled database.
///
/// NOTE: `.deacon` may not yet exist in `NativeTool` (that is Task 6).
/// The `execute()` body is implemented but will only compile once `.deacon` is
/// added to `NativeTool`.  The unit tests for this step only test parameter
/// parsing and do not call `execute()`.
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
        guard let r2 = input.r2 else {
            throw RecipeEngineError.formatMismatch(
                expected: .pairedR1R2, got: input.format, step: Self.typeID)
        }

        let dbPath: URL
        do {
            dbPath = try await DatabaseRegistry.shared.requiredDatabasePath(for: databaseID)
        } catch let error as HumanScrubberDatabaseError {
            throw error
        } catch {
            throw RecipeEngineError.databaseNotFound(id: databaseID, step: Self.typeID)
        }

        let outR1 = context.workspace.appendingPathComponent("\(context.sampleName)_scrubbed_R1.fq.gz")
        let outR2 = context.workspace.appendingPathComponent("\(context.sampleName)_scrubbed_R2.fq.gz")

        let args = [
            "filter",
            "-d", dbPath.path,
            input.r1.path,
            r2.path,
            "-o", outR1.path,
            "-O", outR2.path,
            "-t", "\(context.threads)",
        ]

        let result = try await context.runner.run(.deacon, arguments: args)
        if result.exitCode != 0 {
            throw RecipeEngineError.toolFailed(
                tool: "deacon", step: Self.typeID, stderr: result.stderr)
        }

        return StepOutput(r1: outR1, r2: outR2, format: .pairedR1R2, tool: .deacon, arguments: args)
    }
}
