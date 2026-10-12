// TaxTriageEngineProcess.swift - TaxTriage's Nextflow engine and launch scratch, on the shared engine process
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Engine

extension TaxTriagePipeline {
    /// Set to `1` to keep the Nextflow launch scratch (including `work/`) after a run, the key
    /// ``NextflowWorkflowDescriptor/taxTriage`` names.
    static let keepWorkEnvironmentKey = "LUNGFISH_TAXTRIAGE_KEEP_WORK"

    /// TaxTriage's Nextflow engine for a launch with the effective `profile`, the shared engine
    /// process with the settings of ``NextflowWorkflowDescriptor/taxTriage`` (Phase 2.9, N2).
    ///
    /// The engine waits for Docker only for the `docker` profile, gives the tree 4 s between TERM
    /// and KILL, and names the scratch `taxtriage-run-` with the keep-work key (N6, N7, N9).
    static func nextflowEngine(processManager: ProcessManager, profile: String) -> NextflowEngineProcess {
        NextflowEngineProcess(
            processManager: processManager,
            configuration: NextflowWorkflowDescriptor.taxTriage.engineConfiguration(profile: profile)
        )
    }

    // MARK: - Local launch scratch

    /// A local, lock-capable scratch for one launch, as a run makes it with its engine, the launch
    /// folder that hosts Nextflow's `.nextflow/` cache and history and the `-w` work folder (N7).
    ///
    /// The scratch stays on the project volume whenever it can host Nextflow's cache, since external
    /// project drives are usually far larger than the boot volume and multi-GB work trees belong
    /// there. Only a disqualified volume, one without `fcntl` locks or one whose AppleDouble sidecars
    /// crash the LevelDB cache (ExFAT through FSKit, some network mounts), forces local storage. See
    /// ``NextflowScratchVolumeProbe``.
    nonisolated func makeLocalLaunchScratch(
        contextURL: URL,
        volumeQualifiesForScratch: Bool? = nil
    ) throws -> NextflowEngineScratch {
        try Self.nextflowEngine(processManager: .shared, profile: NextflowWorkflowDescriptor.taxTriage.profile)
            .makeScratch(contextURL: contextURL, volumeQualifiesForScratch: volumeQualifiesForScratch)
    }

    /// Removes a scratch from ``makeLocalLaunchScratch(contextURL:volumeQualifiesForScratch:)`` once
    /// the run's record is written, unless it is kept for debugging.
    nonisolated func cleanUpLaunchScratch(_ scratch: NextflowEngineScratch) {
        Self.nextflowEngine(processManager: .shared, profile: NextflowWorkflowDescriptor.taxTriage.profile)
            .finish(scratch, .remove)
    }
}
