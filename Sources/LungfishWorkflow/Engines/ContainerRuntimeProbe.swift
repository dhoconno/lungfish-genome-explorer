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
import LungfishCore

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
        // ToolProcess stops docker's whole process group at the timeout or when the calling task
        // is cancelled, so a cancel ends the probe at once and leaves no helper running.
        let spec = ToolProcessSpec(
            executableURL: URL(fileURLWithPath: dockerPath),
            arguments: ["version", "--format", format],
            environment: ToolProcessSpec.inheritedEnvironment(),
            timeout: .seconds(max(timeout, 0.001)),
            label: "docker"
        )
        let result: ToolProcessResult
        do {
            result = try await ToolProcess.run(spec)
        } catch ToolProcessError.timedOut(_, let results) {
            // What docker printed before the hang still names its client.
            return DockerDaemonProbe(
                reachable: false,
                clientVersion: Self.versions(in: results.first?.stdoutText ?? "").client,
                serverVersion: nil,
                detail: "docker version did not answer within \(String(format: "%g", timeout)) s"
            )
        } catch ToolProcessError.cancelled {
            return DockerDaemonProbe(
                reachable: false,
                clientVersion: nil,
                serverVersion: nil,
                detail: "docker version was cancelled"
            )
        } catch {
            return DockerDaemonProbe(
                reachable: false,
                clientVersion: nil,
                serverVersion: nil,
                detail: error.localizedDescription
            )
        }

        let (clientVersion, serverVersion) = Self.versions(in: result.stdoutText)
        if result.isSuccess, let serverVersion {
            return DockerDaemonProbe(
                reachable: true,
                clientVersion: clientVersion,
                serverVersion: serverVersion,
                detail: nil
            )
        }
        return DockerDaemonProbe(
            reachable: false,
            clientVersion: clientVersion,
            serverVersion: nil,
            detail: Self.firstLine(of: result.stderrText)
                ?? result.incompleteOutputReason
                ?? "docker version exited with status \(result.status)"
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

    /// How long `which` may take. It reads PATH and exits, so the limit only bounds a wedged file
    /// system.
    private static let whichTimeout: Duration = .seconds(10)

    /// Asks `/usr/bin/which` where `tool` is. The lookup is synchronous, because the protocol's is,
    /// so it runs on `ToolProcess.runBlocking`, which needs no Swift task and so completes even
    /// when every thread of the cooperative pool is busy.
    private static func which(_ tool: String) -> String? {
        let spec = ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/which"),
            arguments: [tool],
            environment: ToolProcessSpec.inheritedEnvironment(),
            stderr: .discard,
            timeout: whichTimeout,
            label: "which"
        )
        guard let result = try? ToolProcess.runBlocking(spec), result.isSuccess else { return nil }
        let path = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// The client and server versions on the first line of `docker version --format`'s output.
    private static func versions(in output: String) -> (client: String?, server: String?) {
        let fields = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init) } ?? []
        let client = fields.first.flatMap { $0.isEmpty ? nil : $0 }
        let server = fields.count > 1 && !fields[1].isEmpty ? fields[1] : nil
        return (client, server)
    }

    /// The first non-empty line of `text`, or nil.
    private static func firstLine(of text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)
    }
}
