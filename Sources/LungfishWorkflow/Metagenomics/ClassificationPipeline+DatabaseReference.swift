// ClassificationPipeline+DatabaseReference.swift - The Kraken2 database one classification run records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The Kraken2 database one classification run records (decision E9 as amended by 2.13 vote V2-1, lane 13.15
/// DB-REF-SIZE). The run reads the folder's install receipt once, before it records anything, and every digest fact
/// of its record reads the result. That is the database reference input of each step, the resolved `databaseDigest`
/// and `databaseIdentityStatus`, the run's parameters and options, and `classification-result.json`.
///
/// A digest the receipt does not back is recorded nowhere as the database's digest. The run goes on, records the
/// database as `unresolved-bounded-metadata` with the size of its three core files, and keeps the registry's digest
/// in the resolved option `databaseIdentityNote`, so no fact is lost. `--db-digest` keeps its refusals
/// (`Kraken2AnalysisRunTool.resolveDatabase`).
struct Kraken2RecordedDatabase: Sendable {
    /// The digest the configuration held, the registry row's payload digest or the one a caller gave.
    let registryDigest: String?
    /// The registry's digest with the size it covers, when the folder's install receipt backs it. Read from the
    /// receipt alone, so no database file is hashed (decision E9 as amended by 2.13 V2-1). Nil when the run has no
    /// digest or the receipt does not check out.
    let checkedDatabaseReference: ProvenanceFileDescriptor?
    /// The database folder, standardized.
    let databasePath: URL

    init(config: ClassificationConfig) {
        registryDigest = config.databaseDigest
        databasePath = config.databasePath.standardizedFileURL
        checkedDatabaseReference = config.databaseDigest == nil
            ? nil
            : Kraken2DatabaseReceipt.verifiedReference(
                databasePath: config.databasePath, registryDigest: config.databaseDigest
            )
    }

    /// The digest the run records, the receipt's digest when it backs the registry's, else none.
    var recordedDigest: String? { checkedDatabaseReference?.checksumSHA256 }

    /// `config` with the digest the run records in place of the registry's. Every other value is kept, as
    /// `ClassificationConfig.withProfileRequest(_:)` keeps them.
    func recording(_ config: ClassificationConfig) -> ClassificationConfig {
        guard config.databaseDigest != recordedDigest else { return config }
        var recorded = ClassificationConfig(
            goal: config.goal,
            inputFiles: config.inputFiles,
            isPairedEnd: config.isPairedEnd,
            interleavedInput: config.interleavedInput,
            inputLayout: config.inputLayout,
            databaseName: config.databaseName,
            inputFormat: config.inputFormat,
            databaseVersion: config.databaseVersion,
            databasePath: config.databasePath,
            databaseDigest: recordedDigest,
            databaseCatalogID: config.databaseCatalogID,
            databaseInstallationRecipe: config.databaseInstallationRecipe,
            brackenProfileRequest: config.brackenProfileRequest,
            confidence: config.confidence,
            minimumHitGroups: config.minimumHitGroups,
            threads: config.threads,
            memoryMapping: config.memoryMapping,
            quickMode: config.quickMode,
            outputDirectory: config.outputDirectory,
            extraArguments: config.extraArguments
        )
        recorded.sampleDisplayName = config.sampleDisplayName
        recorded.originalInputFiles = config.originalInputFiles
        recorded.copyReadSet(from: config)
        return recorded
    }

    /// The resolved option that says why a configured digest is not recorded, written only when the configuration
    /// held a digest and the receipt check failed. Empty otherwise.
    var identityNote: [String: ParameterValue] {
        guard let registryDigest, checkedDatabaseReference == nil else { return [:] }
        return [
            "databaseIdentityNote": .string(
                "The install receipt in \(databasePath.path) does not back the registry's digest \(registryDigest), "
                    + "so this run records no digest."
            ),
        ]
    }
}
