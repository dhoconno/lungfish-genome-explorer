// FASTQBatchImporter+RecipeDatabases.swift - An import's record names each database a recipe step read
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension FASTQBatchImporter {
    /// Each database file a recipe step read, as a step input with its digest and size.
    static func recipeDatabaseInputRecords(for result: RecipeStepResult) -> [FileRecord] {
        result.databases.map {
            FileRecord(
                path: $0.path,
                sha256: $0.sha256,
                sizeBytes: UInt64(clamping: $0.sizeBytes),
                format: .unknown,
                role: .index
            )
        }
    }

    /// The step's resolved options naming each database it read by id, version, file name, index format, SHA-256
    /// and size, empty when it read none (CHTC lane L5-RECORDS M2).
    static func recipeDatabaseOptions(for result: RecipeStepResult) -> [String: ParameterValue] {
        guard !result.databases.isEmpty else { return [:] }
        return ["databases": .array(result.databases.map(databaseOption))]
    }

    private static func databaseOption(_ database: RecipeDatabaseRecord) -> ParameterValue {
        var entry: [String: ParameterValue] = [
            "id": .string(database.id),
            "version": .string(database.version),
            "fileName": .string(database.fileName),
            "sha256": .string(database.sha256),
            "sizeBytes": .integer(Int(database.sizeBytes)),
            "path": .string(database.path),
            "lockPinned": .boolean(database.lockPinned),
        ]
        entry["indexFormat"] = database.indexFormat.map(ParameterValue.integer)
        entry["kmerLength"] = database.kmerLength.map(ParameterValue.integer)
        entry["windowSize"] = database.windowSize.map(ParameterValue.integer)
        entry["buildSourceSHA256"] = database.buildSourceSHA256.map(ParameterValue.string)
        entry["buildSourceSizeBytes"] = database.buildSourceSizeBytes.map { .integer(Int($0)) }
        entry["buildToolVersion"] = database.buildToolVersion.map(ParameterValue.string)
        return .dictionary(entry)
    }
}
