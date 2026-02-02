// ContainerRuntime.swift - Legacy container runtime detection (DEPRECATED)
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Workflow Integration Lead (Role 14)
//
// DEPRECATION NOTICE:
// This file is deprecated and will be removed in a future release.
// Use ContainerRuntimeFactory and ContainerRuntimeProtocol instead.
//
// Migration Guide:
// - Replace `ContainerRuntime.detect()` with `ContainerRuntimeFactory.availableRuntimes()`
// - Replace `ContainerRuntime.detectPreferred()` with `ContainerRuntimeFactory.createRuntime()`
// - Use `AppleContainerRuntime` for native macOS 26+ support
// - Use `DockerRuntime` for Docker-based workflows
//
// Apptainer/Singularity support has been removed as these runtimes are
// designed for HPC environments and provide no value on desktop macOS.

import Foundation
import os.log

// MARK: - ContainerRuntime (DEPRECATED)

/// Represents an available container runtime on the system.
///
/// - Important: This type is deprecated. Use `ContainerRuntimeFactory.createRuntime()`
///   to obtain a `ContainerRuntimeProtocol` implementation instead.
///
/// ## Migration
///
/// ```swift
/// // Old (deprecated)
/// let runtime = await ContainerRuntime.detectPreferred()
/// let profileName = runtime?.nextflowProfile
///
/// // New
/// guard let runtime = await ContainerRuntimeFactory.createRuntime() else {
///     print("No container runtime available")
///     return
/// }
/// // Use runtime.pullImage(), runtime.createContainer(), etc.
/// ```
@available(*, deprecated, message: "Use ContainerRuntimeFactory.createRuntime() instead")
public struct ContainerRuntime: Sendable, Equatable, Identifiable {
    /// Unique identifier for this runtime instance
    public var id: String { type.rawValue }

    /// The type of container runtime
    public let type: RuntimeType

    /// Path to the runtime executable
    public let executablePath: String

    /// Version string of the runtime
    public let version: String

    /// Whether this runtime is running (for Docker daemon)
    public let isRunning: Bool

    /// Creates a ContainerRuntime instance.
    ///
    /// - Parameters:
    ///   - type: The runtime type
    ///   - executablePath: Path to the executable
    ///   - version: Version string
    ///   - isRunning: Whether the runtime is active
    public init(
        type: RuntimeType,
        executablePath: String,
        version: String,
        isRunning: Bool = true
    ) {
        self.type = type
        self.executablePath = executablePath
        self.version = version
        self.isRunning = isRunning
    }

    // MARK: - Static Detection

    private static let logger = Logger(
        subsystem: "com.lungfish.workflow",
        category: "ContainerRuntime"
    )

    /// Detects all available container runtimes on the system.
    ///
    /// - Important: This method is deprecated. Use `ContainerRuntimeFactory.availableRuntimes()` instead.
    ///
    /// - Returns: Array of available container runtimes
    @available(*, deprecated, message: "Use ContainerRuntimeFactory.availableRuntimes() instead")
    public static func detect() async -> [ContainerRuntime] {
        logger.info("Detecting available container runtimes (legacy)")

        // Only detect Docker now - Apptainer/Singularity removed
        let dockerRuntime = await detectDocker()

        let runtimes = [dockerRuntime].compactMap { $0 }

        logger.info("Found \(runtimes.count) container runtime(s)")

        return runtimes
    }

    /// Detects the preferred container runtime.
    ///
    /// - Important: This method is deprecated. Use `ContainerRuntimeFactory.createRuntime()` instead.
    ///
    /// - Returns: The preferred available runtime, or nil if none found
    @available(*, deprecated, message: "Use ContainerRuntimeFactory.createRuntime() instead")
    public static func detectPreferred() async -> ContainerRuntime? {
        let runtimes = await detect()

        // Prefer Docker if it's running
        if let docker = runtimes.first(where: { $0.type == .docker && $0.isRunning }) {
            return docker
        }

        return nil
    }

    // MARK: - Migration Support

    /// Migrates to the new runtime system.
    ///
    /// Use this method to transition from the legacy `ContainerRuntime` to the
    /// new `ContainerRuntimeProtocol`-based system.
    ///
    /// - Returns: A new runtime conforming to `ContainerRuntimeProtocol`, or `nil` if unavailable
    @available(*, deprecated, message: "Use NewContainerRuntimeFactory.createRuntime() directly")
    public func migrateToNewRuntime() async -> (any ContainerRuntimeProtocol)? {
        switch type {
        case .docker:
            return await NewContainerRuntimeFactory.createRuntime(preference: .docker)
        case .apptainer, .singularity:
            // Apptainer/Singularity no longer supported, fall back to automatic
            Self.logger.warning("Apptainer/Singularity support has been removed. Falling back to automatic selection.")
            return await NewContainerRuntimeFactory.createRuntime(preference: .automatic)
        }
    }

    // MARK: - Individual Runtime Detection

    private static func detectDocker() async -> ContainerRuntime? {
        logger.debug("Checking for Docker")

        guard let path = await findExecutable("docker") else {
            logger.debug("Docker not found in PATH")
            return nil
        }

        // Get version
        guard let versionOutput = await runCommand(path, arguments: ["--version"]) else {
            logger.warning("Docker found but version check failed")
            return nil
        }

        // Parse version from output like "Docker version 24.0.6, build ed223bc"
        let version = parseDockerVersion(versionOutput)

        // Check if daemon is running
        let isRunning = await runCommand(path, arguments: ["info"]) != nil

        if !isRunning {
            logger.info("Docker found but daemon is not running")
        }

        logger.info("Docker \(version) detected at \(path), running: \(isRunning)")

        return ContainerRuntime(
            type: .docker,
            executablePath: path,
            version: version,
            isRunning: isRunning
        )
    }

    // MARK: - Helper Methods

    private static func findExecutable(_ name: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]

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
            logger.debug("Failed to run which \(name): \(error.localizedDescription)")
        }

        return nil
    }

    private static func runCommand(_ path: String, arguments: [String]) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            logger.debug("Failed to run \(path) \(arguments.joined(separator: " ")): \(error.localizedDescription)")
        }

        return nil
    }

    private static func parseDockerVersion(_ output: String) -> String {
        // "Docker version 24.0.6, build ed223bc"
        if let match = output.range(of: #"Docker version ([\d.]+)"#, options: .regularExpression) {
            let versionRange = output.index(match.lowerBound, offsetBy: 15)..<output.index(match.upperBound, offsetBy: 0)
            var version = String(output[versionRange])
            // Remove trailing comma if present
            if version.hasSuffix(",") {
                version.removeLast()
            }
            return version
        }
        return "unknown"
    }

    // MARK: - Profile Names

    /// Returns the Nextflow profile name for this runtime.
    ///
    /// This is used with `-profile` when running Nextflow pipelines.
    public var nextflowProfile: String {
        switch type {
        case .docker:
            return "docker"
        case .apptainer, .singularity:
            return "singularity"
        }
    }

    /// Returns the Snakemake container flag for this runtime.
    ///
    /// This returns the flag name without the leading dashes.
    public var snakemakeFlag: String {
        switch type {
        case .docker:
            return "use-docker"
        case .apptainer:
            return "use-apptainer"
        case .singularity:
            return "use-singularity"
        }
    }

    /// Returns command-line arguments for Snakemake to use this runtime.
    public var snakemakeArguments: [String] {
        switch type {
        case .docker:
            return ["--use-docker"]
        case .apptainer:
            return ["--use-apptainer"]
        case .singularity:
            return ["--use-singularity"]
        }
    }
}

// MARK: - RuntimeType (DEPRECATED)

/// Types of container runtimes supported for workflow execution.
///
/// - Important: This type is deprecated. Use `ContainerRuntimeType` instead.
///
/// Note: Apptainer and Singularity are deprecated and will be removed.
/// These runtimes are designed for HPC environments and provide no value
/// on desktop macOS. Use Docker or Apple Containerization instead.
@available(*, deprecated, message: "Use ContainerRuntimeType instead")
public enum RuntimeType: String, Sendable, Codable {
    /// Docker container runtime
    case docker = "docker"

    /// Apptainer container runtime (formerly Singularity)
    ///
    /// - Warning: Deprecated. Apptainer support will be removed.
    case apptainer = "apptainer"

    /// Singularity container runtime
    ///
    /// - Warning: Deprecated. Singularity support will be removed.
    case singularity = "singularity"

    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .docker:
            return "Docker"
        case .apptainer:
            return "Apptainer (deprecated)"
        case .singularity:
            return "Singularity (deprecated)"
        }
    }

    /// SF Symbol icon name for this runtime type.
    public var iconName: String {
        switch self {
        case .docker:
            return "shippingbox"
        case .apptainer, .singularity:
            return "cube"
        }
    }

    /// Whether this runtime requires a daemon process.
    public var requiresDaemon: Bool {
        switch self {
        case .docker:
            return true
        case .apptainer, .singularity:
            return false
        }
    }

    /// Whether this runtime is suitable for HPC environments.
    ///
    /// Note: Lungfish is a desktop application and does not target HPC environments.
    public var isHPCCompatible: Bool {
        switch self {
        case .docker:
            return false
        case .apptainer, .singularity:
            return true
        }
    }

    /// Converts to the new `ContainerRuntimeType`.
    ///
    /// - Returns: The equivalent `ContainerRuntimeType`, or `nil` for deprecated types
    public func toNewType() -> ContainerRuntimeType? {
        switch self {
        case .docker:
            return .docker
        case .apptainer, .singularity:
            // No equivalent in new system
            return nil
        }
    }
}

// MARK: - Legacy ContainerRuntimeError

/// Errors related to container runtime operations.
///
/// - Important: This type is partially deprecated.
///   Use `ContainerRuntimeError` from `ContainerRuntimeProtocol.swift` for new code.
@available(*, deprecated, renamed: "ContainerRuntimeError")
public enum LegacyContainerRuntimeError: Error, LocalizedError, Sendable {
    case notFound(RuntimeType)
    case notRunning(RuntimeType)
    case versionTooOld(RuntimeType, required: String, found: String)
    case imagePullFailed(image: String, message: String)
    case containerStartFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let type):
            return "\(type.displayName) is not installed"
        case .notRunning(let type):
            return "\(type.displayName) is not running"
        case .versionTooOld(let type, let required, let found):
            return "\(type.displayName) version \(found) is too old (requires \(required)+)"
        case .imagePullFailed(let image, let message):
            return "Failed to pull container image '\(image)': \(message)"
        case .containerStartFailed(let message):
            return "Failed to start container: \(message)"
        }
    }
}
