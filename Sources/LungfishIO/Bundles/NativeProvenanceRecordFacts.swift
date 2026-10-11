// NativeProvenanceRecordFacts.swift - What a record that keeps its own shape says about its run and its writer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// What an alignment, tree or workbook export record that keeps its own shape says about how its run
/// ended and about the process that wrote it (Phase 2.7 lane B6, panel decision P13).
///
/// These records are not envelopes, because LungfishIO cannot import the envelope or its writer, but
/// they follow the envelope writer's rules. Each states its `status`, which is what lets the reader
/// read it as a typed record instead of the Older record format. Each names its own executable as
/// `<external>/<file name>` and records no process ID, because an install path names folders on one
/// Mac and a process ID names nothing once the run has ended. None records `CONDA_DEFAULT_ENV`,
/// `CONDA_PREFIX` or `LUNGFISH_CONTAINER_IMAGE` from the environment it inherited, because those name
/// the shell that started LGE and not the run. A path under the managed tool or storage root takes
/// its `PortablePath` placeholder.
public enum NativeProvenanceRecordFacts {
    /// The `status` of a record written when its run completed. These writers write a record only then.
    public static let completedStatus = "completed"

    /// The running app or CLI as `<external>/<file name>`.
    public static var executablePath: String {
        externalExecutablePath(Bundle.main.executablePath ?? CommandLine.arguments.first ?? "unknown")
    }

    /// `path` as `<external>/<file name>`, the form a record gives the app or CLI that wrote it.
    public static func externalExecutablePath(_ path: String) -> String {
        PortablePath.externalPlaceholder + "/" + URL(fileURLWithPath: path).lastPathComponent
    }

    /// `path` with the managed tool root or storage root replaced by its placeholder, such as
    /// `<tool-root>/envs/openpyxl/bin/python`. Any other value, a path elsewhere included, is
    /// returned unchanged.
    public static func storagePath(
        _ path: String,
        managedRoots: (toolRoot: URL, storageRoot: URL) = PortablePath.defaultManagedRoots
    ) -> String {
        guard path.hasPrefix("/") else { return path }
        let context = PortablePath.Context(
            projectURL: nil,
            toolRootURL: managedRoots.toolRoot,
            storageRootURL: managedRoots.storageRoot,
            temporaryRootURLs: []
        )
        let sanitized = PortablePath.sanitize(path: path, context: context)
        let placeholders = [PortablePath.toolRootPlaceholder, PortablePath.storageRootPlaceholder]
        return placeholders.contains { sanitized == $0 || sanitized.hasPrefix($0 + "/") } ? sanitized : path
    }
}
