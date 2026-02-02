// AppleContainerRuntime.swift - Apple Containerization framework implementation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Workflow Integration Lead (Role 14)
// Advisor: Apple Containerization Expert (Role 21)

import Foundation
import os.log

#if canImport(Containerization)
import Containerization
import ContainerizationOCI
#endif

// MARK: - AppleContainerRuntime

/// Apple Containerization framework implementation (PRIMARY runtime).
///
/// `AppleContainerRuntime` provides native Swift integration with Apple's
/// Containerization framework for running Linux containers on macOS 26+.
/// It offers significant advantages over Docker:
///
/// - **Native Swift APIs**: Direct async/await integration
/// - **VM-per-container isolation**: Each container runs in its own lightweight VM
/// - **Sub-second startup**: Optimized for fast container creation
/// - **Dedicated IP networking**: Each container gets its own IP via vmnet
/// - **No daemon required**: No Docker Desktop or background services
///
/// ## Requirements
///
/// - macOS 26.0+ (Tahoe)
/// - Apple Silicon (M1/M2/M3/M4)
/// - Swift 6.2+
///
/// ## Example Usage
///
/// ```swift
/// // Create the runtime
/// let runtime = try await AppleContainerRuntime()
///
/// // Pull an image
/// let image = try await runtime.pullImage(reference: "biocontainers/bwa:0.7.17")
///
/// // Create and run a container
/// let config = ContainerConfiguration(cpuCount: 4, memoryBytes: 8.gib())
/// let container = try await runtime.createContainer(
///     name: "bwa-alignment",
///     image: image,
///     config: config
/// )
/// try await runtime.startContainer(container)
///
/// // Execute a command
/// let process = try await runtime.exec(
///     in: container,
///     command: "bwa",
///     arguments: ["mem", "ref.fa", "reads.fq"],
///     environment: [:],
///     workingDirectory: "/workspace"
/// )
/// ```
@available(macOS 26, *)
public actor AppleContainerRuntime: ContainerRuntimeProtocol {
    // MARK: - Properties

    public let runtimeType: ContainerRuntimeType = .appleContainerization

    private let logger = Logger(
        subsystem: "com.lungfish.workflow",
        category: "AppleContainerRuntime"
    )

    #if canImport(Containerization)
    /// Virtual machine manager for container VMs.
    private let vmManager: VirtualMachineManager

    /// OCI image store for managing pulled images.
    private let imageStore: OCIImageStore
    #endif

    /// Active containers managed by this runtime.
    private var activeContainers: [String: Container] = [:]

    /// Cache of pulled images.
    private var imageCache: [String: ContainerImage] = [:]

    /// Path to the local image store.
    private let imageStorePath: URL

    // MARK: - Initialization

    /// Creates a new Apple Container runtime.
    ///
    /// - Parameter imageStorePath: Optional custom path for the image store.
    ///   Defaults to `~/Library/Caches/com.lungfish.containers`
    /// - Throws: `ContainerRuntimeError.runtimeNotAvailable` if initialization fails
    public init(imageStorePath: URL? = nil) async throws {
        // Verify platform requirements
        #if !arch(arm64)
        throw ContainerRuntimeError.runtimeNotAvailable(
            .appleContainerization,
            reason: "Apple Containerization requires Apple Silicon (arm64)"
        )
        #endif

        // Set up image store path
        let storePath = imageStorePath ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.lungfish.containers")

        self.imageStorePath = storePath

        // Create store directory
        try FileManager.default.createDirectory(
            at: storePath,
            withIntermediateDirectories: true
        )

        #if canImport(Containerization)
        // Initialize the virtual machine manager
        self.vmManager = try VirtualMachineManager()

        // Initialize the OCI image store
        self.imageStore = try OCIImageStore(path: storePath)

        logger.info("Apple Container runtime initialized at \(storePath.path)")
        #else
        logger.error("Containerization framework not available")
        throw ContainerRuntimeError.runtimeNotAvailable(
            .appleContainerization,
            reason: "Containerization framework not available in this build"
        )
        #endif
    }

    // MARK: - ContainerRuntimeProtocol

    public func isAvailable() async -> Bool {
        #if canImport(Containerization)
        // Apple Containerization is always available on macOS 26+ arm64
        // when the framework is imported
        return true
        #else
        return false
        #endif
    }

    public func version() async throws -> String {
        #if canImport(Containerization)
        // Return the Containerization framework version
        // The actual version comes from the framework bundle
        return "1.0.0"
        #else
        throw ContainerRuntimeError.runtimeNotAvailable(
            .appleContainerization,
            reason: "Containerization framework not available"
        )
        #endif
    }

    public func pullImage(reference: String) async throws -> ContainerImage {
        logger.info("Pulling image: \(reference, privacy: .public)")

        #if canImport(Containerization)
        // Check cache first
        if let cached = imageCache[reference] {
            logger.info("Image found in cache: \(reference, privacy: .public)")
            return cached
        }

        do {
            // Parse the image reference
            let imageRef = try OCIImageReference(reference)

            // Check local store
            if let existing = try? await imageStore.image(for: imageRef) {
                let image = ContainerImage(
                    id: existing.digest ?? UUID().uuidString,
                    reference: reference,
                    digest: existing.digest,
                    rootfsPath: existing.rootfsPath,
                    sizeBytes: existing.sizeBytes,
                    pulledAt: Date(),
                    architecture: "arm64",
                    os: "linux",
                    runtimeType: .appleContainerization
                )
                imageCache[reference] = image
                logger.info("Image found in local store: \(reference, privacy: .public)")
                return image
            }

            // Pull from registry
            logger.info("Pulling from registry: \(reference, privacy: .public)")

            let pullOptions = OCIPullOptions(
                platform: OCIPlatform(os: "linux", architecture: "arm64"),
                progressHandler: { [weak self] progress in
                    self?.logger.debug(
                        "Pull progress: \(progress.fractionCompleted * 100, format: .fixed(precision: 1))%"
                    )
                }
            )

            let pulledImage = try await imageStore.pull(imageRef, options: pullOptions)

            let image = ContainerImage(
                id: pulledImage.digest ?? UUID().uuidString,
                reference: reference,
                digest: pulledImage.digest,
                rootfsPath: pulledImage.rootfsPath,
                sizeBytes: pulledImage.sizeBytes,
                pulledAt: Date(),
                architecture: "arm64",
                os: "linux",
                runtimeType: .appleContainerization
            )

            imageCache[reference] = image
            logger.info("Image pulled successfully: \(reference, privacy: .public)")

            return image

        } catch {
            logger.error("Failed to pull image \(reference, privacy: .public): \(error.localizedDescription)")
            throw ContainerRuntimeError.imagePullFailed(
                reference: reference,
                reason: error.localizedDescription
            )
        }
        #else
        throw ContainerRuntimeError.runtimeNotAvailable(
            .appleContainerization,
            reason: "Containerization framework not available"
        )
        #endif
    }

    public func createContainer(
        name: String,
        image: ContainerImage,
        config: ContainerConfiguration
    ) async throws -> Container {
        logger.info("Creating container: \(name, privacy: .public)")

        #if canImport(Containerization)
        guard let rootfsPath = image.rootfsPath else {
            throw ContainerRuntimeError.containerCreationFailed(
                name: name,
                reason: "Image does not have a local rootfs path"
            )
        }

        do {
            // Create rootfs mount from extracted image
            let rootfsMount = try RootFSMount(path: rootfsPath)

            // Create the Linux container
            let linuxContainer = try LinuxContainer(
                name,
                rootfs: rootfsMount,
                vmm: vmManager
            ) { containerConfig in
                // Resource allocation
                if let cpuCount = config.cpuCount {
                    containerConfig.cpus = cpuCount
                } else {
                    containerConfig.cpus = ProcessInfo.processInfo.activeProcessorCount
                }

                if let memoryBytes = config.memoryBytes {
                    containerConfig.memoryInBytes = memoryBytes
                } else {
                    containerConfig.memoryInBytes = 8.gib()
                }

                // Hostname
                containerConfig.hostname = config.hostname ?? name

                // Network configuration
                switch config.networkMode {
                case .vmnetShared:
                    containerConfig.networking = .vmnet(mode: .shared)
                case .vmnetBridged:
                    containerConfig.networking = .vmnet(mode: .bridged)
                case .none:
                    containerConfig.networking = .none
                default:
                    // Default to shared vmnet for other modes
                    containerConfig.networking = .vmnet(mode: .shared)
                }

                // Mount bindings
                containerConfig.mounts = config.mounts.map { mount in
                    ContainerMount.bind(
                        source: mount.source,
                        destination: mount.destination,
                        readOnly: mount.readOnly
                    )
                }
            }

            // Create the container (provisions VM)
            try await linuxContainer.create()

            let containerID = UUID().uuidString

            let container = Container(
                id: containerID,
                name: name,
                runtimeType: .appleContainerization,
                state: .created,
                image: image,
                configuration: config,
                hostname: config.hostname ?? name,
                nativeContainer: AnySendable(linuxContainer)
            )

            activeContainers[containerID] = container

            logger.info("Container created: \(name, privacy: .public) [\(containerID.prefix(8))]")

            return container

        } catch {
            logger.error("Failed to create container \(name, privacy: .public): \(error.localizedDescription)")
            throw ContainerRuntimeError.containerCreationFailed(
                name: name,
                reason: error.localizedDescription
            )
        }
        #else
        throw ContainerRuntimeError.runtimeNotAvailable(
            .appleContainerization,
            reason: "Containerization framework not available"
        )
        #endif
    }

    public func startContainer(_ container: Container) async throws {
        logger.info("Starting container: \(container.name, privacy: .public)")

        #if canImport(Containerization)
        guard let linuxContainer = container.nativeContainerAs(LinuxContainer.self) else {
            throw ContainerRuntimeError.containerStartFailed(
                containerID: container.id,
                reason: "Invalid native container handle"
            )
        }

        do {
            try await linuxContainer.start()

            // Update container state
            if var updatedContainer = activeContainers[container.id] {
                try updatedContainer.updateState(.running)

                // Get IP address if available
                if let networkConfig = await linuxContainer.networkConfiguration,
                   let ipAddress = networkConfig.ipAddress {
                    updatedContainer.setIPAddress(ipAddress)
                }

                activeContainers[container.id] = updatedContainer
            }

            logger.info("Container started: \(container.name, privacy: .public)")

        } catch {
            logger.error("Failed to start container \(container.name, privacy: .public): \(error.localizedDescription)")
            throw ContainerRuntimeError.containerStartFailed(
                containerID: container.id,
                reason: error.localizedDescription
            )
        }
        #else
        throw ContainerRuntimeError.runtimeNotAvailable(
            .appleContainerization,
            reason: "Containerization framework not available"
        )
        #endif
    }

    public func stopContainer(_ container: Container) async throws {
        logger.info("Stopping container: \(container.name, privacy: .public)")

        #if canImport(Containerization)
        guard let linuxContainer = container.nativeContainerAs(LinuxContainer.self) else {
            throw ContainerRuntimeError.containerStopFailed(
                containerID: container.id,
                reason: "Invalid native container handle"
            )
        }

        do {
            // Update state to stopping
            if var updatedContainer = activeContainers[container.id] {
                try updatedContainer.updateState(.stopping)
                activeContainers[container.id] = updatedContainer
            }

            try await linuxContainer.stop()

            // Update state to stopped
            if var updatedContainer = activeContainers[container.id] {
                try updatedContainer.updateState(.stopped)
                activeContainers[container.id] = updatedContainer
            }

            logger.info("Container stopped: \(container.name, privacy: .public)")

        } catch {
            logger.error("Failed to stop container \(container.name, privacy: .public): \(error.localizedDescription)")
            throw ContainerRuntimeError.containerStopFailed(
                containerID: container.id,
                reason: error.localizedDescription
            )
        }
        #else
        throw ContainerRuntimeError.runtimeNotAvailable(
            .appleContainerization,
            reason: "Containerization framework not available"
        )
        #endif
    }

    public func exec(
        in container: Container,
        command: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String
    ) async throws -> ContainerProcess {
        logger.info("Exec in container \(container.name, privacy: .public): \(command, privacy: .public)")

        #if canImport(Containerization)
        guard let linuxContainer = container.nativeContainerAs(LinuxContainer.self) else {
            throw ContainerRuntimeError.execFailed(
                containerID: container.id,
                command: command,
                reason: "Invalid native container handle"
            )
        }

        guard container.state == .running else {
            throw ContainerRuntimeError.invalidContainerState(
                containerID: container.id,
                expected: .running,
                actual: container.state
            )
        }

        // Storage for native process reference
        var nativeProcess: ContainerExecProcess?

        let process = ContainerProcess(
            command: command,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            containerID: container.id,
            startHandler: { [weak self] in
                guard let self = self else { return }

                // Execute the command in the container
                let execProcess = try await linuxContainer.exec(command) { execConfig in
                    execConfig.arguments = arguments
                    execConfig.workingDirectory = workingDirectory

                    for (key, value) in environment {
                        execConfig.environment[key] = value
                    }

                    execConfig.attachStdin = false
                    execConfig.attachStdout = true
                    execConfig.attachStderr = true
                }

                nativeProcess = execProcess

                // Start output streaming
                Task {
                    for await data in execProcess.stdout {
                        await process.writeStdout(data)
                    }
                }

                Task {
                    for await data in execProcess.stderr {
                        await process.writeStderr(data)
                    }
                }

                try await execProcess.start()

                self.logger.debug("Process started: \(command, privacy: .public)")
            },
            waitHandler: {
                guard let execProcess = nativeProcess else {
                    return -1
                }
                return try await execProcess.wait()
            },
            signalHandler: { signal in
                guard let execProcess = nativeProcess else { return }
                try await execProcess.signal(signal)
            }
        )

        return process

        #else
        throw ContainerRuntimeError.runtimeNotAvailable(
            .appleContainerization,
            reason: "Containerization framework not available"
        )
        #endif
    }

    public func removeContainer(_ container: Container) async throws {
        logger.info("Removing container: \(container.name, privacy: .public)")

        guard container.state == .stopped || container.state == .created else {
            throw ContainerRuntimeError.invalidContainerState(
                containerID: container.id,
                expected: .stopped,
                actual: container.state
            )
        }

        // Remove from active containers
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

    /// Returns the image store path.
    public func getImageStorePath() -> URL {
        imageStorePath
    }

    /// Clears the image cache.
    public func clearImageCache() {
        imageCache.removeAll()
        logger.info("Image cache cleared")
    }
}

// MARK: - Placeholder Types for Non-macOS 26 Builds

#if !canImport(Containerization)
// These placeholder types allow the code to compile on macOS versions
// that don't have the Containerization framework.

/// Placeholder for VirtualMachineManager when Containerization is unavailable.
private struct VirtualMachineManager {}

/// Placeholder for OCIImageStore when Containerization is unavailable.
private struct OCIImageStore {
    init(path: URL) throws {
        fatalError("Containerization framework not available")
    }
}

/// Placeholder for OCIImageReference when Containerization is unavailable.
private struct OCIImageReference {
    init(_ reference: String) throws {
        fatalError("Containerization framework not available")
    }
}

/// Placeholder for OCIPullOptions when Containerization is unavailable.
private struct OCIPullOptions {
    init(platform: OCIPlatform, progressHandler: ((ImagePullProgress) -> Void)?) {}
}

/// Placeholder for OCIPlatform when Containerization is unavailable.
private struct OCIPlatform {
    let os: String
    let architecture: String
}

/// Placeholder for RootFSMount when Containerization is unavailable.
private struct RootFSMount {
    init(path: URL) throws {
        fatalError("Containerization framework not available")
    }
}

/// Placeholder for LinuxContainer when Containerization is unavailable.
private final class LinuxContainer: @unchecked Sendable {
    init(_ name: String, rootfs: RootFSMount, vmm: VirtualMachineManager, configure: (ContainerConfig) -> Void) throws {
        fatalError("Containerization framework not available")
    }

    func create() async throws {}
    func start() async throws {}
    func stop() async throws {}
    func exec(_ command: String, configure: (ExecConfig) -> Void) async throws -> ContainerExecProcess {
        fatalError("Containerization framework not available")
    }

    var networkConfiguration: NetworkConfiguration? { nil }
}

/// Placeholder for ContainerConfig when Containerization is unavailable.
private struct ContainerConfig {
    var cpus: Int = 0
    var memoryInBytes: UInt64 = 0
    var hostname: String = ""
    var networking: NetworkingConfig = .none
    var mounts: [ContainerMount] = []
}

/// Placeholder for NetworkingConfig when Containerization is unavailable.
private enum NetworkingConfig {
    case none
    case vmnet(mode: VmnetMode)
}

/// Placeholder for VmnetMode when Containerization is unavailable.
private enum VmnetMode {
    case shared
    case bridged
}

/// Placeholder for ContainerMount when Containerization is unavailable.
private enum ContainerMount {
    static func bind(source: String, destination: String, readOnly: Bool) -> ContainerMount {
        fatalError("Containerization framework not available")
    }
}

/// Placeholder for ExecConfig when Containerization is unavailable.
private struct ExecConfig {
    var arguments: [String] = []
    var workingDirectory: String = ""
    var environment: [String: String] = [:]
    var attachStdin: Bool = false
    var attachStdout: Bool = false
    var attachStderr: Bool = false
}

/// Placeholder for ContainerExecProcess when Containerization is unavailable.
private final class ContainerExecProcess: @unchecked Sendable {
    var stdout: AsyncStream<Data> { AsyncStream { _ in } }
    var stderr: AsyncStream<Data> { AsyncStream { _ in } }

    func start() async throws {}
    func wait() async throws -> Int32 { -1 }
    func signal(_ signal: Int32) async throws {}
}

/// Placeholder for NetworkConfiguration when Containerization is unavailable.
private struct NetworkConfiguration {
    var ipAddress: String? { nil }
}

/// Placeholder for pulled image when Containerization is unavailable.
private struct PulledOCIImage {
    var digest: String? { nil }
    var rootfsPath: URL { URL(fileURLWithPath: "/") }
    var sizeBytes: UInt64? { nil }
}

extension OCIImageStore {
    func image(for ref: OCIImageReference) async throws -> PulledOCIImage? { nil }
    func pull(_ ref: OCIImageReference, options: OCIPullOptions) async throws -> PulledOCIImage {
        fatalError("Containerization framework not available")
    }
}
#endif
