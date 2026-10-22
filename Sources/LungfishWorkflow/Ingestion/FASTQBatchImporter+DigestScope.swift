// FASTQBatchImporter+DigestScope.swift - The batch import entry point, which runs under one digest cache
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension FASTQBatchImporter {

    /// Processes all samples in `pairs` sequentially using the provided configuration.
    ///
    /// The whole command runs under one ``ProvenanceDigestCache``, so a file its records describe more than once is
    /// read once (L7-HASHONCE). ``runBatchImportInScope(_:_:_:_:)`` holds the import itself and its notes on pairing,
    /// skipped samples and memory.
    ///
    /// - Parameters:
    ///   - pairs: Detected sample pairs to process.
    ///   - config: Import configuration (recipe, threads, directories).
    ///   - log: Optional callback for structured log events.
    /// - Returns: Summary of completed, skipped, and failed sample counts.
    public static func runBatchImport(
        pairs: [SamplePair],
        config: ImportConfig,
        log: (@Sendable (ImportLogEvent) -> Void)? = nil,
        databaseRegistry: DatabaseRegistry = .shared
    ) async -> ImportResult {
        await ProvenanceDigestCache.scoped { await runBatchImportInScope(pairs, config, log, databaseRegistry) }
    }
}
