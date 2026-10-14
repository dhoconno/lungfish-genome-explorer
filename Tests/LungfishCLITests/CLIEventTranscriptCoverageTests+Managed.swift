// CLIEventTranscriptCoverageTests+Managed.swift - The in-process captures of the managed tools and packs leaves
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
@testable import LungfishCLI
@testable import LungfishWorkflow

/// `tools update`, `conda install --pack` and `conda db update` run micromamba and large downloads, so
/// their transcripts are captured in process on the stand-ins of `ManagedToolLeafFixtures` (lane A52 of
/// Phase 2.10). The record file name carries the time of the run, which the capture rewrites to
/// `<time>` so the transcript is the same on every run. They live here because the main file is past
/// 800 lines.
extension CLIEventTranscriptCoverageTests {
    typealias ManagedFixtures = ManagedToolLeafFixtures

    /// Runs `run` with the stand-ins in place and the managed storage root at the scratch folder, and
    /// returns the event lines with the run time of every record name rewritten.
    private static func managedLines(
        _ scratch: Scratch,
        expectingFailure: Bool = false,
        _ run: @escaping (@escaping (String) -> Void) async throws -> Void
    ) async throws -> [String] {
        // `tools update --storage-root` exports LUNGFISH_STORAGE_ROOT into this process
        // (`ToolsCommand.resolvedStorageRoot`), and every later class of the CLI test process would
        // then look for its tools under the scratch folder. Put back what the process had.
        let savedStorageRoot = ProcessInfo.processInfo.environment["LUNGFISH_STORAGE_ROOT"]
        CondaCommand.storageRootOverride = scratch.root
        defer {
            CondaCommand.storageRootOverride = nil
            CondaCommand.packStatusServiceOverride = nil
            ToolsCommand.manifestOverride = nil
            ToolsCommand.servicesOverride = nil
            DbCommand.DbUpdateSubcommand.registryOverride = nil
            if let savedStorageRoot {
                setenv("LUNGFISH_STORAGE_ROOT", savedStorageRoot, 1)
            } else {
                unsetenv("LUNGFISH_STORAGE_ROOT")
            }
        }
        let lines = try await eventLines(expectingFailure: expectingFailure, run)
        return lines.map {
            $0.replacingOccurrences(
                of: #"\d{4}-\d{2}-\d{2}T\d{6}"#, with: "<time>", options: .regularExpression
            )
        }
    }

    static func managedToolCaptures() -> [Capture] {
        [
            Capture(leaf: "conda install", name: "complete") { scratch in
                CondaCommand.packStatusServiceOverride = ManagedFixtures.PackService(.succeed)
                let pack = try ManagedFixtures.pack()
                let command = try CondaCommand.InstallSubcommand.parse(["--pack", pack.id, "--reinstall", "--format", "json"])
                return try await managedLines(scratch) { try await command.executePacks(eventsOn: true, quiet: true, emit: $0) }
            },
            Capture(leaf: "conda install", name: "failed") { scratch in
                CondaCommand.packStatusServiceOverride = ManagedFixtures.PackService(.fail)
                let pack = try ManagedFixtures.pack()
                let command = try CondaCommand.InstallSubcommand.parse(["--pack", pack.id, "--reinstall", "--format", "json"])
                return try await managedLines(scratch, expectingFailure: true) {
                    try await command.executePacks(eventsOn: true, quiet: true, emit: $0)
                }
            },
            Capture(leaf: "tools update", name: "complete") { scratch in
                ToolsCommand.manifestOverride = ManagedFixtures.manifest()
                ToolsCommand.servicesOverride = ManagedFixtures.services(behaviour: .succeed)
                let command = try ToolsCommand.UpdateSubcommand.parse(
                    ["--apply", "--yes", "--only", "samtools", "--format", "json", "--storage-root", scratch.root.path]
                )
                return try await managedLines(scratch) { try await command.execute(emit: $0) }
            },
            Capture(leaf: "tools update", name: "failed") { scratch in
                ToolsCommand.manifestOverride = ManagedFixtures.manifest()
                ToolsCommand.servicesOverride = ManagedFixtures.services(behaviour: .fail)
                let command = try ToolsCommand.UpdateSubcommand.parse(
                    ["--apply", "--yes", "--format", "json", "--storage-root", scratch.root.path]
                )
                return try await managedLines(scratch, expectingFailure: true) { try await command.execute(emit: $0) }
            },
            Capture(leaf: "conda db update", name: "complete") { scratch in
                DbCommand.DbUpdateSubcommand.registryOverride = try await ManagedFixtures.registry(
                    in: scratch.root.appendingPathComponent("databases"), stalling: false
                )
                let command = try DbCommand.DbUpdateSubcommand.parse(["kraken2-viral", "--yes", "--format", "json"])
                return try await managedLines(scratch) { try await command.execute(eventsOn: true, quiet: true, emit: $0) }
            },
            Capture(leaf: "conda db update", name: "failed") { scratch in
                // A database the registry does not hold fails after the run starts.
                DbCommand.DbUpdateSubcommand.registryOverride = try await ManagedFixtures.registry(
                    in: scratch.root.appendingPathComponent("databases"), stalling: false
                )
                let command = try DbCommand.DbUpdateSubcommand.parse(["no-such-database", "--yes", "--format", "json"])
                return try await managedLines(scratch, expectingFailure: true) {
                    try await command.execute(eventsOn: true, quiet: true, emit: $0)
                }
            },
        ]
    }
}
