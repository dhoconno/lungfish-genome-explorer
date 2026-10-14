// CondaFamilyProcess.swift - The ToolProcess adapter the conda family of runners shares
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

// MARK: - ToolProcess adapter shared by the conda family

/// What the conda family of runners shares when it runs a process through
/// ``ToolProcess``. `CondaManager`, the streaming micromamba run in
/// `ManagedMappingPipeline`, `ManagedToolSourceInstaller.run` and
/// `ProcessGATKCommandRunner` use it.
enum CondaFamilyProcess {
    /// How long a cancelled or timed-out run's process tree has between
    /// SIGTERM and SIGKILL, the one policy for runTool, the streaming mapper,
    /// the source installer and GATK. ToolProcess has one grace for both, so
    /// a timeout keeps the 0.5 seconds it had before Phase 2.2 and a
    /// cancellation, which used to kill at once, now waits the same 0.5
    /// seconds, so a JVM or a Python worker can flush and exit.
    static let terminationGracePeriod: Duration = .milliseconds(500)

    /// The ToolProcess limit for a timeout in seconds. A value that is not
    /// finite, or too large to count in nanoseconds, means no limit. A value at
    /// or below zero becomes the smallest limit, so the run stops at once, as
    /// the timer it replaces did.
    static func limit(seconds: TimeInterval) -> Duration? {
        guard seconds.isFinite, seconds < 9e9 else { return nil }
        return .nanoseconds(max(Int64((seconds * 1e9).rounded()), 1))
    }

    /// An event observer that hands each captured line to the handler for its
    /// stream, or nil when there is no handler, so output is not framed at all.
    static func lineForwarder(
        stdout stdoutHandler: (@Sendable (String) -> Void)?,
        stderr stderrHandler: (@Sendable (String) -> Void)?
    ) -> (@Sendable (ToolProcessEvent) -> Void)? {
        guard stdoutHandler != nil || stderrHandler != nil else { return nil }
        return { event in
            guard case .output(let stream, let line) = event else { return }
            switch stream {
            case .stdout: stdoutHandler?(line)
            case .stderr: stderrHandler?(line)
            }
        }
    }

    /// The `Process` termination reason that matches a ToolProcess termination.
    static func terminationReason(_ termination: ToolProcessTermination) -> Process.TerminationReason {
        switch termination {
        case .exited: return .exit
        case .signaled: return .uncaughtSignal
        }
    }
}
