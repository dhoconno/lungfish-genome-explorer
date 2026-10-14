// NFCoreEngineVersionProbing.swift - The Nextflow version and commit a Viral Recon run records, and where they come from
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow

/// A runner that can ask `-version` of the Nextflow its launch starts, before the launch (Phase 2.10 N3).
protocol NFCoreEngineVersionProbing: Sendable {
    /// `-version` of the executable the runner's launch starts, or nil when it cannot be asked.
    func probeEngineVersion() async -> NextflowVersionProbe?
}

extension ProcessNFCoreWorkflowProcessRunner: NFCoreEngineVersionProbing {
    /// `-version` of the managed Nextflow ``runNextflow(_:)`` launches, resolved by the same `resolveLaunch`, so the
    /// probe runs the absolute path the engine runs and never a Nextflow found on `PATH` (N3).
    func probeEngineVersion() async -> NextflowVersionProbe? {
        guard let launch = try? resolveLaunch("nextflow", homeDirectory) else { return nil }
        return await NextflowVersionProbe.run(launch)
    }
}

/// The engine facts a Viral Recon record takes from the run that launched (N3, 2.9 R2).
struct ViralReconEngineFacts: Sendable, Equatable {
    /// The version of the Nextflow that ran, nil when neither its debug log nor the probe named one.
    let nextflowVersion: String?
    /// The commit Nextflow resolved, as its `Launching` line names it, nil when no line names one.
    let launchedCommit: String?

    /// How much of the head of each log is read. Both lines come within the first few kilobytes.
    static let headBytes = 256 * 1024

    /// The facts of a run launched in `launchFolder`. The version comes from Nextflow's own debug log
    /// `.nextflow.log` in the launch folder when it names one, else from `probe`, the `-version` of the same
    /// executable asked before the launch, and is absent otherwise. The commit comes from the debug log's
    /// `Launching` line, else from that line in the run's `consoleLog`.
    static func read(launchFolder: URL, consoleLog: URL, probe: NextflowVersionProbe?) -> ViralReconEngineFacts {
        let debugLog = head(of: launchFolder.appendingPathComponent(".nextflow.log"))
        let console = head(of: consoleLog)
        return ViralReconEngineFacts(
            nextflowVersion: debugLog.flatMap(NextflowRecordFacts.nextflowVersion(inDebugLog:)) ?? probe?.version,
            launchedCommit: debugLog.flatMap(NextflowRecordFacts.launchedCommit(inLog:))
                ?? console.flatMap(NextflowRecordFacts.launchedCommit(inLog:))
        )
    }

    private static func head(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: headBytes)).map { String(decoding: $0, as: UTF8.self) }
    }
}
