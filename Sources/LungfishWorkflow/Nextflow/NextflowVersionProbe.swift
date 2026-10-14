// NextflowVersionProbe.swift - `-version` of the Nextflow a launch starts, asked before the launch
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// What `-version` of the Nextflow a launch starts printed, asked before the launch (Phase 2.10 N3).
///
/// A record takes the version from Nextflow's own debug log when that log names it, and from this probe only
/// otherwise. The probe runs the launch's own executable and argument prefix with the launch's environment, never a
/// Nextflow found on `PATH`, through ``ToolProcess`` with ``timeout``, and never while a cancel runs.
package struct NextflowVersionProbe: Sendable, Equatable {
    /// The command the probe ran ahead of `-version`, the launch's executable and argument prefix.
    package let command: [String]
    /// The version the output names, nil when it names none.
    package let version: String?

    /// How long `-version` may take, a JVM start on a loaded Mac.
    package static let timeout: Duration = .seconds(30)

    package init(command: [String], version: String?) {
        self.command = command
        self.version = version
    }

    /// Runs `-version` of the executable `launch` starts. Nil when it cannot start, does not exit 0 in time or the
    /// calling task is cancelled.
    package static func run(_ launch: WorkflowEngineLaunch, timeout: Duration = timeout) async -> NextflowVersionProbe? {
        let command = [launch.executableURL.path] + launch.argumentPrefix
        let spec = ToolProcessSpec(
            executableURL: launch.executableURL,
            arguments: launch.arguments(["-version"]),
            environment: launch.environment,
            timeout: timeout,
            label: "nextflow -version"
        )
        guard let result = try? await ToolProcess.run(spec), result.status == 0 else { return nil }
        return NextflowVersionProbe(
            command: command,
            version: NextflowRecordFacts.nextflowVersion(inVersionOutput: result.stdoutText)
        )
    }
}
