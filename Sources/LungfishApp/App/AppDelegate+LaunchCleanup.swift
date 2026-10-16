// AppDelegate+LaunchCleanup.swift - The temp file cleanup and, once per launch, the system temp scratch sweep
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension AppDelegate {
    /// Applies the temp file retention and removes stale temp files. At launch it also starts the sweep
    /// of LGE scratch in the system temp folder whose creator is gone (2.11 S3), once both cleanup calls
    /// have returned. A change of the retention setting runs the cleanup again but never the sweep.
    func cleanUpTemporaryFiles(retentionHours: Int, atLaunch: Bool) {
        Task {
            await TempFileManager.shared.setMaxAge(hours: retentionHours)
            await TempFileManager.shared.cleanupOnLaunch()
            if atLaunch {
                AppDelegate.startSystemTempScratchSweep()
            }
        }
    }

    /// Starts ``SystemTempScratchSweep/sweep(root:recordedPaths:userID:processInspector:)`` detached at
    /// utility priority, so its listing, marker reads and removals never run on the main actor.
    ///
    /// - Parameters:
    ///   - root: The folder to sweep, the system temp folder (which honours `TMPDIR`) when nil. Tests
    ///     pass a TestTempDirectory folder.
    ///   - sweep: The sweep to run. Tests pass one that records where it ran.
    @discardableResult
    nonisolated static func startSystemTempScratchSweep(
        root: URL? = nil,
        sweep: @escaping @Sendable (URL) -> SystemTempScratchSweep.Outcome = { SystemTempScratchSweep.sweep(root: $0) }
    ) -> Task<SystemTempScratchSweep.Outcome, Never> {
        Task.detached(priority: .utility) {
            sweep(root ?? ProjectTempDirectory.systemTemporaryDirectory())
        }
    }
}
