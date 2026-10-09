// DockerRuntime.swift - Docker CLI-based runtime implementation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Workflow Integration Lead (Role 14)

import Foundation
import os.log
import Synchronization
import LungfishCore

// MARK: - DockerRuntime

/// Docker container runtime implementation (FALLBACK runtime).
///
/// `DockerRuntime` provides container functionality via the Docker CLI.
/// It is used as a fallback when Apple Containerization is not available
/// (pre-macOS 26, Intel Macs, or user preference).
///
/// ## Requirements
///
/// - Docker Desktop installed and running
/// - `docker` CLI in PATH
///
/// ## Implementation Notes
///
/// This implementation uses the Docker CLI rather than the Docker API for:
/// - Simpler setup (no socket configuration)
/// - Better compatibility across Docker versions
/// - Reduced dependencies
///
/// ## Example Usage
///
/// ```swift
/// let runtime = DockerRuntime()
///
/// // Check availability
/// guard await runtime.isAvailable() else {
///     print("Docker is not available")
///     return
/// }
///
/// // Pull and run
/// let image = try await runtime.pullImage(reference: "ubuntu:22.04")
/// let container = try await runtime.createContainer(
///     name: "test",
///     image: image,
///     config: .minimal()
/// )
/// try await runtime.startContainer(container)
/// ```
public actor DockerRuntime: ContainerRuntimeProtocol {
    // MARK: - Properties

    public let runtimeType: ContainerRuntimeType = .docker

    private let logger = Logger(
        subsystem: LogSubsystem.workflow,
        category: "DockerRuntime"
    )

    /// Path to the docker executable.
    private var dockerPath: String?

    /// Cached docker version.
    private var cachedVersion: String?

    /// Active containers managed by this runtime.
    private var activeContainers: [String: Container] = [:]

    /// Cache of pulled images.
    private var imageCache: [String: ContainerImage] = [:]

    // MARK: - Initialization

    /// Creates a new Docker runtime.
    public init() {
        logger.info("Docker runtime initialized")
    }

    // MARK: - ContainerRuntimeProtocol

    public func isAvailable() async -> Bool {
        // Find docker executable
        guard let path = await findDockerPath() else {
            logger.debug("Docker executable not found in PATH")
            return false
        }

        dockerPath = path

        // Check if daemon is running
        let (exitCode, _, _) = await runDockerCommand(["info"], timeout: 5.0)

        if exitCode != 0 {
            logger.info("Docker found but daemon is not running")
            return false
        }

        logger.info("Docker is available at \(path)")
        return true
    }

    public func version() async throws -> String {
        if let cached = cachedVersion {
            return cached
        }

        let (exitCode, stdout, stderr) = await runDockerCommand(["--version"])

        guard exitCode == 0 else {
            throw ContainerRuntimeError.versionCheckFailed(
                .docker,
                underlying: NSError(
                    domain: "DockerRuntime",
                    code: Int(exitCode),
                    userInfo: [NSLocalizedDescriptionKey: stderr]
                )
            )
        }

        // Parse version from "Docker version 24.0.6, build ed223bc"
        let version = parseDockerVersion(stdout)
        cachedVersion = version
        return version
    }

    public func pullImage(reference: String) async throws -> ContainerImage {
        logger.info("Pulling image: \(reference, privacy: .public)")

        // Check cache first
        if let cached = imageCache[reference] {
            logger.info("Image found in cache: \(reference, privacy: .public)")
            return cached
        }

        // Pull the image
        let (exitCode, _, stderr) = await runDockerCommand(
            ["pull", reference],
            timeout: 600.0  // 10 minute timeout for large images
        )

        guard exitCode == 0 else {
            throw ContainerRuntimeError.imagePullFailed(
                reference: reference,
                reason: stderr.isEmpty ? "Pull failed with exit code \(exitCode)" : stderr
            )
        }

        // Get image details
        let (inspectCode, inspectOutput, _) = await runDockerCommand([
            "inspect",
            "--format",
            "{{.Id}}|{{.Size}}|{{.Created}}|{{.Architecture}}|{{.Os}}",
            reference
        ])

        var digest: String?
        var sizeBytes: UInt64?
        var createdAt: Date?
        var architecture: String?
        var os: String?

        if inspectCode == 0 {
            let parts = inspectOutput.split(separator: "|")
            if parts.count >= 5 {
                digest = String(parts[0])
                sizeBytes = UInt64(parts[1])
                createdAt = ISO8601DateFormatter().date(from: String(parts[2]))
                architecture = String(parts[3])
                os = String(parts[4])
            }
        }

        let image = ContainerImage(
            id: digest ?? UUID().uuidString,
            reference: reference,
            digest: digest,
            rootfsPath: nil,  // Docker manages its own storage
            sizeBytes: sizeBytes,
            createdAt: createdAt,
            pulledAt: Date(),
            architecture: architecture,
            os: os,
            runtimeType: .docker
        )

        imageCache[reference] = image
        logger.info("Image pulled successfully: \(reference, privacy: .public)")

        return image
    }

    public func createContainer(
        name: String,
        image: ContainerImage,
        config: ContainerConfiguration
    ) async throws -> Container {
        logger.info("Creating container: \(name, privacy: .public)")

        // Build docker create command
        var args = ["create", "--name", name]

        // Resource limits
        if let cpuCount = config.cpuCount {
            args.append(contentsOf: ["--cpus", String(cpuCount)])
        }

        if let memoryBytes = config.memoryBytes {
            args.append(contentsOf: ["--memory", String(memoryBytes)])
        }

        // Hostname
        if let hostname = config.hostname {
            args.append(contentsOf: ["--hostname", hostname])
        }

        // Working directory
        if let workingDirectory = config.workingDirectory {
            args.append(contentsOf: ["--workdir", workingDirectory])
        }

        // Environment variables
        for (key, value) in config.environment {
            args.append(contentsOf: ["-e", "\(key)=\(value)"])
        }

        // Network mode
        args.append(contentsOf: ["--network", config.networkMode.dockerNetworkFlag])

        // Port mappings
        for mapping in config.portMappings {
            args.append(contentsOf: ["-p", mapping.dockerFlag])
        }

        // Mount bindings
        for mount in config.mounts {
            args.append(contentsOf: ["-v", mount.dockerMountSpec])
        }

        // User/group
        if let userID = config.userID {
            if let groupID = config.groupID {
                args.append(contentsOf: ["--user", "\(userID):\(groupID)"])
            } else {
                args.append(contentsOf: ["--user", String(userID)])
            }
        }

        // Additional Docker options
        args.append(contentsOf: config.dockerOptions)

        // Image reference
        args.append(image.reference)

        if let command = config.command, !command.isEmpty {
            args.append(contentsOf: command)
        } else {
            // Default command to keep container running for exec-based workflows.
            args.append(contentsOf: ["tail", "-f", "/dev/null"])
        }

        // Run docker create
        let (exitCode, stdout, stderr) = await runDockerCommand(args)

        guard exitCode == 0 else {
            throw ContainerRuntimeError.containerCreationFailed(
                name: name,
                reason: stderr.isEmpty ? "Creation failed with exit code \(exitCode)" : stderr
            )
        }

        let containerID = stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let container = Container(
            id: containerID,
            name: name,
            runtimeType: .docker,
            state: .created,
            image: image,
            configuration: config,
            hostname: config.hostname ?? name,
            nativeContainer: AnySendable(containerID)
        )

        activeContainers[containerID] = container

        logger.info("Container created: \(name, privacy: .public) [\(containerID.prefix(12))]")

        return container
    }

    public func startContainer(_ container: Container) async throws {
        logger.info("Starting container: \(container.name, privacy: .public)")

        let (exitCode, _, stderr) = await runDockerCommand(["start", container.id])

        guard exitCode == 0 else {
            throw ContainerRuntimeError.containerStartFailed(
                containerID: container.id,
                reason: stderr.isEmpty ? "Start failed with exit code \(exitCode)" : stderr
            )
        }

        // Update container state
        if var updatedContainer = activeContainers[container.id] {
            try updatedContainer.updateState(.running)

            // Get container IP address
            let (inspectCode, ipOutput, _) = await runDockerCommand([
                "inspect",
                "--format",
                "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
                container.id
            ])

            if inspectCode == 0 {
                let ip = ipOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                if !ip.isEmpty {
                    updatedContainer.setIPAddress(ip)
                }
            }

            activeContainers[container.id] = updatedContainer
        }

        logger.info("Container started: \(container.name, privacy: .public)")
    }

    public func runAndWait(_ container: Container) async throws -> Int32 {
        logger.info("Running container to completion: \(container.name, privacy: .public)")

        let (exitCode, _, stderr) = await runDockerCommand(
            ["start", "--attach", container.id],
            timeout: 24 * 60 * 60
        )

        if var updatedContainer = activeContainers[container.id] {
            try? updatedContainer.updateState(.stopped)
            activeContainers[container.id] = updatedContainer
        }

        guard exitCode >= 0 else {
            throw ContainerRuntimeError.containerStartFailed(
                containerID: container.id,
                reason: stderr.isEmpty ? "Docker start failed" : stderr
            )
        }

        logger.info("Container completed: \(container.name, privacy: .public) [exit \(exitCode)]")
        return exitCode
    }

    public func stopContainer(_ container: Container) async throws {
        logger.info("Stopping container: \(container.name, privacy: .public)")

        let currentState = activeContainers[container.id]?.state ?? container.state
        if currentState == .stopped {
            logger.debug("stopContainer: Container already stopped: \(container.name, privacy: .public)")
            return
        }
        if currentState == .created {
            if var updatedContainer = activeContainers[container.id] {
                try? updatedContainer.updateState(.stopped)
                activeContainers[container.id] = updatedContainer
            }
            return
        }

        // Update state to stopping
        if var updatedContainer = activeContainers[container.id] {
            try? updatedContainer.updateState(.stopping)
            activeContainers[container.id] = updatedContainer
        }

        let (exitCode, _, stderr) = await runDockerCommand(
            ["stop", "--time", "10", container.id],
            timeout: 30.0
        )

        guard exitCode == 0 else {
            throw ContainerRuntimeError.containerStopFailed(
                containerID: container.id,
                reason: stderr.isEmpty ? "Stop failed with exit code \(exitCode)" : stderr
            )
        }

        // Update state to stopped
        if var updatedContainer = activeContainers[container.id] {
            try? updatedContainer.updateState(.stopped)
            activeContainers[container.id] = updatedContainer
        }

        logger.info("Container stopped: \(container.name, privacy: .public)")
    }

    public func exec(
        in container: Container,
        command: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String
    ) async throws -> ContainerProcess {
        logger.info("Exec in container \(container.name, privacy: .public): \(command, privacy: .public)")

        guard container.state == .running else {
            throw ContainerRuntimeError.invalidContainerState(
                containerID: container.id,
                expected: .running,
                actual: container.state
            )
        }

        // Build docker exec command
        var args = ["exec"]

        // Working directory
        args.append(contentsOf: ["-w", workingDirectory])

        // Environment variables
        for (key, value) in environment {
            args.append(contentsOf: ["-e", "\(key)=\(value)"])
        }

        // Container ID
        args.append(container.id)

        // Command and arguments
        args.append(command)
        args.append(contentsOf: arguments)

        // Capture values for use in closures
        let execArgs = args
        let containerId = container.id
        let execCommand = command
        let currentDockerPath = dockerPath
        let execRun = DockerExecRun()

        let containerProcess = ContainerProcess(
            command: command,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            containerID: container.id,
            startHandler: {
                guard let path = currentDockerPath else {
                    throw ContainerRuntimeError.execFailed(
                        containerID: containerId,
                        command: execCommand,
                        reason: "Docker executable not found"
                    )
                }
                guard let outputWriter = execRun.outputWriter else {
                    throw ContainerRuntimeError.execFailed(
                        containerID: containerId,
                        command: execCommand,
                        reason: "Output writer not set"
                    )
                }
                // Stdout streams raw, byte for byte. A capture limit of 0
                // streams stderr's lines without keeping the whole output.
                let spec = ToolProcessSpec(
                    executableURL: URL(fileURLWithPath: path),
                    arguments: execArgs,
                    environment: ToolProcessSpec.inheritedEnvironment(),
                    stdout: .stream,
                    stderr: .capture(limit: 0),
                    label: "docker exec"
                )
                do {
                    try await execRun.start(spec, writer: outputWriter)
                } catch {
                    throw ContainerRuntimeError.execFailed(
                        containerID: containerId,
                        command: execCommand,
                        reason: error.localizedDescription
                    )
                }
            },
            waitHandler: {
                let result: ToolProcessResult
                do {
                    guard let finished = try await execRun.wait() else { return -1 }
                    result = finished
                } catch let error as ToolProcessError {
                    throw ContainerRuntimeError.execFailed(
                        containerID: containerId,
                        command: execCommand,
                        reason: error.localizedDescription
                    )
                }
                // A run a signal stopped is reported by its status alone.
                if result.stop == nil, let reason = result.incompleteOutputReason {
                    throw ContainerRuntimeError.execFailed(containerID: containerId, command: execCommand, reason: reason)
                }
                return result.status
            },
            signalHandler: { signal in
                // SIGTERM and SIGKILL stop the docker client's whole process
                // tree, SIGTERM first and SIGKILL after the grace period.
                if signal == SIGKILL || signal == SIGTERM {
                    execRun.stop()
                }
            }
        )

        // Set the output writer reference in the holder
        execRun.setOutputWriter(containerProcess)

        return containerProcess
    }

    public func removeContainer(_ container: Container) async throws {
        logger.info("Removing container: \(container.name, privacy: .public)")

        var currentState = activeContainers[container.id]?.state ?? container.state
        if currentState == .running || currentState == .stopping {
            try? await stopContainer(container)
            currentState = activeContainers[container.id]?.state ?? .stopped
        }

        guard currentState == .stopped || currentState == .created else {
            logger.debug("removeContainer: forcing local cleanup for \(container.name, privacy: .public) in state \(String(describing: currentState), privacy: .public)")
            activeContainers.removeValue(forKey: container.id)
            return
        }

        let (exitCode, _, stderr) = await runDockerCommand(["rm", container.id])

        guard exitCode == 0 else {
            throw ContainerRuntimeError.containerRemoveFailed(
                containerID: container.id,
                reason: stderr.isEmpty ? "Remove failed with exit code \(exitCode)" : stderr
            )
        }

        activeContainers.removeValue(forKey: container.id)

        logger.info("Container removed: \(container.name, privacy: .public)")
    }

    // MARK: - Additional Methods

    /// Returns all active containers.
    public func listContainers() -> [Container] {
        Array(activeContainers.values)
    }

    /// Returns a container by ID.
    public func container(id: String) -> Container? {
        activeContainers[id]
    }

    /// Gets the docker path.
    public func getDockerPath() -> String? {
        dockerPath
    }

    /// Clears the image cache.
    public func clearImageCache() {
        imageCache.removeAll()
        logger.info("Image cache cleared")
    }

    // MARK: - Private Methods

    private func findDockerPath() async -> String? {
        let spec = ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/which"),
            arguments: ["docker"],
            environment: ToolProcessSpec.inheritedEnvironment(),
            stderr: .discard,
            label: "which docker"
        )
        do {
            let result = try await ToolProcess.run(spec)
            if result.isSuccess {
                let path = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty {
                    return path
                }
            }
        } catch {
            logger.debug("Failed to find docker: \(error.localizedDescription)")
        }

        return nil
    }

    /// Runs the docker CLI and returns its exit status and trimmed output.
    ///
    /// A run that cannot produce a trustworthy result, because docker could
    /// not launch, ran past `timeout`, was cancelled or left its output
    /// incomplete, returns status -1 with the reason in stderr. A timed-out or
    /// cancelled run has its whole process tree stopped first.
    private func runDockerCommand(
        _ arguments: [String],
        timeout: TimeInterval = 120.0
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {

        // Resolve docker path first
        var resolvedPath = dockerPath
        if resolvedPath == nil {
            resolvedPath = await findDockerPath()
            if resolvedPath != nil {
                dockerPath = resolvedPath
            }
        }

        guard let path = resolvedPath else {
            return (-1, "", "Docker executable not found")
        }

        let spec = ToolProcessSpec(
            executableURL: URL(fileURLWithPath: path),
            arguments: arguments,
            environment: ToolProcessSpec.inheritedEnvironment(),
            timeout: .seconds(timeout),
            label: "docker"
        )
        let command = (["docker"] + arguments.prefix(1)).joined(separator: " ")
        func trimmed(_ data: Data) -> String {
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let result: ToolProcessResult
        do {
            result = try await ToolProcess.run(spec)
        } catch .timedOut(_, let results) {
            let stdout = results.first.map { trimmed($0.stdout) } ?? ""
            let stderr = results.first.map { trimmed($0.stderr) } ?? ""
            let reason = "\(command) timed out after \(Int(timeout)) seconds"
            return (-1, stdout, stderr.isEmpty ? reason : stderr + "\n" + reason)
        } catch .cancelled {
            return (-1, "", "\(command) was cancelled")
        } catch {
            return (-1, "", error.localizedDescription)
        }

        let stdout = trimmed(result.stdout)
        let stderr = trimmed(result.stderr)
        if let reason = result.incompleteOutputReason {
            return (-1, stdout, stderr.isEmpty ? reason : stderr + "\n" + reason)
        }
        return (result.status, stdout, stderr)
    }

    private func parseDockerVersion(_ output: String) -> String {
        // Parse "Docker version 24.0.6, build ed223bc"
        if let range = output.range(of: #"Docker version ([\d.]+)"#, options: .regularExpression) {
            let match = String(output[range])
            if let versionStart = match.firstIndex(of: " "),
               let versionEnd = match.firstIndex(of: ",") ?? match.endIndex as String.Index? {
                let version = String(match[match.index(after: match.index(after: versionStart))..<versionEnd])
                return version.trimmingCharacters(in: .whitespaces)
            }
        }

        // Try simpler extraction
        let components = output.split(separator: " ")
        if components.count >= 3 {
            var version = String(components[2])
            if version.hasSuffix(",") {
                version.removeLast()
            }
            return version
        }

        return "unknown"
    }
}

// MARK: - DockerExecRun

/// One `docker exec` run on ToolProcess, shared by the start, wait and
/// signal handlers of its ``ContainerProcess``.
///
/// The run keeps going between `start()` and `wait()`. An unstructured task
/// copies stdout into the process's stream byte for byte, CRs included, and
/// stderr arrives as framed lines, each ending in a newline. The streams
/// finish when the run is over. A signal or a cancelled `wait()` stops
/// docker's whole process tree.
private final class DockerExecRun: Sendable {
    private struct State {
        weak var outputWriter: ContainerProcess?
        var run: ToolProcessRun?
        var task: Task<ToolProcessResult, any Error>?
    }

    private let state = Mutex(State())

    var outputWriter: ContainerProcess? {
        state.withLock { $0.outputWriter }
    }

    func setOutputWriter(_ writer: ContainerProcess) {
        state.withLock { $0.outputWriter = writer }
    }

    /// Launches docker and returns once it is running, or throws when it
    /// could not launch.
    func start(_ spec: ToolProcessSpec, writer: ContainerProcess) async throws {
        let run = try ToolProcess.start(
            spec,
            onEvent: { event in
                guard case .output(.stderr, let line) = event else { return }
                writer.writeStderr(Data((line + "\n").utf8))
            }
        )
        let task = Task<ToolProcessResult, any Error> {
            defer { writer.finishStreams() }
            _ = await run.stdout.drain(()) { _, chunk in
                writer.writeStdout(chunk)
                return true
            }
            return try await run.result()
        }
        state.withLock {
            $0.run = run
            $0.task = task
        }
        // The spawn happened inside start, so a failed one is the run's error.
        if run.pid == nil, case .failure(let error) = await task.result {
            throw error
        }
    }

    /// The finished run, or nil when it never started. Cancelling the
    /// calling task stops the run and throws `CancellationError`.
    func wait() async throws -> ToolProcessResult? {
        guard let task = state.withLock({ $0.task }) else { return nil }
        let outcome = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            self.stop()
        }
        switch outcome {
        case .success(let result):
            return result
        case .failure(ToolProcessError.cancelled(let results)):
            if Task.isCancelled { throw CancellationError() }
            // Stopped through a signal: report how docker ended.
            guard let result = results.first else { throw CancellationError() }
            return result
        case .failure(let error):
            throw error
        }
    }

    /// Stops docker's tree, which ends the stdout copy at end of file.
    func stop() {
        let (run, task) = state.withLock { ($0.run, $0.task) }
        run?.cancel()
        task?.cancel()
    }
}
