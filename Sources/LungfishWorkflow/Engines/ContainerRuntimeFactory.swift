// ContainerRuntimeFactory.swift - Container runtime selection and creation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Workflow Integration Lead (Role 14)
// Advisor: Apple Containerization Expert (Role 21)

import Foundation
import os.log
import LungfishCore

// MARK: - NewContainerRuntimeFactory

/// Factory for selecting and creating container runtimes.
///
/// `NewContainerRuntimeFactory` provides automatic runtime selection with the
/// following priority:
///
/// 1. **Apple Containerization** (PRIMARY) - macOS 26+, Apple Silicon
///    - Native Swift APIs
///    - VM-per-container isolation
///    - Sub-second startup
///    - Dedicated IP networking
///
/// 2. **Docker** (FALLBACK) - Any macOS with Docker Desktop
///    - CLI-based implementation
///    - Broader compatibility
///    - Familiar tooling
///
/// ## Automatic Selection
///
/// By default, the factory automatically selects the best available runtime:
///
/// ```swift
/// // Automatic selection (recommended)
/// guard let runtime = await NewContainerRuntimeFactory.createRuntime() else {
///     print("No container runtime available")
///     return
/// }
///
/// print("Using: \(runtime.displayName)")
/// ```
///
/// ## Manual Selection
///
/// You can also explicitly request a specific runtime:
///
/// ```swift
/// // Force Apple Containerization (fails if unavailable)
/// let appleRuntime = await NewContainerRuntimeFactory.createRuntime(preference: .apple)
///
/// // Force Docker (fails if unavailable)
/// let dockerRuntime = await NewContainerRuntimeFactory.createRuntime(preference: .docker)
/// ```
///
/// ## Platform Detection
///
/// The factory provides methods to check runtime availability:
///
/// ```swift
/// // Check if Apple Containerization is available
/// if NewContainerRuntimeFactory.isAppleContainerizationAvailable() {
///     print("Native containers supported!")
/// }
///
/// // List all available runtimes
/// let runtimes = await NewContainerRuntimeFactory.availableRuntimes()
/// for runtime in runtimes {
///     let version = try? await runtime.version()
///     print("\(runtime.displayName): \(version ?? "unknown")")
/// }
/// ```
public enum NewContainerRuntimeFactory {
    // MARK: - Types

    /// User preference for container runtime selection.
    public enum Preference: String, Sendable, CaseIterable {
        /// Automatically select the best available runtime.
        ///
        /// Priority:
        /// 1. Apple Containerization (if available)
        /// 2. Docker (fallback)
        case automatic = "automatic"

        /// Force Apple Containerization.
        ///
        /// Returns `nil` if Apple Containerization is not available
        /// (pre-macOS 26, Intel Mac, or framework unavailable).
        case apple = "apple"

        /// Force Docker runtime.
        ///
        /// Returns `nil` if Docker is not installed or daemon is not running.
        case docker = "docker"

        /// Human-readable display name.
        public var displayName: String {
            switch self {
            case .automatic:
                return "Automatic"
            case .apple:
                return "Apple Containerization"
            case .docker:
                return "Docker"
            }
        }
    }

    // MARK: - Properties

    private static let logger = Logger(
        subsystem: LogSubsystem.workflow,
        category: "NewContainerRuntimeFactory"
    )

    // MARK: - Factory Methods

    /// Creates the best available container runtime.
    ///
    /// When `preference` is `.automatic`:
    /// 1. Tries Apple Containerization first (macOS 26+, Apple Silicon)
    /// 2. Falls back to Docker if Apple Containerization is unavailable
    ///
    /// - Parameter preference: User preference for runtime selection (default: `.automatic`)
    /// - Returns: A container runtime, or `nil` if none available
    public static func createRuntime(
        preference: Preference = .automatic
    ) async -> (any ContainerRuntimeProtocol)? {

        logger.info("Creating container runtime with preference: \(preference.rawValue)")

        switch preference {
        case .apple:
            if let runtime = await tryCreateAppleRuntime() {
                logger.info("Created Apple Containerization runtime (explicit preference)")
                return runtime
            }
            logger.warning("Apple Containerization requested but not available")
            return nil

        case .docker:
            if let runtime = await createDockerRuntime() {
                logger.info("Created Docker runtime (explicit preference)")
                return runtime
            }
            logger.warning("Docker requested but not available")
            return nil

        case .automatic:
            // Try Apple Containerization first (primary)
            if let appleRuntime = await tryCreateAppleRuntime() {
                logger.info("Using Apple Containerization runtime (primary)")
                return appleRuntime
            }

            // Fall back to Docker
            if let dockerRuntime = await createDockerRuntime() {
                logger.info("Using Docker runtime (fallback)")
                return dockerRuntime
            }

            logger.error("No container runtime available")
            return nil
        }
    }

    /// Creates a container runtime with detailed error information.
    ///
    /// This is the preferred method when you need to understand why no runtime
    /// is available and potentially display actionable information to the user.
    ///
    /// - Parameter preference: User preference for runtime selection (default: `.automatic`)
    /// - Returns: A `Result` containing either a runtime or a `ContainerRuntimeError`
    public static func createRuntimeWithError(
        preference: Preference = .automatic
    ) async -> Result<any ContainerRuntimeProtocol, ContainerRuntimeError> {

        logger.info("Creating container runtime with error handling, preference: \(preference.rawValue)")

        switch preference {
        case .apple:
            let (runtime, reason) = await tryCreateAppleRuntimeWithReason()
            if let runtime = runtime {
                logger.info("Created Apple Containerization runtime (explicit preference)")
                return .success(runtime)
            }
            return .failure(.runtimeNotAvailable(
                .appleContainerization,
                reason: reason ?? "Unknown reason"
            ))

        case .docker:
            let (runtime, reason) = await createDockerRuntimeWithReason()
            if let runtime = runtime {
                logger.info("Created Docker runtime (explicit preference)")
                return .success(runtime)
            }
            return .failure(.runtimeNotAvailable(
                .docker,
                reason: reason ?? "Unknown reason"
            ))

        case .automatic:
            var reasons: [String] = []

            // Try Apple Containerization first (primary)
            let (appleRuntime, appleReason) = await tryCreateAppleRuntimeWithReason()
            if let runtime = appleRuntime {
                logger.info("Using Apple Containerization runtime (primary)")
                return .success(runtime)
            }
            if let reason = appleReason {
                reasons.append("Apple Containerization: \(reason)")
            }

            // Fall back to Docker
            let (dockerRuntime, dockerReason) = await createDockerRuntimeWithReason()
            if let runtime = dockerRuntime {
                logger.info("Using Docker runtime (fallback)")
                return .success(runtime)
            }
            if let reason = dockerReason {
                reasons.append("Docker: \(reason)")
            }

            logger.error("No container runtime available")
            return .failure(.noRuntimeAvailable(reasons: reasons))
        }
    }

    /// Tries to create an Apple Containerization runtime if available.
    ///
    /// This method handles the availability check internally.
    ///
    /// - Returns: An `AppleContainerRuntime`, or `nil` if not available
    private static func tryCreateAppleRuntime() async -> (any ContainerRuntimeProtocol)? {
        guard isAppleContainerizationAvailable() else {
            logger.debug("Apple Containerization not available on this system")
            return nil
        }

        if #available(macOS 26, *) {
            do {
                let runtime = try await AppleContainerRuntime()
                if await runtime.isAvailable() {
                    return runtime
                }
                logger.debug("Apple Containerization runtime created but reports unavailable")
            } catch {
                logger.error("Failed to create Apple Containerization runtime: \(error.localizedDescription)")
            }
        }

        return nil
    }

    /// Creates a Docker runtime if available.
    ///
    /// - Returns: A `DockerRuntime`, or `nil` if not available
    public static func createDockerRuntime() async -> DockerRuntime? {
        let runtime = DockerRuntime()

        if await runtime.isAvailable() {
            return runtime
        }

        logger.debug("Docker runtime not available")
        return nil
    }

    /// Tries to create an Apple Containerization runtime with detailed reason on failure.
    ///
    /// - Returns: Tuple of (runtime if successful, reason for failure if unsuccessful)
    private static func tryCreateAppleRuntimeWithReason() async -> ((any ContainerRuntimeProtocol)?, String?) {
        // Check macOS version first
        guard #available(macOS 26, *) else {
            return (nil, "Requires macOS 26 or later")
        }

        // Check architecture
        #if !arch(arm64)
        return (nil, "Requires Apple Silicon (arm64)")
        #endif

        do {
            let runtime = try await AppleContainerRuntime()
            if await runtime.isAvailable() {
                return (runtime, nil)
            }
            return (nil, "Runtime created but reports unavailable (check container configuration)")
        } catch {
            return (nil, "Initialization failed: \(error.localizedDescription)")
        }
    }

    /// Creates a Docker runtime with detailed reason on failure.
    ///
    /// - Returns: Tuple of (runtime if successful, reason for failure if unsuccessful)
    private static func createDockerRuntimeWithReason() async -> (DockerRuntime?, String?) {
        // Check if docker CLI is available
        let dockerFound = await isDockerAvailable()
        guard dockerFound else {
            return (nil, "Docker CLI not found in PATH")
        }

        let runtime = DockerRuntime()
        if await runtime.isAvailable() {
            return (runtime, nil)
        }

        return (nil, "Docker daemon not running or not accessible")
    }

    // MARK: - Availability Checks

    /// Checks if Apple Containerization is available on this system.
    ///
    /// Requirements:
    /// - macOS 26.0+ (Tahoe)
    /// - Apple Silicon (arm64)
    ///
    /// - Returns: `true` if Apple Containerization can be used
    public static func isAppleContainerizationAvailable() -> Bool {
        // Check macOS version
        if #available(macOS 26, *) {
            // Check architecture
            #if arch(arm64)
            return true
            #else
            return false  // Intel Macs not supported
            #endif
        }

        return false
    }

    /// Checks if Docker is available on this system.
    ///
    /// This performs a quick check without fully initializing the runtime.
    ///
    /// - Returns: `true` if Docker CLI is found in PATH
    public static func isDockerAvailable() async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["docker"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Returns all available container runtimes on this system.
    ///
    /// - Returns: Array of available runtimes, ordered by preference (Apple first)
    public static func availableRuntimes() async -> [any ContainerRuntimeProtocol] {
        var runtimes: [any ContainerRuntimeProtocol] = []

        if let apple = await tryCreateAppleRuntime() {
            runtimes.append(apple)
        }

        if let docker = await createDockerRuntime() {
            runtimes.append(docker)
        }

        logger.info("Found \(runtimes.count) available runtime(s)")

        return runtimes
    }

    /// Returns detailed availability information for all supported runtimes.
    ///
    /// - Returns: Array of `RuntimeAvailability` for each runtime type
    public static func checkAvailability() async -> [RuntimeAvailability] {
        var results: [RuntimeAvailability] = []

        // Check Apple Containerization
        let appleAvailable: Bool
        var appleVersion: String?
        var appleReason: String?

        if #available(macOS 26, *) {
            #if arch(arm64)
            if let runtime = await tryCreateAppleRuntime() as? AppleContainerRuntime {
                appleAvailable = true
                appleVersion = try? await runtime.version()
                appleReason = nil
            } else {
                appleAvailable = false
                appleVersion = nil
                appleReason = "Framework initialization failed"
            }
            #else
            appleAvailable = false
            appleVersion = nil
            appleReason = "Requires Apple Silicon (arm64)"
            #endif
        } else {
            appleAvailable = false
            appleVersion = nil
            appleReason = "Requires macOS 26 or later"
        }

        results.append(RuntimeAvailability(
            runtimeType: .appleContainerization,
            isAvailable: appleAvailable,
            version: appleVersion,
            unavailableReason: appleReason
        ))

        // Check Docker
        let dockerRuntime = DockerRuntime()
        let dockerAvailable = await dockerRuntime.isAvailable()
        let dockerVersion = dockerAvailable ? (try? await dockerRuntime.version()) : nil
        let dockerReason = dockerAvailable ? nil : "Docker not installed or daemon not running"

        results.append(RuntimeAvailability(
            runtimeType: .docker,
            isAvailable: dockerAvailable,
            version: dockerVersion,
            unavailableReason: dockerReason
        ))

        return results
    }

    // MARK: - Utility Methods

    /// Returns the recommended runtime preference for the current system.
    ///
    /// - Returns: `.apple` on macOS 26+ Apple Silicon, `.docker` otherwise
    public static func recommendedPreference() -> Preference {
        if isAppleContainerizationAvailable() {
            return .apple
        }
        return .docker
    }

    /// Returns a human-readable description of the current container environment.
    ///
    /// - Returns: Description string suitable for display
    public static func environmentDescription() async -> String {
        let availability = await checkAvailability()

        var lines: [String] = ["Container Runtime Environment:"]

        for runtime in availability {
            var line = "  - \(runtime.runtimeType.displayName): "
            if runtime.isAvailable {
                line += "Available"
                if let version = runtime.version {
                    line += " (v\(version))"
                }
            } else {
                line += "Unavailable"
                if let reason = runtime.unavailableReason {
                    line += " - \(reason)"
                }
            }
            lines.append(line)
        }

        let recommended = recommendedPreference()
        lines.append("  Recommended: \(recommended.displayName)")

        return lines.joined(separator: "\n")
    }
}

// MARK: - RuntimeAvailability

/// Availability information for a container runtime.
public struct RuntimeAvailability: Sendable {
    /// The runtime type.
    public let runtimeType: ContainerRuntimeType

    /// Whether the runtime is available.
    public let isAvailable: Bool

    /// Runtime version if available.
    public let version: String?

    /// Reason why the runtime is unavailable.
    public let unavailableReason: String?

    /// Creates runtime availability info.
    public init(
        runtimeType: ContainerRuntimeType,
        isAvailable: Bool,
        version: String?,
        unavailableReason: String?
    ) {
        self.runtimeType = runtimeType
        self.isAvailable = isAvailable
        self.version = version
        self.unavailableReason = unavailableReason
    }
}

// MARK: - RuntimeAvailability + CustomStringConvertible

extension RuntimeAvailability: CustomStringConvertible {
    public var description: String {
        if isAvailable {
            if let version = version {
                return "\(runtimeType.displayName) v\(version) (available)"
            }
            return "\(runtimeType.displayName) (available)"
        } else {
            if let reason = unavailableReason {
                return "\(runtimeType.displayName) (unavailable: \(reason))"
            }
            return "\(runtimeType.displayName) (unavailable)"
        }
    }
}
