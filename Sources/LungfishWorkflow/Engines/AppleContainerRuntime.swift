// AppleContainerRuntime.swift - Apple Containerization framework implementation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Workflow Integration Lead (Role 14)
// Advisor: Apple Containerization Expert (Role 21)

import Foundation
import os.log
import LungfishCore
import Containerization
import ContainerizationOCI
import ContainerizationArchive
import ContainerizationExtras
import ContainerizationError
import ContainerizationEXT4

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
/// - Linux kernel binary for VM
///
/// ## Current Status
///
/// Container execution requires additional setup including:
/// - A Linux kernel binary (can be obtained from the containerization project)
/// - An initfs image (vminit)
///
/// Until full container support is configured, the bundle builder falls back to
/// basic file copying without format conversion.
@available(macOS 26, *)
public actor AppleContainerRuntime: ContainerRuntimeProtocol {
    // MARK: - Properties

    public let runtimeType: ContainerRuntimeType = .appleContainerization

    private let logger = Logger(
        subsystem: LogSubsystem.workflow,
        category: "AppleContainerRuntime"
    )

    /// Container manager that handles image pulling and container lifecycle.
    private var containerManager: ContainerManager?

    /// Active containers managed by this runtime.
    private var activeContainers: [String: Container] = [:]

    /// Active native containers indexed by container ID.
    private var nativeContainers: [String: LinuxContainer] = [:]

    /// Cache of pulled images with timestamps for expiry.
    private var imageCache: [String: CachedImage] = [:]

    /// Maximum age for cached images before they are considered stale (7 days).
    private static let imageCacheMaxAge: TimeInterval = 7 * 24 * 60 * 60

    /// Path to the local image store.
    private let imageStorePath: URL

    /// Path to the Linux kernel binary (required for containers).
    private let kernelPath: URL?

    // MARK: - Initialization

    /// Creates a new Apple Container runtime.
    ///
    /// - Parameters:
    ///   - imageStorePath: Optional custom path for the image store.
    ///     Defaults to `~/Library/Caches/com.lungfish.containers`
    ///   - kernelPath: Optional path to a Linux kernel binary.
    ///     If not provided, the runtime will look for a bundled kernel in Resources/Containerization.
    /// - Throws: `ContainerRuntimeError.runtimeNotAvailable` if initialization fails
    public init(imageStorePath: URL? = nil, kernelPath: URL? = nil) async throws {
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

        // Find kernel path - use provided path or look for bundled kernel
        let resolvedKernelPath = Self.resolveKernelPath(kernelPath)
        self.kernelPath = resolvedKernelPath

        // Debug: print kernel path resolution to stderr
        if let kp = resolvedKernelPath {
            logger.info("Resolved kernel path: \(kp.path)")
        } else {
            logger.warning("No kernel path resolved")
        }

        // Initialize container manager if kernel is available
        if let kernelPath = resolvedKernelPath,
           FileManager.default.fileExists(atPath: kernelPath.path) {
            do {
                let kernel = Kernel(
                    path: kernelPath,
                    platform: .linuxArm
                )

                // Load bundled initfs into image store if needed
                try await Self.loadBundledInitfs(storePath: storePath, logger: logger)

                // Use NAT networking which doesn't require com.apple.vm.networking entitlement
                // NAT uses VZNATNetworkDeviceAttachment which is available without special entitlements
                let natNetwork = NATNetwork()

                self.containerManager = try await ContainerManager(
                    kernel: kernel,
                    initfsReference: "vminit:latest",
                    root: storePath,
                    network: natNetwork,
                    rosetta: true  // Enable x86_64 emulation for biocontainers (amd64 only)
                )
                logger.info("Apple Container runtime initialized with kernel at \(kernelPath.path)")
            } catch {
                logger.error("Failed to initialize ContainerManager: \(error)")
                self.containerManager = nil
            }
        } else {
            self.containerManager = nil
            logger.info("Apple Container runtime initialized without kernel (limited functionality)")
        }

        logger.info("Apple Container runtime initialized at \(storePath.path)")
    }

    // MARK: - ContainerRuntimeProtocol

    public func isAvailable() async -> Bool {
        // Runtime is available if we have a properly initialized container manager
        return containerManager != nil
    }

    public func version() async throws -> String {
        return "0.24.5" // Apple Containerization package version
    }

    public func pullImage(reference: String) async throws -> ContainerImage {
        logger.info("Pulling image: \(reference, privacy: .public)")

        // Evict expired entries and check cache
        evictExpiredImages()
        if let cached = imageCache[reference] {
            logger.info("Image found in cache: \(reference, privacy: .public)")
            return cached.image
        }

        guard let manager = containerManager else {
            throw ContainerRuntimeError.runtimeNotAvailable(
                .appleContainerization,
                reason: "Container manager not initialized. A Linux kernel binary is required for container operations."
            )
        }

        do {
            // Pull the image using the image store
            let pulledImage = try await manager.imageStore.get(reference: reference, pull: true)

            // Detect actual platform of the pulled image
            let detectedPlatform = try await Self.detectImagePlatform(pulledImage)

            let image = ContainerImage(
                id: pulledImage.digest ?? UUID().uuidString,
                reference: reference,
                digest: pulledImage.digest,
                rootfsPath: nil, // Managed by ContainerManager
                sizeBytes: nil,
                pulledAt: Date(),
                architecture: detectedPlatform.architecture,
                os: detectedPlatform.os,
                runtimeType: .appleContainerization
            )

            imageCache[reference] = CachedImage(image: image, cachedAt: Date())
            logger.info("Image pulled successfully: \(reference, privacy: .public)")

            return image

        } catch {
            // Log detailed error information for debugging

            logger.error("Failed to pull image \(reference, privacy: .public): \(error)")
            throw ContainerRuntimeError.imagePullFailed(
                reference: reference,
                reason: "\(error)"
            )
        }
    }

    public func createContainer(
        name: String,
        image: ContainerImage,
        config: ContainerConfiguration
    ) async throws -> Container {
        logger.info("Creating container: \(name, privacy: .public)")

        guard var manager = containerManager else {
            throw ContainerRuntimeError.runtimeNotAvailable(
                .appleContainerization,
                reason: "Container manager not initialized. A Linux kernel binary is required for container operations."
            )
        }

        do {
            let containerID = UUID().uuidString

            // Compute rootfs size: base 4 GiB + proportional to memory allocation.
            let memoryBytes = config.memoryBytes ?? UInt64(8.gib())
            let rootfsSize = UInt64(4.gib()) + (memoryBytes / 2)

            // Determine the image platform. ContainerManager.create() hardcodes
            // Platform.current (arm64) for unpacking and config retrieval, which
            // fails for amd64-only images. Detect this and use a manual unpack
            // path with Rosetta x86_64 emulation when needed.
            let pulledImage = try await manager.imageStore.get(reference: image.reference, pull: true)
            let imagePlatform = try await Self.detectImagePlatform(pulledImage)

            let linuxContainer: LinuxContainer

            if imagePlatform.architecture == "amd64" {
                logger.info("Image is amd64 — using Rosetta unpack path")
                linuxContainer = try await createContainerForAmd64(
                    id: containerID,
                    image: pulledImage,
                    platform: imagePlatform,
                    rootfsSize: rootfsSize,
                    manager: &manager,
                    config: config,
                    name: name
                )
            } else {
                // Native arm64 image — use standard ContainerManager path
                linuxContainer = try await manager.create(
                    containerID,
                    image: pulledImage,
                    rootfsSizeInBytes: rootfsSize
                ) { containerConfig in
                    Self.applyContainerConfig(&containerConfig, from: config, name: name)
                }
            }

            // Store the native container
            nativeContainers[containerID] = linuxContainer

            let container = Container(
                id: containerID,
                name: name,
                runtimeType: .appleContainerization,
                state: .created,
                image: image,
                configuration: config,
                hostname: config.hostname ?? name,
                nativeContainer: AnySendable(containerID)
            )

            activeContainers[containerID] = container

            logger.info("Container created: \(name, privacy: .public) [\(containerID.prefix(8))]")

            return container

        } catch {
            logger.error("Failed to create container \(name, privacy: .public): \(error)")
            throw ContainerRuntimeError.containerCreationFailed(
                name: name,
                reason: "\(error)"
            )
        }
    }

    // MARK: - Amd64 Image Support (Rosetta)

    /// Detects the best platform for an image.
    /// Prefers .current (arm64) if available, falls back to amd64 for Rosetta.
    private static func detectImagePlatform(_ image: Containerization.Image) async throws -> Platform {
        do {
            let index = try await image.index()
            let platforms = index.manifests.compactMap(\.platform)

            // Prefer native arm64 if available
            if let native = platforms.first(where: { $0 == .current }) {
                return native
            }
            // Fall back to amd64 (will use Rosetta)
            if let amd64 = platforms.first(where: { $0.architecture == "amd64" }) {
                return amd64
            }
            // Return whatever is available
            if let first = platforms.first {
                return first
            }
        } catch {
            // Single-manifest images may not have an index
        }
        return .current
    }

    /// Creates a container for an amd64 image using manual unpack + Rosetta.
    ///
    /// ContainerManager.create() hardcodes Platform.current for both unpacking
    /// layers and reading the image config. For amd64 images on arm64, we must:
    /// 1. Unpack layers using the amd64 platform
    /// 2. Read the image config (entrypoint, env, workdir) using amd64 platform
    /// 3. Create LinuxContainer directly with our own VZVirtualMachineManager
    private func createContainerForAmd64(
        id: String,
        image: Containerization.Image,
        platform: Platform,
        rootfsSize: UInt64,
        manager: inout ContainerManager,
        config: ContainerConfiguration,
        name: String
    ) async throws -> LinuxContainer {
        // Create container root directory
        let containerRoot = manager.imageStore.path
            .appendingPathComponent("containers")
            .appendingPathComponent(id)
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)

        let rootfsPath = containerRoot.appendingPathComponent("rootfs.ext4")

        // Unpack image layers using the amd64 platform
        let unpacker = EXT4Unpacker(blockSizeInBytes: rootfsSize)
        let rootfs = try await unpacker.unpack(image, for: platform, at: rootfsPath)

        // Read image config from the amd64 manifest
        let ociImage = try await image.config(for: platform)
        let imageConfig = ociImage.config

        // Build the kernel and initfs for our own VZVirtualMachineManager.
        // We need rosetta enabled to run amd64 binaries.
        guard let kernelPath = self.kernelPath else {
            throw ContainerRuntimeError.runtimeNotAvailable(
                .appleContainerization,
                reason: "Kernel path required for amd64 container creation"
            )
        }

        let kernel = Kernel(path: kernelPath, platform: .linuxArm)

        // Reuse the initfs.ext4 that ContainerManager already unpacked during init
        let initfsPath = manager.imageStore.path.appendingPathComponent("initfs.ext4")
        let initfsMount = Mount.block(
            format: "ext4",
            source: initfsPath.absolutePath(),
            destination: "/",
            options: ["ro"]
        )

        let vmm = VZVirtualMachineManager(
            kernel: kernel,
            initialFilesystem: initfsMount,
            rosetta: true
        )

        // Build LinuxContainer configuration
        var containerConfig = LinuxContainer.Configuration()

        // Apply image config (entrypoint, cmd, env, workdir)
        if let imageConfig {
            containerConfig.process = .init(from: imageConfig)
        }

        // Capture stdout/stderr for diagnostics
        let logWriter = LogWriter(logger: logger, stream: "container")
        containerConfig.process.stdout = logWriter
        containerConfig.process.stderr = logWriter

        // Apply user-specified overrides
        Self.applyContainerConfig(&containerConfig, from: config, name: name)

        // Set up networking (NAT)
        var mutableNetwork = NATNetwork()
        if let interface = try mutableNetwork.create(id) {
            containerConfig.interfaces = [interface]
            if let gateway = interface.ipv4Gateway {
                containerConfig.dns = .init(nameservers: [gateway.description])
            }
        }

        containerConfig.bootLog = BootLog.file(
            path: containerRoot.appendingPathComponent("bootlog.log")
        )

        return try LinuxContainer(
            id,
            rootfs: rootfs,
            vmm: vmm,
            configuration: containerConfig
        )
    }

    /// Applies user ContainerConfiguration to a LinuxContainer.Configuration.
    private static func applyContainerConfig(
        _ containerConfig: inout LinuxContainer.Configuration,
        from config: ContainerConfiguration,
        name: String
    ) {
        if let cpuCount = config.cpuCount {
            containerConfig.cpus = cpuCount
        } else {
            containerConfig.cpus = ProcessInfo.processInfo.activeProcessorCount
        }

        // VZ requires memorySize to be a multiple of 1 MiB
        let mib: UInt64 = 1024 * 1024
        if let memoryBytes = config.memoryBytes {
            containerConfig.memoryInBytes = ((memoryBytes + mib - 1) / mib) * mib
        } else {
            containerConfig.memoryInBytes = 8.gib()
        }

        containerConfig.hostname = config.hostname ?? name

        if let command = config.command, !command.isEmpty {
            containerConfig.process.arguments = command
        }

        if let workingDir = config.workingDirectory {
            containerConfig.process.workingDirectory = workingDir
        }

        for (key, value) in config.environment {
            containerConfig.process.environmentVariables.append("\(key)=\(value)")
        }

        for mount in config.mounts {
            let czMount = Mount.share(
                source: mount.source,
                destination: mount.destination,
                options: mount.readOnly ? ["ro"] : []
            )
            containerConfig.mounts.append(czMount)
        }
    }

    public func startContainer(_ container: Container) async throws {
        logger.info("Starting container: \(container.name, privacy: .public)")

        guard let linuxContainer = nativeContainers[container.id] else {
            throw ContainerRuntimeError.containerStartFailed(
                containerID: container.id,
                reason: "Native container not found"
            )
        }

        do {
            try await linuxContainer.create()

            try await linuxContainer.start()

            // Update container state
            if var updatedContainer = activeContainers[container.id] {
                try updatedContainer.updateState(.running)
                activeContainers[container.id] = updatedContainer
            }

            logger.info("Container started: \(container.name, privacy: .public)")

        } catch {

            logger.error("Failed to start container \(container.name, privacy: .public): \(error)")
            throw ContainerRuntimeError.containerStartFailed(
                containerID: container.id,
                reason: "\(error)"
            )
        }
    }

    public func stopContainer(_ container: Container) async throws {
        logger.info("Stopping container: \(container.name, privacy: .public)")

        let currentState = activeContainers[container.id]?.state ?? container.state
        if currentState == .stopped {
            logger.debug("stopContainer: Container already stopped: \(container.name, privacy: .public)")
            return
        }
        if currentState == .created {
            // Created-but-never-started containers do not need a runtime stop call.
            if var updatedContainer = activeContainers[container.id] {
                try? updatedContainer.updateState(.stopped)
                activeContainers[container.id] = updatedContainer
            }
            return
        }

        guard let linuxContainer = nativeContainers[container.id] else {
            throw ContainerRuntimeError.containerStopFailed(
                containerID: container.id,
                reason: "Native container not found"
            )
        }

        do {
            // Update state to stopping
            if var updatedContainer = activeContainers[container.id] {
                try? updatedContainer.updateState(.stopping)
                activeContainers[container.id] = updatedContainer
            }

            try await linuxContainer.stop()

            // Update state to stopped
            if var updatedContainer = activeContainers[container.id] {
                try? updatedContainer.updateState(.stopped)
                activeContainers[container.id] = updatedContainer
            }

            logger.info("Container stopped: \(container.name, privacy: .public)")

        } catch {
            logger.error("Failed to stop container \(container.name, privacy: .public): \(error)")
            throw ContainerRuntimeError.containerStopFailed(
                containerID: container.id,
                reason: "\(error)"
            )
        }
    }

    /// Runs a container with a command and waits for it to complete.
    ///
    /// This is the preferred method for running commands in Apple Containerization,
    /// as it sets the command as the container's main process rather than using exec.
    ///
    /// - Parameters:
    ///   - container: The container to run (must have command set in config)
    /// - Returns: The exit code of the container process
    public func runAndWait(_ container: Container) async throws -> Int32 {
        logger.info("Running container: \(container.name, privacy: .public)")

        guard let linuxContainer = nativeContainers[container.id] else {
            throw ContainerRuntimeError.containerStartFailed(
                containerID: container.id,
                reason: "Native container not found"
            )
        }

        do {
            try await linuxContainer.create()
            try await linuxContainer.start()

            // Update container state
            if var updatedContainer = activeContainers[container.id] {
                try updatedContainer.updateState(.running)
                activeContainers[container.id] = updatedContainer
            }

            let exitStatus = try await linuxContainer.wait()
            let exitCode = exitStatus.exitCode

            // Update state to stopped
            if var updatedContainer = activeContainers[container.id] {
                try updatedContainer.updateState(.stopped)
                updatedContainer.setExitCode(exitCode)
                activeContainers[container.id] = updatedContainer
            }

            logger.info("Container \(container.name, privacy: .public) exited with code \(exitCode)")
            return exitCode

        } catch {
            // Clean up actor-local state on error so removeContainer can succeed
            if var updatedContainer = activeContainers[container.id] {
                try? updatedContainer.updateState(.stopped)
                activeContainers[container.id] = updatedContainer
            }
            logger.error("runAndWait failed for \(container.name, privacy: .public): \(error)")
            throw ContainerRuntimeError.containerStartFailed(
                containerID: container.id,
                reason: "\(error)"
            )
        }
    }

    public func exec(
        in container: Container,
        command: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String
    ) async throws -> ContainerProcess {
        logger.info("Exec in container \(container.name, privacy: .public): \(command, privacy: .public)")

        guard let linuxContainer = nativeContainers[container.id] else {
            throw ContainerRuntimeError.execFailed(
                containerID: container.id,
                command: command,
                reason: "Native container not found"
            )
        }

        let currentState = activeContainers[container.id]?.state ?? container.state
        guard currentState == .running else {
            throw ContainerRuntimeError.invalidContainerState(
                containerID: container.id,
                expected: .running,
                actual: currentState
            )
        }

        // Execute the command in the container synchronously
        let execID = UUID().uuidString
        let execProcess = try await linuxContainer.exec(execID) { execConfig in
            execConfig.arguments = [command] + arguments
            execConfig.workingDirectory = workingDirectory

            for (key, value) in environment {
                execConfig.environmentVariables.append("\(key)=\(value)")
            }
        }

        // Start the process
        try await execProcess.start()

        // Create a wrapper that holds the process reference
        let process = ContainerProcess(
            command: command,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            containerID: container.id,
            startHandler: {
                // Already started above
            },
            waitHandler: { [execProcess] in
                let status = try await execProcess.wait()
                return status.exitCode
            },
            signalHandler: { [execProcess] signal in
                try await execProcess.kill(signal)
            }
        )

        return process
    }

    public func removeContainer(_ container: Container) async throws {
        logger.info("Removing container: \(container.name, privacy: .public)")

        var currentState = activeContainers[container.id]?.state ?? container.state
        if currentState == .running || currentState == .stopping {
            try? await stopContainer(container)
            currentState = activeContainers[container.id]?.state ?? .stopped
        }

        guard currentState == .stopped || currentState == .created else {
            logger.debug("removeContainer: forcing removal from local state for container \(container.name, privacy: .public) in state \(String(describing: currentState), privacy: .public)")
            activeContainers.removeValue(forKey: container.id)
            nativeContainers.removeValue(forKey: container.id)
            return
        }

        // Remove from active containers
        activeContainers.removeValue(forKey: container.id)
        nativeContainers.removeValue(forKey: container.id)

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

    /// Checks if the runtime has a kernel configured for full container support.
    public func hasKernel() -> Bool {
        containerManager != nil
    }

    // MARK: - Image Cache Expiry

    /// A cached container image with a timestamp for expiry tracking.
    private struct CachedImage {
        let image: ContainerImage
        let cachedAt: Date
    }

    /// Removes expired entries from the image cache.
    private func evictExpiredImages() {
        let now = Date()
        let keysToRemove = imageCache.compactMap { (key, cached) -> String? in
            if now.timeIntervalSince(cached.cachedAt) > Self.imageCacheMaxAge {
                return key
            }
            return nil
        }
        for key in keysToRemove {
            imageCache.removeValue(forKey: key)
            logger.debug("Evicted expired image from cache: \(key)")
        }
    }

    // MARK: - Bundled Resource Helpers

    /// Resolves the kernel path, checking for bundled kernel if no path provided.
    private static func resolveKernelPath(_ providedPath: URL?) -> URL? {
        if let path = providedPath {
            return path
        }

        // Check SPM Bundle resources first (works for both debug and release builds)
        if let bundleKernel = Bundle.module.url(forResource: "vmlinux", withExtension: nil, subdirectory: "Containerization") {
            if FileManager.default.fileExists(atPath: bundleKernel.path) {
                return bundleKernel
            }
        }

        // SPM flat bundle structure - check directly in bundle path
        let bundlePath = Bundle.module.bundlePath
        let flatBundleKernel = URL(fileURLWithPath: bundlePath)
            .appendingPathComponent("Containerization")
            .appendingPathComponent("vmlinux")
        if FileManager.default.fileExists(atPath: flatBundleKernel.path) {
            return flatBundleKernel
        }

        // Look for bundled kernel in Resources/Containerization
        // Check relative to the executable
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let resourcesDir = executableURL
            .deletingLastPathComponent()
            .appendingPathComponent("LungfishGenomeBrowser_LungfishWorkflow.bundle")
            .appendingPathComponent("Containerization")

        let bundledKernel = resourcesDir.appendingPathComponent("vmlinux")
        if FileManager.default.fileExists(atPath: bundledKernel.path) {
            return bundledKernel
        }

        return nil
    }

    /// Loads the bundled initfs tarball into the image store if not already present.
    /// The tarball contains a raw rootfs filesystem, not an OCI image, so we use
    /// InitImage.create to convert it to an OCI image.
    private static func loadBundledInitfs(storePath: URL, logger: Logger) async throws {
        // Create content store first, then image store with the content store
        let contentStorePath = storePath.appendingPathComponent("content")
        try FileManager.default.createDirectory(at: contentStorePath, withIntermediateDirectories: true)
        let contentStore = try LocalContentStore(path: contentStorePath)
        let imageStore = try ImageStore(path: storePath, contentStore: contentStore)

        // Check if vminit:latest already exists in the image store
        do {
            _ = try await imageStore.get(reference: "vminit:latest")
            logger.debug("Initfs already loaded in image store")
            return
        } catch {
            // Image not found, need to create it
        }

        // Find the bundled initfs tarball
        // Check SPM Bundle resources first
        var initfsTarball: URL?

        if let bundleInitfs = Bundle.module.url(forResource: "init.rootfs.tar", withExtension: "gz", subdirectory: "Containerization") {
            if FileManager.default.fileExists(atPath: bundleInitfs.path) {
                initfsTarball = bundleInitfs
            }
        }

        // SPM flat bundle structure - check directly in bundle path
        if initfsTarball == nil {
            let bundlePath = Bundle.module.bundlePath
            let flatBundleInitfs = URL(fileURLWithPath: bundlePath)
                .appendingPathComponent("Containerization")
                .appendingPathComponent("init.rootfs.tar.gz")
            if FileManager.default.fileExists(atPath: flatBundleInitfs.path) {
                initfsTarball = flatBundleInitfs
            }
        }

        if initfsTarball == nil {
            let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            let resourcesDir = executableURL
                .deletingLastPathComponent()
                .appendingPathComponent("LungfishGenomeBrowser_LungfishWorkflow.bundle")
                .appendingPathComponent("Containerization")

            let execInitfs = resourcesDir.appendingPathComponent("init.rootfs.tar.gz")
            if FileManager.default.fileExists(atPath: execInitfs.path) {
                initfsTarball = execInitfs
            }
        }

        guard let initfsTarball = initfsTarball else {
            logger.warning("Bundled initfs not found in any search location")
            return
        }

        logger.info("Loading bundled initfs from \(initfsTarball.path)")

        // The tarball contains a raw rootfs filesystem (bin/, sbin/, etc.), not an OCI image.
        // Use InitImage.create to convert the rootfs tarball into an OCI image.
        do {
            let platform = Platform(arch: "arm64", os: "linux", variant: "v8")

            _ = try await InitImage.create(
                reference: "vminit:latest",
                rootfs: initfsTarball,
                platform: platform,
                labels: [
                    "org.opencontainers.image.title": "vminit",
                    "org.opencontainers.image.description": "Lungfish VM init image"
                ],
                imageStore: imageStore,
                contentStore: contentStore
            )

            logger.info("Successfully created initfs OCI image in store")
        } catch {
            logger.warning("Failed to create initfs image: \(error)")
            throw error
        }
    }
}

// MARK: - NAT Network Implementation

/// A network implementation using NAT that doesn't require the com.apple.vm.networking entitlement.
/// This uses VZNATNetworkDeviceAttachment which provides outbound internet access via NAT
/// without requiring special entitlements.
@available(macOS 26, *)
public struct NATNetwork: ContainerManager.Network, Sendable {
    /// The base subnet for NAT addresses (these are virtual addresses used inside the VM)
    private let subnet: CIDRv4

    /// Counter for allocating IP addresses
    private var nextAddress: UInt32

    /// Track allocated addresses by container ID
    private var allocations: [String: UInt32]

    /// Pool of released addresses available for reuse
    private var releasedAddresses: [UInt32] = []

    public init() {
        // Use a private subnet for NAT - the actual networking is handled by macOS
        // These addresses are used for configuring the network inside the VM
        // The gateway (192.168.64.1) is the host from the VM's perspective
        let baseAddress = try! IPv4Address("192.168.64.0")
        let prefix = Prefix.ipv4(24)!
        self.subnet = try! CIDRv4(baseAddress, prefix: prefix)
        self.nextAddress = 2  // Start at .2 (.1 is gateway)
        self.allocations = [:]
    }

    public mutating func create(_ id: String) throws -> Interface? {
        // Recycle a released address if available, otherwise allocate new
        let addressOffset: UInt32
        if !releasedAddresses.isEmpty {
            addressOffset = releasedAddresses.removeFirst()
        } else {
            // /24 subnet: .2 through .254 are usable (253 addresses)
            guard nextAddress <= 254 else {
                throw ContainerRuntimeError.runtimeNotAvailable(
                    .appleContainerization,
                    reason: "NAT network address pool exhausted (max 253 containers)"
                )
            }
            addressOffset = nextAddress
            nextAddress += 1
        }

        let addressValue = subnet.lower.value + addressOffset
        let address = IPv4Address(addressValue)
        let cidr = try CIDRv4(address, prefix: subnet.prefix)

        // Gateway is .1 in the subnet
        let gateway = IPv4Address(subnet.lower.value + 1)

        // Store allocation
        allocations[id] = addressOffset

        // Return a NATInterface which uses VZNATNetworkDeviceAttachment
        return NATInterface(
            ipv4Address: cidr,
            ipv4Gateway: gateway,
            macAddress: nil,
            mtu: 1500
        )
    }

    public mutating func release(_ id: String) throws {
        if let offset = allocations.removeValue(forKey: id) {
            releasedAddresses.append(offset)
        }
    }
}

// MARK: - Log Writer

/// A `Writer` that logs container stdout/stderr to the system logger.
@available(macOS 26, *)
final class LogWriter: Writer, Sendable {
    private let logger: Logger
    private let stream: String

    init(logger: Logger, stream: String) {
        self.logger = logger
        self.stream = stream
    }

    func write(_ data: Data) throws {
        if let text = String(data: data, encoding: .utf8) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                logger.info("[\(self.stream)] \(line, privacy: .public)")
            }
        }
    }

    func close() throws {}
}
