// ManagedDatabaseInstallSeams.swift - The closures a managed database install runs its downloads, tools, records and lock lookups through
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

typealias ManagedDatabaseDownloadProgress = @Sendable (Double, Int64, Int64) -> Void
typealias ManagedDatabaseDownloader = @Sendable (URL, ManagedDatabaseDownloadProgress) async throws -> ManagedDatabaseDownloadResult
typealias ManagedDatabaseStderrHandler = @Sendable (String) -> Void
typealias ManagedDatabaseToolRunner = @Sendable (
    String,
    [String],
    String,
    TimeInterval,
    ManagedDatabaseStderrHandler?
) async throws -> ManagedDatabaseToolResult
typealias ManagedDatabaseProvenanceWriter = @Sendable (WorkflowRun, URL) throws -> Void

/// Finds the lock's entry for a managed database by its ID. A registry reads the bundled lock unless it is handed
/// another lookup, which a test does to pin the bytes of its own fixture in place of the real index's.
typealias ManagedDatabaseLockLookup = @Sendable (String) -> DatabaseSpec?
