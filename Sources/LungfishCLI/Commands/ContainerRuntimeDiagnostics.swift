// ContainerRuntimeDiagnostics.swift - Report for `lungfish-cli debug container`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The probes themselves (`ContainerRuntimeProbing`, `SystemContainerRuntimeProbe`,
// `PipelineContainerRuntimeStatus`) live in LungfishWorkflow so the app's
// Nextflow wizards report the same Docker daemon verdict this command prints.

import Foundation
import LungfishWorkflow

// MARK: - Report

/// What `debug container` prints, in text or JSON.
struct ContainerRuntimeReport: Codable, Equatable, Sendable {
    /// Runtime that Nextflow pipelines (Viral Recon, TaxTriage) launch with
    /// (`-profile docker`).
    static let pipelineRuntimeName = PipelineContainerRuntimeStatus.runtimeName

    let dockerCLIPath: String?
    let dockerDaemonReachable: Bool
    let dockerClientVersion: String?
    let dockerServerVersion: String?
    let dockerDetail: String?
    let appleContainerizationAvailable: Bool
    let appleContainerRuntimeReady: Bool
    let appleContainerDetail: String?
    /// The timeout the daemon probe used, in seconds.
    let probeTimeoutSeconds: Double

    /// `true` only when the runtime the pipelines actually use is reachable.
    var pipelineRuntimeReady: Bool { dockerDaemonReachable }

    /// The error the command exits with, or `nil` when the pipelines can run.
    var exitError: CLIError? {
        pipelineRuntimeReady ? nil : .containerUnavailable
    }

    static func collect(
        probe: any ContainerRuntimeProbing,
        timeout: TimeInterval
    ) async -> ContainerRuntimeReport {
        let dockerPath = probe.dockerCLIPath()
        let daemon: DockerDaemonProbe
        if let dockerPath {
            daemon = await probe.dockerDaemon(dockerPath: dockerPath, timeout: timeout)
        } else {
            daemon = DockerDaemonProbe(
                reachable: false,
                clientVersion: nil,
                serverVersion: nil,
                detail: "docker CLI not found in PATH or the usual install locations"
            )
        }
        let apple = await probe.appleContainerRuntime()
        return ContainerRuntimeReport(
            dockerCLIPath: dockerPath,
            dockerDaemonReachable: daemon.reachable,
            dockerClientVersion: daemon.clientVersion,
            dockerServerVersion: daemon.serverVersion,
            dockerDetail: daemon.detail,
            appleContainerizationAvailable: apple.frameworkAvailable,
            appleContainerRuntimeReady: apple.runtimeReady,
            appleContainerDetail: apple.detail,
            probeTimeoutSeconds: timeout
        )
    }

    /// Text rendering. Each line is returned separately so tests can assert
    /// on content without ANSI colour codes.
    func textLines(formatter: TerminalFormatter) -> [String] {
        var lines: [String] = []
        lines.append(formatter.header("Container Runtime"))
        lines.append("")
        lines.append(formatter.info(
            "Nextflow pipelines (Viral Recon, TaxTriage) run their containers through "
                + "\(Self.pipelineRuntimeName) (-profile docker)."
        ))
        lines.append("")

        lines.append(formatter.header("Docker (used by pipelines)"))
        if pipelineRuntimeReady {
            lines.append(formatter.success("Docker daemon reachable"))
        } else {
            lines.append(formatter.error("Docker daemon unreachable"))
        }
        var dockerRows: [(String, String)] = [
            ("Docker CLI", dockerCLIPath ?? "not installed"),
            ("Daemon", dockerDaemonReachable ? "reachable" : "unreachable"),
            ("Client Version", dockerClientVersion ?? "unknown"),
            ("Server Version", dockerServerVersion ?? "unknown"),
        ]
        if let dockerDetail, !dockerDetail.isEmpty {
            dockerRows.append(("Detail", dockerDetail))
        }
        lines.append(formatter.keyValueTable(dockerRows))
        if !pipelineRuntimeReady {
            lines.append(formatter.warning(
                "Start \(Self.pipelineRuntimeName) and run this command again before launching a pipeline."
            ))
        }
        lines.append("")

        lines.append(formatter.header("Apple Containerization (not used by pipelines)"))
        var appleRows: [(String, String)] = [
            ("Framework", appleContainerizationAvailable ? "available (macOS 26+, arm64)" : "not available"),
            ("Runtime", appleContainerRuntimeReady ? "ready" : "not ready"),
        ]
        if let appleContainerDetail, !appleContainerDetail.isEmpty {
            appleRows.append(("Detail", appleContainerDetail))
        }
        lines.append(formatter.keyValueTable(appleRows))
        return lines
    }
}
