// ContainerRuntimeDiagnostics.swift - Probes for `lungfish-cli debug container`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

// MARK: - Probe protocol

/// Result of asking the Docker daemon for its version.
struct DockerDaemonProbe: Sendable, Equatable {
    /// Whether `docker version` reached the daemon.
    var reachable: Bool
    /// Docker CLI (client) version, when the CLI ran at all.
    var clientVersion: String?
    /// Docker Engine (server) version, when the daemon answered.
    var serverVersion: String?
    /// One line explaining an unreachable daemon (stderr, timeout, ...).
    var detail: String?
}

/// Result of checking the Apple Containerization runtime.
struct AppleContainerProbe: Sendable, Equatable {
    /// macOS 26 or later on Apple Silicon, where the framework can load.
    var frameworkAvailable: Bool
    /// The runtime initialised and reports itself ready.
    var runtimeReady: Bool
    /// One line explaining why the runtime is not ready.
    var detail: String?
}

/// Everything `debug container` needs to know, behind a protocol so tests
/// can inject a stub instead of running `docker`.
protocol ContainerRuntimeProbing: Sendable {
    /// Absolute path of the `docker` CLI, or `nil` when it is not installed.
    func dockerCLIPath() -> String?
    /// Asks the daemon for its version, giving up after `timeout` seconds.
    func dockerDaemon(dockerPath: String, timeout: TimeInterval) async -> DockerDaemonProbe
    /// Checks the Apple Containerization runtime.
    func appleContainerRuntime() async -> AppleContainerProbe
}

// MARK: - Report

/// What `debug container` prints, in text or JSON.
struct ContainerRuntimeReport: Codable, Equatable, Sendable {
    /// Runtime that Nextflow pipelines (Viral Recon, TaxTriage) launch with
    /// (`-profile docker`).
    static let pipelineRuntimeName = "Docker Desktop"

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

// MARK: - System probe

/// The real probe: finds `docker`, runs `docker version` with a timeout, and
/// tries to initialise the Apple Containerization runtime.
struct SystemContainerRuntimeProbe: ContainerRuntimeProbing {
    /// Locations Docker Desktop installs its CLI into. `which` covers an
    /// interactive shell; these cover a CLI launched from the app, whose PATH
    /// may be bare.
    static let fallbackDockerPaths: [String] = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
        NSHomeDirectory() + "/.docker/bin/docker",
    ]

    func dockerCLIPath() -> String? {
        if let path = Self.which("docker") {
            return path
        }
        let fileManager = FileManager.default
        return Self.fallbackDockerPaths.first { fileManager.isExecutableFile(atPath: $0) }
    }

    func dockerDaemon(dockerPath: String, timeout: TimeInterval) async -> DockerDaemonProbe {
        // `docker version` prints the client block even when the daemon is
        // down, exits non-zero, and explains on stderr. One call gives the
        // whole picture. The separator is not a tab: docker feeds templates
        // containing `\t` through a tabwriter, which pads with spaces.
        let format = "{{.Client.Version}}|{{if .Server}}{{.Server.Version}}{{end}}"
        let result = await Self.run(
            executable: dockerPath,
            arguments: ["version", "--format", format],
            timeout: timeout
        )

        let fields = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init) } ?? []
        let clientVersion = fields.first.flatMap { $0.isEmpty ? nil : $0 }
        let serverVersion = fields.count > 1 && !fields[1].isEmpty ? fields[1] : nil

        if result.timedOut {
            return DockerDaemonProbe(
                reachable: false,
                clientVersion: clientVersion,
                serverVersion: nil,
                detail: "docker version did not answer within \(String(format: "%g", timeout)) s"
            )
        }
        if result.exitCode == 0, let serverVersion {
            return DockerDaemonProbe(
                reachable: true,
                clientVersion: clientVersion,
                serverVersion: serverVersion,
                detail: nil
            )
        }
        let stderrLine = result.stderr
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)
        return DockerDaemonProbe(
            reachable: false,
            clientVersion: clientVersion,
            serverVersion: nil,
            detail: stderrLine ?? "docker version exited with status \(result.exitCode)"
        )
    }

    func appleContainerRuntime() async -> AppleContainerProbe {
        guard NewContainerRuntimeFactory.isAppleContainerizationAvailable() else {
            return AppleContainerProbe(
                frameworkAvailable: false,
                runtimeReady: false,
                detail: "requires macOS 26 or later on Apple Silicon"
            )
        }
        if #available(macOS 26, *) {
            do {
                let runtime = try await AppleContainerRuntime()
                let ready = await runtime.isAvailable()
                return AppleContainerProbe(
                    frameworkAvailable: true,
                    runtimeReady: ready,
                    detail: ready ? nil : "runtime initialised but reports unavailable"
                )
            } catch {
                return AppleContainerProbe(
                    frameworkAvailable: true,
                    runtimeReady: false,
                    detail: error.localizedDescription
                )
            }
        }
        return AppleContainerProbe(frameworkAvailable: false, runtimeReady: false, detail: nil)
    }

    // MARK: Process helpers

    private static func which(_ tool: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [tool]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private struct ProcessResult {
        var exitCode: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
    }

    private static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async -> ProcessResult {
        await DiagnosticProcessRunner().run(
            executable: executable,
            arguments: arguments,
            timeout: timeout
        )
    }

    /// Runs one process with a watchdog, the same way `DockerRuntime` does.
    /// Being an actor keeps the `Process` on one isolation domain, which is
    /// what strict concurrency needs for the timeout task to capture it.
    private actor DiagnosticProcessRunner {
        func run(
            executable: String,
            arguments: [String],
            timeout: TimeInterval
        ) -> ProcessResult {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                return ProcessResult(
                    exitCode: -1,
                    stdout: "",
                    stderr: error.localizedDescription,
                    timedOut: false
                )
            }

            let timedOut = ProcessTimeoutFlag()
            let watchdog = Task {
                try await Task.sleep(for: .seconds(timeout))
                if process.isRunning {
                    timedOut.set()
                    process.terminate()
                }
            }

            // Drain both pipes before waiting so a chatty child cannot block
            // on a full pipe buffer.
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()

            return ProcessResult(
                exitCode: process.terminationStatus,
                stdout: String(decoding: stdoutData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                stderr: String(decoding: stderrData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                timedOut: timedOut.value
            )
        }
    }
}

/// Thread-safe flag shared between the timeout timer and the termination handler.
private final class ProcessTimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
