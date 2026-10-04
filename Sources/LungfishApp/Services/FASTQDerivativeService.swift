// FASTQDerivativeService.swift - FASTQ materialization and import recipe runner
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

/// Materializes derived FASTQ bundles to FASTQ files and runs import recipes
/// with bundled tools. The FASTQ operations dialog makes derivative bundles
/// through `lungfish-cli` and `FASTQOperationOutputImporter`, not here.
public actor FASTQDerivativeService {
    public static let shared = FASTQDerivativeService()

    static func resolveHumanScrubberDatabasePath(
        databaseID: String,
        registry: DatabaseRegistry = .shared
    ) async throws -> URL {
        let resolvedID = canonicalHumanScrubDatabaseID(for: databaseID)
        return try await registry.requiredDatabasePath(for: resolvedID)
    }

    static func canonicalHumanScrubDatabaseID(for databaseID: String) -> String {
        let canonical = DatabaseRegistry.canonicalDatabaseID(for: databaseID)
        if canonical == HumanScrubberDatabaseInstaller.databaseID {
            return DeaconPanhumanDatabaseInstaller.databaseID
        }
        return canonical
    }

    let runner: NativeToolRunner
    let databaseRegistry: DatabaseRegistry

    /// Number of threads to pass to multithreaded tools (fastp, seqkit, etc.).
    /// Uses all available cores for maximum throughput.
    let toolThreadCount = ProcessInfo.processInfo.activeProcessorCount

    /// Cached BBTools environment dictionary — stable across the actor's lifetime.
    var cachedBBToolsEnv: [String: String]?

    public init(databaseRegistry: DatabaseRegistry = .shared, runner: NativeToolRunner = .shared) {
        self.databaseRegistry = databaseRegistry
        self.runner = runner
    }
}
