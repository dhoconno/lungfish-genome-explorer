// ContainerPluginManager.swift - Plugin execution manager using Apple Containerization
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

// MARK: - ContainerPluginManager

/// Manages execution of container tool plugins using Apple Containerization.
///
/// `ContainerPluginManager` is the central coordinator for running containerized
/// bioinformatics tools. It handles:
/// - Plugin registration and discovery
/// - Container image pulling with progress reporting
/// - Command execution with parameter substitution
/// - Output file collection and cleanup
///
/// ## Requirements
///
/// - macOS 26.0+ (Tahoe)
/// - Apple Silicon (M1/M2/M3/M4)
/// - No Docker fallback - uses Apple Containerization exclusively
///
/// ## Example Usage
///
/// ```swift
/// let manager = ContainerPluginManager.shared
///
/// // Prepare the plugin (pulls image if needed)
/// try await manager.preparePlugin("samtools") { progress, message in
///     print("[\(Int(progress * 100))%] \(message)")
/// }
///
/// // Execute a command
/// let result = try await manager.execute(
///     pluginId: "samtools",
///     command: "faidx",
///     parameters: ["INPUT": "/workspace/genome.fa"],
///     workspacePath: URL(fileURLWithPath: "/path/to/workspace")
/// )
///
/// if result.isSuccess {
///     print("Index created successfully")
/// }
/// ```
///
/// ## Thread Safety
///
/// `ContainerPluginManager` is an actor and all operations are thread-safe.
@available(macOS 26.0, *)
public actor ContainerPluginManager {

    // MARK: - Singleton

    /// Shared instance of the plugin manager.
    public static let shared = ContainerPluginManager()

    // MARK: - Properties

    private let logger = Logger(
        subsystem: "com.lungfish.workflow",
        category: "ContainerPluginManager"
    )

    /// Registered plugins by ID.
    private var registeredPlugins: [String: ContainerToolPlugin] = [:]

    /// Prepared plugins (images have been pulled).
    private var preparedPlugins: Set<String> = []

    /// The Apple Container runtime.
    private var runtime: AppleContainerRuntime?

    /// Active containers for plugin execution.
    private var activeContainers: [String: Container] = [:]

    /// Pulled images cache.
    private var pulledImages: [String: ContainerImage] = [:]

    // MARK: - Initialization

    private init() {
        // Register built-in plugins
        for plugin in BuiltInContainerPlugins.all {
            registeredPlugins[plugin.id] = plugin
        }
        let count = registeredPlugins.count
        logger.info("ContainerPluginManager initialized with \(count) built-in plugins")
    }

    // MARK: - Plugin Registration

    /// Registers a custom plugin.
    ///
    /// - Parameter plugin: The plugin to register
    /// - Throws: `ContainerPluginError.pluginAlreadyRegistered` if ID is taken
    public func registerPlugin(_ plugin: ContainerToolPlugin) throws {
        guard registeredPlugins[plugin.id] == nil else {
            throw ContainerPluginError.pluginAlreadyRegistered(plugin.id)
        }
        registeredPlugins[plugin.id] = plugin
        logger.info("Registered plugin: \(plugin.id)")
    }

    /// Returns a registered plugin by ID.
    ///
    /// - Parameter id: The plugin ID
    /// - Returns: The plugin, or nil if not found
    public func plugin(id: String) -> ContainerToolPlugin? {
        registeredPlugins[id]
    }

    /// Returns all registered plugins.
    public func allPlugins() -> [ContainerToolPlugin] {
        Array(registeredPlugins.values)
    }

    // MARK: - Plugin Preparation

    /// Prepares a plugin for execution by pulling its container image.
    ///
    /// This method ensures the container image is available locally before
    /// execution. Progress is reported via the callback.
    ///
    /// - Parameters:
    ///   - pluginId: The plugin ID to prepare
    ///   - progress: Callback for progress updates (0.0 to 1.0, status message)
    /// - Throws: `ContainerPluginError` if preparation fails
    public func preparePlugin(
        _ pluginId: String,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        guard let plugin = registeredPlugins[pluginId] else {
            throw ContainerPluginError.pluginNotFound(pluginId)
        }

        // Check if already prepared
        if preparedPlugins.contains(pluginId) {
            logger.debug("Plugin \(pluginId) already prepared")
            progress(1.0, "Ready")
            return
        }

        logger.info("Preparing plugin: \(pluginId)")
        progress(0.0, "Initializing container runtime...")

        // Initialize runtime if needed
        if runtime == nil {
            do {
                runtime = try await AppleContainerRuntime()
                logger.info("Apple Container runtime initialized")
            } catch {
                logger.error("Failed to initialize Apple Container runtime: \(error.localizedDescription)")
                throw ContainerPluginError.runtimeInitializationFailed(error.localizedDescription)
            }
        }

        guard let runtime = runtime else {
            throw ContainerPluginError.runtimeNotAvailable
        }

        // Check if image is already cached
        if let cached = pulledImages[plugin.imageReference] {
            logger.debug("Image already cached: \(plugin.imageReference)")
            preparedPlugins.insert(pluginId)
            progress(1.0, "Ready")
            return
        }

        // Pull the image
        progress(0.1, "Pulling container image...")
        logger.info("Pulling image: \(plugin.imageReference)")

        do {
            let image = try await runtime.pullImage(reference: plugin.imageReference)
            pulledImages[plugin.imageReference] = image
            preparedPlugins.insert(pluginId)
            progress(1.0, "Ready")
            logger.info("Plugin prepared: \(pluginId)")
        } catch {
            logger.error("Failed to pull image for \(pluginId): \(error.localizedDescription)")
            throw ContainerPluginError.imagePullFailed(plugin.imageReference, error.localizedDescription)
        }
    }

    /// Checks if a plugin is prepared for execution.
    public func isPluginPrepared(_ pluginId: String) -> Bool {
        preparedPlugins.contains(pluginId)
    }

    // MARK: - Command Execution

    /// Executes a command from a container tool plugin.
    ///
    /// - Parameters:
    ///   - pluginId: The plugin ID
    ///   - command: The command name (must be defined in the plugin)
    ///   - parameters: Parameter values for template substitution
    ///   - workspacePath: The workspace directory to mount
    /// - Returns: The execution result
    /// - Throws: `ContainerPluginError` if execution fails
    public func execute(
        pluginId: String,
        command: String,
        parameters: [String: String],
        workspacePath: URL
    ) async throws -> PluginExecutionResult {
        fputs("[DEBUG] PluginManager.execute: pluginId=\(pluginId), command=\(command)\n", stderr)
        fflush(stderr)

        guard let plugin = registeredPlugins[pluginId] else {
            fputs("[DEBUG] PluginManager.execute: plugin not found\n", stderr)
            throw ContainerPluginError.pluginNotFound(pluginId)
        }

        guard let commandTemplate = plugin.commands[command] else {
            fputs("[DEBUG] PluginManager.execute: command not found\n", stderr)
            throw ContainerPluginError.commandNotFound(pluginId, command)
        }

        guard let runtime = runtime else {
            fputs("[DEBUG] PluginManager.execute: runtime not available\n", stderr)
            throw ContainerPluginError.runtimeNotAvailable
        }

        guard let image = pulledImages[plugin.imageReference] else {
            fputs("[DEBUG] PluginManager.execute: plugin not prepared\n", stderr)
            throw ContainerPluginError.pluginNotPrepared(pluginId)
        }

        fputs("[DEBUG] PluginManager.execute: starting execution\n", stderr)
        fflush(stderr)
        logger.info("Executing \(pluginId):\(command)")

        let startTime = Date()

        // Resolve command arguments
        var resolvedParams = parameters

        // Add workspace path mapping
        for (key, value) in parameters {
            if value.hasPrefix(workspacePath.path) {
                resolvedParams[key] = value.replacingOccurrences(
                    of: workspacePath.path,
                    with: "/workspace"
                )
            }
        }

        let args = commandTemplate.resolve(with: resolvedParams)
        logger.debug("Running: \(args.joined(separator: " "))")
        fputs("[DEBUG] PluginManager: Resolved command: \(args.joined(separator: " "))\n", stderr)
        fflush(stderr)

        do {
            // Run setup commands if defined (each in their own container)
            if let setupCommands = plugin.setupCommands, !setupCommands.isEmpty {
                logger.info("Running setup commands for plugin: \(pluginId)")
                fputs("[DEBUG] PluginManager: Running \(setupCommands.count) setup commands\n", stderr)

                for (index, setupCmd) in setupCommands.enumerated() {
                    guard !setupCmd.isEmpty else { continue }

                    logger.debug("Setup[\(index)]: \(setupCmd.joined(separator: " "))")
                    fputs("[DEBUG] PluginManager: Setup[\(index)]: \(setupCmd.joined(separator: " "))\n", stderr)
                    fflush(stderr)

                    let setupConfig = ContainerConfiguration(
                        cpuCount: plugin.resources.cpuCount,
                        memoryBytes: plugin.resources.memoryGB.map { UInt64($0).gib() },
                        mounts: [
                            MountBinding(
                                source: workspacePath.path,
                                destination: "/workspace",
                                readOnly: false
                            )
                        ],
                        workingDirectory: "/workspace",
                        command: setupCmd
                    )

                    let setupContainerName = "\(pluginId)-setup-\(index)-\(UUID().uuidString.prefix(8))"
                    let setupContainer = try await runtime.createContainer(
                        name: setupContainerName,
                        image: image,
                        config: setupConfig
                    )

                    let setupExitCode = try await runtime.runAndWait(setupContainer)
                    try? await runtime.removeContainer(setupContainer)

                    fputs("[DEBUG] PluginManager: Setup[\(index)] exit code: \(setupExitCode)\n", stderr)
                    if setupExitCode != 0 {
                        logger.error("Setup command failed with exit code \(setupExitCode)")
                        throw ContainerPluginError.executionFailed(
                            pluginId,
                            "setup",
                            "Setup command failed with exit code \(setupExitCode): \(setupCmd.joined(separator: " "))"
                        )
                    }
                    logger.debug("Setup command completed successfully")
                    fputs("[DEBUG] PluginManager: Setup[\(index)] completed successfully\n", stderr)
                }
            } else {
                fputs("[DEBUG] PluginManager: No setup commands to run\n", stderr)
            }

            // Create container configuration for the main command
            let config = ContainerConfiguration(
                cpuCount: plugin.resources.cpuCount,
                memoryBytes: plugin.resources.memoryGB.map { UInt64($0).gib() },
                mounts: [
                    MountBinding(
                        source: workspacePath.path,
                        destination: "/workspace",
                        readOnly: false
                    )
                ],
                workingDirectory: commandTemplate.workingDirectory ?? "/workspace",
                environment: commandTemplate.environment,
                command: args
            )

            // Create a unique container name
            let containerName = "\(pluginId)-\(command)-\(UUID().uuidString.prefix(8))"

            fputs("[DEBUG] PluginManager: Creating main command container: \(containerName)\n", stderr)
            let container = try await runtime.createContainer(
                name: containerName,
                image: image,
                config: config
            )

            // Run the container and wait for completion
            fputs("[DEBUG] PluginManager: Running main command container...\n", stderr)
            let exitCode = try await runtime.runAndWait(container)

            // Remove container
            try? await runtime.removeContainer(container)

            let duration = Date().timeIntervalSince(startTime)

            // Find output files
            var outputFiles: [URL] = []
            if commandTemplate.producesOutput {
                // Check for common output patterns
                for output in plugin.outputs {
                    if let ext = output.fileExtension {
                        let outputParam = parameters["OUTPUT"] ?? parameters["INPUT"]
                        if let basePath = outputParam {
                            let outputPath = basePath + "." + ext
                            let outputURL = URL(fileURLWithPath: outputPath)
                            if FileManager.default.fileExists(atPath: outputURL.path) {
                                outputFiles.append(outputURL)
                            }
                        }
                    }
                }
            }

            logger.info("Execution completed: \(pluginId):\(command) exit=\(exitCode) duration=\(String(format: "%.2f", duration))s")
            fputs("[DEBUG] PluginManager: Main command exit code: \(exitCode)\n", stderr)

            return PluginExecutionResult(
                exitCode: exitCode,
                stdout: "", // Output not captured with runAndWait approach
                stderr: "",
                outputFiles: outputFiles,
                duration: duration
            )

        } catch {
            fputs("[DEBUG] PluginManager: Execution failed with error: \(error)\n", stderr)
            fputs("[DEBUG] PluginManager: error type: \(type(of: error))\n", stderr)
            fputs("[DEBUG] PluginManager: localizedDescription: \(error.localizedDescription)\n", stderr)
            logger.error("Execution failed: \(pluginId):\(command) - \(error.localizedDescription)")
            throw ContainerPluginError.executionFailed(pluginId, command, error.localizedDescription)
        }
    }

    // MARK: - Convenience Methods

    /// Executes a samtools faidx command to index a FASTA file.
    ///
    /// - Parameters:
    ///   - fastaPath: Path to the FASTA file
    ///   - workspacePath: Workspace directory containing the file
    /// - Returns: The execution result
    public func indexFASTA(
        fastaPath: URL,
        workspacePath: URL
    ) async throws -> PluginExecutionResult {
        if !isPluginPrepared("samtools") {
            try await preparePlugin("samtools") { _, _ in }
        }

        return try await execute(
            pluginId: "samtools",
            command: "faidx",
            parameters: ["INPUT": fastaPath.path],
            workspacePath: workspacePath
        )
    }

    /// Executes bcftools to convert VCF to indexed BCF.
    ///
    /// - Parameters:
    ///   - vcfPath: Path to the VCF file
    ///   - outputPath: Path for the output BCF file
    ///   - workspacePath: Workspace directory
    /// - Returns: The execution result
    public func convertVCFtoBCF(
        vcfPath: URL,
        outputPath: URL,
        workspacePath: URL
    ) async throws -> PluginExecutionResult {
        if !isPluginPrepared("bcftools") {
            try await preparePlugin("bcftools") { _, _ in }
        }

        // Convert to BCF
        let convertResult = try await execute(
            pluginId: "bcftools",
            command: "view",
            parameters: [
                "INPUT": vcfPath.path,
                "OUTPUT": outputPath.path
            ],
            workspacePath: workspacePath
        )

        guard convertResult.isSuccess else {
            return convertResult
        }

        // Create index
        return try await execute(
            pluginId: "bcftools",
            command: "index",
            parameters: ["INPUT": outputPath.path],
            workspacePath: workspacePath
        )
    }

    /// Executes bedToBigBed to convert BED to BigBed.
    ///
    /// - Parameters:
    ///   - bedPath: Path to the BED file
    ///   - chromSizesPath: Path to chromosome sizes file
    ///   - outputPath: Path for the output BigBed file
    ///   - workspacePath: Workspace directory
    /// - Returns: The execution result
    public func convertBEDtoBigBed(
        bedPath: URL,
        chromSizesPath: URL,
        outputPath: URL,
        workspacePath: URL
    ) async throws -> PluginExecutionResult {
        if !isPluginPrepared("bedToBigBed") {
            try await preparePlugin("bedToBigBed") { _, _ in }
        }

        return try await execute(
            pluginId: "bedToBigBed",
            command: "convert",
            parameters: [
                "INPUT": bedPath.path,
                "CHROM_SIZES": chromSizesPath.path,
                "OUTPUT": outputPath.path
            ],
            workspacePath: workspacePath
        )
    }

    /// Compresses a file with bgzip.
    ///
    /// - Parameters:
    ///   - inputPath: Path to the file to compress
    ///   - workspacePath: Workspace directory
    /// - Returns: The execution result
    public func bgzipCompress(
        inputPath: URL,
        workspacePath: URL
    ) async throws -> PluginExecutionResult {
        if !isPluginPrepared("bgzip") {
            try await preparePlugin("bgzip") { _, _ in }
        }

        return try await execute(
            pluginId: "bgzip",
            command: "compress",
            parameters: ["INPUT": inputPath.path],
            workspacePath: workspacePath
        )
    }

    // MARK: - Cleanup

    /// Removes cached image for a plugin.
    public func clearPluginCache(_ pluginId: String) {
        preparedPlugins.remove(pluginId)
        if let plugin = registeredPlugins[pluginId] {
            pulledImages.removeValue(forKey: plugin.imageReference)
        }
        logger.info("Cleared cache for plugin: \(pluginId)")
    }

    /// Clears all cached images.
    public func clearAllCaches() {
        preparedPlugins.removeAll()
        pulledImages.removeAll()
        logger.info("Cleared all plugin caches")
    }
}

// MARK: - ContainerPluginError

/// Errors that can occur during container plugin operations.
public enum ContainerPluginError: Error, LocalizedError, Sendable {
    /// Plugin not found in registry.
    case pluginNotFound(String)

    /// Plugin is already registered.
    case pluginAlreadyRegistered(String)

    /// Command not found in plugin.
    case commandNotFound(String, String)

    /// Plugin has not been prepared (image not pulled).
    case pluginNotPrepared(String)

    /// Container runtime is not available.
    case runtimeNotAvailable

    /// Failed to initialize the container runtime.
    case runtimeInitializationFailed(String)

    /// Failed to pull the container image.
    case imagePullFailed(String, String)

    /// Command execution failed.
    case executionFailed(String, String, String)

    /// Invalid parameter value.
    case invalidParameter(String, String)

    public var errorDescription: String? {
        switch self {
        case .pluginNotFound(let id):
            return "Plugin '\(id)' not found"
        case .pluginAlreadyRegistered(let id):
            return "Plugin '\(id)' is already registered"
        case .commandNotFound(let plugin, let command):
            return "Command '\(command)' not found in plugin '\(plugin)'"
        case .pluginNotPrepared(let id):
            return "Plugin '\(id)' has not been prepared - call preparePlugin first"
        case .runtimeNotAvailable:
            return "Apple Container runtime is not available"
        case .runtimeInitializationFailed(let reason):
            return "Failed to initialize container runtime: \(reason)"
        case .imagePullFailed(let image, let reason):
            return "Failed to pull image '\(image)': \(reason)"
        case .executionFailed(let plugin, let command, let reason):
            return "Execution of '\(plugin):\(command)' failed: \(reason)"
        case .invalidParameter(let name, let reason):
            return "Invalid parameter '\(name)': \(reason)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .pluginNotFound:
            return "Check the plugin ID or register the plugin first"
        case .pluginAlreadyRegistered:
            return "Use a different plugin ID"
        case .commandNotFound:
            return "Check available commands for this plugin"
        case .pluginNotPrepared:
            return "Call preparePlugin() before executing commands"
        case .runtimeNotAvailable:
            return "Ensure you are running macOS 26+ on Apple Silicon"
        case .runtimeInitializationFailed:
            return "Check system requirements and permissions"
        case .imagePullFailed:
            return "Check network connection and image reference"
        case .executionFailed:
            return "Check command parameters and input files"
        case .invalidParameter:
            return "Provide a valid value for the parameter"
        }
    }
}

// MARK: - Extension for UInt64 GiB conversion

private extension Optional where Wrapped == Int {
    func map<T>(_ transform: (Int) -> T) -> T? {
        switch self {
        case .some(let value):
            return transform(value)
        case .none:
            return nil
        }
    }
}

private extension UInt64 {
    func gib() -> UInt64 {
        self * 1024 * 1024 * 1024
    }
}
