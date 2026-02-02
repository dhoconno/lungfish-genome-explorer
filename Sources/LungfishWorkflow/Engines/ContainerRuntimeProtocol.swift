// ContainerRuntimeProtocol.swift - Abstract container runtime protocol
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Workflow Integration Lead (Role 14)
// Advisor: Apple Containerization Expert (Role 21)

import Foundation

// MARK: - ContainerRuntimeType

/// Container runtime types supported by Lungfish.
///
/// Runtime priority:
/// 1. `appleContainerization` - Native Swift APIs, macOS 26+, Apple Silicon only
/// 2. `docker` - Fallback for older systems or user preference
public enum ContainerRuntimeType: String, Sendable, CaseIterable, Codable {
    /// Apple Containerization framework (macOS 26+, Apple Silicon).
    ///
    /// Native Swift APIs with VM-per-container isolation, sub-second startup,
    /// and dedicated IP networking. Recommended for macOS 26+ on Apple Silicon.
    case appleContainerization = "apple"

    /// Docker container runtime.
    ///
    /// CLI-based implementation using the docker command. Works on all macOS
    /// versions but requires Docker Desktop to be installed and running.
    case docker = "docker"

    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .appleContainerization:
            return "Apple Containerization"
        case .docker:
            return "Docker"
        }
    }

    /// SF Symbol icon name for this runtime type.
    public var iconName: String {
        switch self {
        case .appleContainerization:
            return "apple.logo"
        case .docker:
            return "shippingbox"
        }
    }

    /// Whether this runtime requires a daemon process.
    public var requiresDaemon: Bool {
        switch self {
        case .appleContainerization:
            return false  // VM-per-container, no shared daemon
        case .docker:
            return true   // Docker Desktop daemon required
        }
    }

    /// Minimum macOS version required for this runtime.
    public var minimumMacOSVersion: OperatingSystemVersion {
        switch self {
        case .appleContainerization:
            return OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        case .docker:
            return OperatingSystemVersion(majorVersion: 12, minorVersion: 0, patchVersion: 0)
        }
    }
}

// MARK: - ContainerRuntimeProtocol

/// Protocol defining container runtime capabilities.
///
/// Implementations handle specific container runtimes like Apple Containerization
/// or Docker. The runtime is responsible for:
/// - Pulling OCI images from registries
/// - Creating and managing containers
/// - Executing processes within containers
/// - Streaming I/O from container processes
///
/// ## Thread Safety
///
/// All implementations must be actors to ensure thread-safe access to container
/// state and avoid race conditions during concurrent operations.
///
/// ## Implementation Notes
///
/// - Use `os.log` for logging throughout
/// - Handle cleanup on actor deinitialization
/// - Support structured concurrency with proper cancellation
///
/// ## Example
///
/// ```swift
/// // Get the preferred runtime
/// guard let runtime = await ContainerRuntimeFactory.createRuntime() else {
///     throw ContainerRuntimeError.noRuntimeAvailable
/// }
///
/// // Pull an image
/// let image = try await runtime.pullImage(reference: "biocontainers/bwa:0.7.17")
///
/// // Create and start a container
/// let config = ContainerConfiguration(cpuCount: 4, memoryBytes: 8.gib())
/// let container = try await runtime.createContainer(
///     name: "bwa-alignment",
///     image: image,
///     config: config
/// )
/// try await runtime.startContainer(container)
///
/// // Execute a process
/// let process = try await runtime.exec(
///     in: container,
///     command: "bwa",
///     arguments: ["mem", "ref.fa", "reads.fq"],
///     environment: [:],
///     workingDirectory: "/workspace"
/// )
/// try await process.start()
/// let exitCode = try await process.wait()
///
/// // Cleanup
/// try await runtime.stopContainer(container)
/// try await runtime.removeContainer(container)
/// ```
public protocol ContainerRuntimeProtocol: Actor, Sendable {
    /// The runtime type identifier.
    var runtimeType: ContainerRuntimeType { get }

    /// Human-readable name of the runtime.
    var displayName: String { get }

    /// Checks whether this runtime is available on the current system.
    ///
    /// For Apple Containerization, this checks macOS version and architecture.
    /// For Docker, this checks if the docker CLI is installed and daemon is running.
    ///
    /// - Returns: `true` if the runtime is available and ready to use
    func isAvailable() async -> Bool

    /// Returns the version string of the runtime.
    ///
    /// - Returns: Version string (e.g., "1.0.0" for Apple, "24.0.6" for Docker)
    /// - Throws: `ContainerRuntimeError.versionCheckFailed` if version cannot be determined
    func version() async throws -> String

    /// Pulls an OCI image from a registry.
    ///
    /// Downloads the image layers and extracts the rootfs for container creation.
    /// Progress is reported via the runtime's logging system.
    ///
    /// - Parameter reference: OCI image reference (e.g., "docker.io/library/ubuntu:22.04")
    /// - Returns: The pulled container image with local rootfs path
    /// - Throws: `ContainerRuntimeError.imagePullFailed` if the pull fails
    func pullImage(reference: String) async throws -> ContainerImage

    /// Creates a container from an image.
    ///
    /// Allocates resources and prepares the container for execution but does not
    /// start it. The container will be in the `created` state.
    ///
    /// - Parameters:
    ///   - name: Unique name for the container
    ///   - image: The container image to use
    ///   - config: Container configuration including resource limits and mounts
    /// - Returns: The created container handle
    /// - Throws: `ContainerRuntimeError.containerCreationFailed` if creation fails
    func createContainer(
        name: String,
        image: ContainerImage,
        config: ContainerConfiguration
    ) async throws -> Container

    /// Starts a created container.
    ///
    /// Transitions the container from `created` to `running` state.
    /// For Apple Containerization, this boots the VM.
    /// For Docker, this starts the container process.
    ///
    /// - Parameter container: The container to start
    /// - Throws: `ContainerRuntimeError.containerStartFailed` if start fails
    func startContainer(_ container: Container) async throws

    /// Stops a running container.
    ///
    /// Gracefully stops the container, allowing processes to terminate cleanly.
    /// Uses a timeout before forcefully terminating.
    ///
    /// - Parameter container: The container to stop
    /// - Throws: `ContainerRuntimeError.containerStopFailed` if stop fails
    func stopContainer(_ container: Container) async throws

    /// Executes a process in a running container.
    ///
    /// Creates a new process inside the container but does not start it.
    /// Call `start()` on the returned `ContainerProcess` to begin execution.
    ///
    /// - Parameters:
    ///   - container: The running container
    ///   - command: The command to execute
    ///   - arguments: Command arguments
    ///   - environment: Environment variables to set
    ///   - workingDirectory: Working directory for the process
    /// - Returns: A `ContainerProcess` handle for managing the execution
    /// - Throws: `ContainerRuntimeError.execFailed` if process creation fails
    func exec(
        in container: Container,
        command: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String
    ) async throws -> ContainerProcess

    /// Removes a stopped container.
    ///
    /// Cleans up all resources associated with the container including
    /// filesystem layers and network configuration.
    ///
    /// - Parameter container: The container to remove
    /// - Throws: `ContainerRuntimeError.containerRemoveFailed` if removal fails
    func removeContainer(_ container: Container) async throws
}

// MARK: - Default Implementations

extension ContainerRuntimeProtocol {
    /// Default display name based on runtime type.
    public var displayName: String {
        runtimeType.displayName
    }
}

// MARK: - ContainerRuntimeError

/// Errors that can occur during container runtime operations.
public enum ContainerRuntimeError: Error, LocalizedError, Sendable {
    /// No container runtime is available on this system.
    case noRuntimeAvailable

    /// The specified runtime is not available.
    case runtimeNotAvailable(ContainerRuntimeType, reason: String)

    /// Failed to check runtime version.
    case versionCheckFailed(ContainerRuntimeType, underlying: Error?)

    /// Failed to pull a container image.
    case imagePullFailed(reference: String, reason: String)

    /// Failed to create a container.
    case containerCreationFailed(name: String, reason: String)

    /// Failed to start a container.
    case containerStartFailed(containerID: String, reason: String)

    /// Failed to stop a container.
    case containerStopFailed(containerID: String, reason: String)

    /// Failed to execute a process in a container.
    case execFailed(containerID: String, command: String, reason: String)

    /// Failed to remove a container.
    case containerRemoveFailed(containerID: String, reason: String)

    /// Container is in an invalid state for the requested operation.
    case invalidContainerState(containerID: String, expected: ContainerState, actual: ContainerState)

    /// Process execution timed out.
    case processTimeout(containerID: String, command: String, timeout: TimeInterval)

    /// The container was not found.
    case containerNotFound(containerID: String)

    /// The image was not found locally or in the registry.
    case imageNotFound(reference: String)

    public var errorDescription: String? {
        switch self {
        case .noRuntimeAvailable:
            return "No container runtime is available on this system"

        case .runtimeNotAvailable(let type, let reason):
            return "\(type.displayName) is not available: \(reason)"

        case .versionCheckFailed(let type, _):
            return "Failed to check \(type.displayName) version"

        case .imagePullFailed(let reference, let reason):
            return "Failed to pull image '\(reference)': \(reason)"

        case .containerCreationFailed(let name, let reason):
            return "Failed to create container '\(name)': \(reason)"

        case .containerStartFailed(let id, let reason):
            return "Failed to start container '\(id)': \(reason)"

        case .containerStopFailed(let id, let reason):
            return "Failed to stop container '\(id)': \(reason)"

        case .execFailed(let id, let command, let reason):
            return "Failed to execute '\(command)' in container '\(id)': \(reason)"

        case .containerRemoveFailed(let id, let reason):
            return "Failed to remove container '\(id)': \(reason)"

        case .invalidContainerState(let id, let expected, let actual):
            return "Container '\(id)' is in state '\(actual)' but expected '\(expected)'"

        case .processTimeout(let id, let command, let timeout):
            return "Process '\(command)' in container '\(id)' timed out after \(Int(timeout)) seconds"

        case .containerNotFound(let id):
            return "Container '\(id)' not found"

        case .imageNotFound(let reference):
            return "Image '\(reference)' not found"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .noRuntimeAvailable:
            return "Install Docker Desktop or upgrade to macOS 26 for Apple Containerization"

        case .runtimeNotAvailable(let type, _):
            switch type {
            case .appleContainerization:
                return "Ensure you are running macOS 26+ on Apple Silicon"
            case .docker:
                return "Install Docker Desktop and ensure the daemon is running"
            }

        case .versionCheckFailed:
            return "Check that the runtime is properly installed"

        case .imagePullFailed:
            return "Check your network connection and image reference"

        case .containerCreationFailed:
            return "Check system resources and container configuration"

        case .containerStartFailed:
            return "Check container logs for details"

        case .containerStopFailed:
            return "Try force-stopping the container"

        case .execFailed:
            return "Verify the command exists in the container"

        case .containerRemoveFailed:
            return "Ensure the container is stopped first"

        case .invalidContainerState:
            return "Wait for the container to reach the required state"

        case .processTimeout:
            return "Increase the timeout or optimize the process"

        case .containerNotFound:
            return "Verify the container ID is correct"

        case .imageNotFound:
            return "Check the image reference and pull the image first"
        }
    }
}
