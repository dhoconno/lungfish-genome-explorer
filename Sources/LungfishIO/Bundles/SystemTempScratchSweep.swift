// SystemTempScratchSweep.swift - LGE scratch in the system temp folder, marked and swept once its creator is gone
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import os.log
import LungfishCore

private let logger = Logger(subsystem: LogSubsystem.io, category: "SystemTempScratchSweep")

/// Scratch that LGE makes in the system temp folder (2.10 P1, 2.11 S3).
///
/// A run with no project, a volume the Nextflow scratch probe rejects and the space-free staging of
/// TaxTriage and nf-core all put scratch in the system temp folder, and a cancelled executor run
/// leaves its scratch for a sweep (P3). ``createMarkedDirectory(prefix:in:toolVersion:)`` gives each
/// such folder the ``OwnedWorkDirectoryMarker`` that project scratch gets, bound to the temp folder
/// and naming the creating process by PID, start time and boot session.
public enum SystemTempScratchSweep {

    // MARK: - Marking

    /// Creates `<root>/<prefix><UUID>/` with an ``OwnedWorkDirectoryMarker`` bound to `root` that
    /// names the current process, the user's alone (`0700`), as project scratch is made.
    ///
    /// The marker binds the physical folder, so `/var/...` and `/private/var/...` name one root. The
    /// returned URL keeps the caller's spelling of `root`.
    static func createMarkedDirectory(prefix: String, in root: URL, toolVersion: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let physicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let created = try OwnedWorkDirectoryMarkerStore.createDirectory(
            OwnedWorkDirectoryCreationRequest(
                projectURL: physicalRoot,
                parentDirectoryURL: physicalRoot,
                prefix: prefix,
                runID: UUID(),
                processIdentity: try OwnedProcessIdentity.current(),
                state: .active,
                lockRelativePath: nil,
                keepIntermediates: false,
                toolName: "ProjectTempDirectory",
                toolVersion: toolVersion
            )
        )
        let directory = root.appendingPathComponent(created.lastPathComponent, isDirectory: true)
        logger.debug("Created marked system temp directory: \(directory.path, privacy: .public)")
        return directory
    }
}
