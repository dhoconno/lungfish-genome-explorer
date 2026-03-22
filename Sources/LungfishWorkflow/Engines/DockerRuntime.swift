// DockerRuntime.swift - Docker CLI-based runtime implementation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Workflow Integration Lead (Role 14)
// Advisor: Apple Containerization Expert (Role 21)

import Foundation
import os.log
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

        // Default command to keep container running
        args.append(contentsOf: ["tail", "-f", "/dev/null"])

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

        // Create a combined holder for process and output writer
        let execHolder = DockerExecHolder()

        let containerProcess = ContainerProcess(
            command: command,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            containerID: container.id,
            startHandler: {
                let proc = Process()
                await execHolder.setProcess(proc)

                guard let path = currentDockerPath else {
                    throw ContainerRuntimeError.execFailed(
                        containerID: containerId,
                        command: execCommand,
                        reason: "Docker executable not found"
                    )
                }

                proc.executableURL = URL(fileURLWithPath: path)
                proc.arguments = execArgs

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                proc.standardOutput = stdoutPipe
                proc.standardError = stderrPipe

                // Get the output writer from the holder
                guard let outputWriter = await execHolder.getOutputWriter() else {
                    throw ContainerRuntimeError.execFailed(
                        containerID: containerId,
                        command: execCommand,
                        reason: "Output writer not set"
                    )
                }

                // Stream stdout
                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if !data.isEmpty {
                        outputWriter.writeStdout(data)
                    }
                }

                // Stream stderr
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if !data.isEmpty {
                        outputWriter.writeStderr(data)
                    }
                }

                try proc.run()
            },
            waitHandler: {
                guard let proc = await execHolder.getProcess() else { return -1 }
                proc.waitUntilExit()

                // Clean up handlers
                if let stdout = proc.standardOutput as? Pipe {
                    stdout.fileHandleForReading.readabilityHandler = nil
                }
                if let stderr = proc.standardError as? Pipe {
                    stderr.fileHandleForReading.readabilityHandler = nil
                }

                return proc.terminationStatus
            },
            signalHandler: { signal in
                guard let proc = await execHolder.getProcess() else { return }
                if signal == 9 {
                    proc.terminate()
                } else if signal == 15 {
                    proc.interrupt()
                }
            }
        )

        // Set the output writer reference in the holder
        await execHolder.setOutputWriter(containerProcess)

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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["docker"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    return path
                }
            }
        } catch {
            logger.debug("Failed to find docker: \(error.localizedDescription)")
        }

        return nil
    }

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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()

            // Set up timeout
            let timeoutTask = Task {
                try await Task.sleep(for: .seconds(timeout))
                if process.isRunning {
                    process.terminate()
                }
            }

            process.waitUntilExit()
            timeoutTask.cancel()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            let stdout = String(decoding: stdoutData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = String(decoding: stderrData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return (process.terminationStatus, stdout, stderr)

        } catch {
            return (-1, "", error.localizedDescription)
        }
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

// MARK: - DockerExecHolder

/// Thread-safe holder for Docker exec state including process and output writer.
private actor DockerExecHolder {
    private var process: Process?
    private weak var outputWriter: ContainerProcess?

    func setProcess(_ proc: Process) {
        self.process = proc
    }

    func getProcess() -> Process? {
        return process
    }

    func setOutputWriter(_ writer: ContainerProcess) {
        self.outputWriter = writer
    }

    func getOutputWriter() -> ContainerProcess? {
        return outputWriter
    }
}
