// ContainerRuntimeProbe.swift - Docker daemon and Apple Containerization probes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Shared by `lungfish-cli debug container` and the Nextflow wizards (TaxTriage,
// Viral Recon). Both need the same answer: can a `-profile docker` pipeline
// launch right now? Only the Docker daemon settles that. Apple Containerization
// may be ready on the same machine and still not run a single pipeline
// container, so readiness lines must never be derived from
// `NewContainerRuntimeFactory.createRuntime()`, which prefers Apple.

import Foundation

// MARK: - Probe results

/// Result of asking the Docker daemon for its version.
public struct DockerDaemonProbe: Sendable, Equatable {
    /// Whether `docker version` reached the daemon.
    public var reachable: Bool
    /// Docker CLI (client) version, when the CLI ran at all.
    public var clientVersion: String?
    /// Docker Engine (server) version, when the daemon answered.
    public var serverVersion: String?
    /// One line explaining an unreachable daemon (stderr, timeout, ...).
    public var detail: String?

    public init(reachable: Bool, clientVersion: String?, serverVersion: String?, detail: String?) {
        self.reachable = reachable
        self.clientVersion = clientVersion
        self.serverVersion = serverVersion
        self.detail = detail
    }
}

/// Result of checking the Apple Containerization runtime.
public struct AppleContainerProbe: Sendable, Equatable {
    /// macOS 26 or later on Apple Silicon, where the framework can load.
    public var frameworkAvailable: Bool
    /// The runtime initialised and reports itself ready.
    public var runtimeReady: Bool
    /// One line explaining why the runtime is not ready.
    public var detail: String?

    public init(frameworkAvailable: Bool, runtimeReady: Bool, detail: String?) {
        self.frameworkAvailable = frameworkAvailable
        self.runtimeReady = runtimeReady
        self.detail = detail
    }
}

// MARK: - Probe protocol

/// Everything a readiness check needs to know, behind a protocol so tests
/// can inject a stub instead of running `docker`.
public protocol ContainerRuntimeProbing: Sendable {
    /// Absolute path of the `docker` CLI, or `nil` when it is not installed.
    func dockerCLIPath() -> String?
    /// Asks the daemon for its version, giving up after `timeout` seconds.
    func dockerDaemon(dockerPath: String, timeout: TimeInterval) async -> DockerDaemonProbe
    /// Checks the Apple Containerization runtime.
    func appleContainerRuntime() async -> AppleContainerProbe
}

// MARK: - Pipeline readiness

/// The one-line verdict a Nextflow wizard shows for its container prerequisite.
///
/// `available` is `true` only when the Docker daemon answered, because that is
/// the runtime the pipelines launch with. The label names Docker Desktop so the
/// user knows what to start; the CLI's `debug container` report shares the
/// same name through `runtimeName`.
public struct PipelineContainerRuntimeStatus: Sendable, Equatable {
    /// Runtime that Nextflow pipelines (Viral Recon, TaxTriage) launch with
    /// (`-profile docker`).
    public static let runtimeName = "Docker Desktop"

    /// Default seconds to wait for `docker version` before calling the daemon
    /// unreachable. Matches `lungfish-cli debug container --timeout`.
    public static let defaultProbeTimeout: TimeInterval = 5

    /// Whether a pipeline can launch through Docker right now.
    public let available: Bool
    /// Short label for a prerequisite row, such as "Docker Desktop: Running".
    public let label: String
    /// One line explaining an unavailable runtime, for tooltips and logs.
    public let detail: String?
    /// The daemon probe this status was derived from.
    public let daemon: DockerDaemonProbe
    /// Where the `docker` CLI was found, or `nil` when it is not installed.
    public let dockerCLIPath: String?

    public init(
        available: Bool,
        label: String,
        detail: String?,
        daemon: DockerDaemonProbe,
        dockerCLIPath: String?
    ) {
        self.available = available
        self.label = label
        self.detail = detail
        self.daemon = daemon
        self.dockerCLIPath = dockerCLIPath
    }

    /// Message for a wizard's validation line when the runtime is unavailable.
    public var unavailableMessage: String {
        if dockerCLIPath == nil {
            return "\(Self.runtimeName) is not installed"
        }
        return "\(Self.runtimeName) is not running"
    }

    /// Probes the Docker daemon and folds the answer into a status line.
    ///
    /// The Apple Containerization runtime is deliberately not consulted: it
    /// cannot make a `-profile docker` pipeline runnable.
    public static func check(
        probe: any ContainerRuntimeProbing,
        timeout: TimeInterval = defaultProbeTimeout
    ) async -> PipelineContainerRuntimeStatus {
        guard let dockerPath = probe.dockerCLIPath() else {
            let daemon = DockerDaemonProbe(
                reachable: false,
                clientVersion: nil,
                serverVersion: nil,
                detail: "docker CLI not found in PATH or the usual install locations"
            )
            return PipelineContainerRuntimeStatus(
                available: false,
                label: "\(runtimeName): Not installed",
                detail: daemon.detail,
                daemon: daemon,
                dockerCLIPath: nil
            )
        }
        let daemon = await probe.dockerDaemon(dockerPath: dockerPath, timeout: timeout)
        if daemon.reachable {
            return PipelineContainerRuntimeStatus(
                available: true,
                label: "\(runtimeName): Running",
                detail: nil,
                daemon: daemon,
                dockerCLIPath: dockerPath
            )
        }
        return PipelineContainerRuntimeStatus(
            available: false,
            label: "\(runtimeName): Not running",
            detail: daemon.detail,
            daemon: daemon,
            dockerCLIPath: dockerPath
        )
    }
}

// MARK: - System probe

/// The real probe: finds `docker`, runs `docker version` with a timeout, and
/// tries to initialise the Apple Containerization runtime.
public struct SystemContainerRuntimeProbe: ContainerRuntimeProbing {
    /// Locations Docker Desktop installs its CLI into. `which` covers an
    /// interactive shell; these cover a process launched from the app, whose
    /// PATH may be bare. A Homebrew-installed CLI is found through
    /// HOMEBREW_PREFIX when the environment carries it; the prefix is never
    /// hardcoded (ReleaseBuildConfigurationTests polices that).
    public static let fallbackDockerPaths: [String] = {
        var paths = [
            "/usr/local/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
            NSHomeDirectory() + "/.docker/bin/docker",
        ]
        if let prefix = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"],
           !prefix.isEmpty {
            paths.insert(prefix + "/bin/docker", at: 1)
        }
        return paths
    }()

    public init() {}

    public func dockerCLIPath() -> String? {
        if let path = Self.which("docker") {
            return path
        }
        let fileManager = FileManager.default
        return Self.fallbackDockerPaths.first { fileManager.isExecutableFile(atPath: $0) }
    }

    public func dockerDaemon(dockerPath: String, timeout: TimeInterval) async -> DockerDaemonProbe {
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

    public func appleContainerRuntime() async -> AppleContainerProbe {
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
        await ProbeProcessRunner().run(
            executable: executable,
            arguments: arguments,
            timeout: timeout
        )
    }

    /// Runs one process with a watchdog, the same way `DockerRuntime` does.
    /// Being an actor keeps the `Process` on one isolation domain, which is
    /// what strict concurrency needs for the timeout task to capture it.
    private actor ProbeProcessRunner {
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

            let timedOut = ProbeTimeoutFlag()
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
private final class ProbeTimeoutFlag: @unchecked Sendable {
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
