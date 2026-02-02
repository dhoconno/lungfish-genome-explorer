// Container.swift - Container model
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Workflow Integration Lead (Role 14)
// Advisor: Apple Containerization Expert (Role 21)

import Foundation

// MARK: - Container

/// Represents a container instance managed by a container runtime.
///
/// `Container` provides a unified interface for container lifecycle management
/// across different runtimes (Apple Containerization and Docker). It tracks
/// the container's state, configuration, and provides access to runtime-specific
/// handles.
///
/// ## Lifecycle
///
/// Containers follow a defined lifecycle:
/// 1. `created` - Container is configured but not running
/// 2. `running` - Container is actively executing
/// 3. `paused` - Container execution is suspended (not all runtimes support this)
/// 4. `stopped` - Container has been stopped
/// 5. `removed` - Container has been deleted (terminal state)
///
/// ## Example Usage
///
/// ```swift
/// // Create and start a container
/// let container = try await runtime.createContainer(
///     name: "my-container",
///     image: image,
///     config: config
/// )
///
/// try await runtime.startContainer(container)
///
/// // Check state
/// print("Container state: \(container.state)")
/// print("Container IP: \(container.ipAddress ?? "none")")
///
/// // Execute a process
/// let process = try await runtime.exec(
///     in: container,
///     command: "echo",
///     arguments: ["Hello, World!"],
///     environment: [:],
///     workingDirectory: "/"
/// )
///
/// // Stop and remove
/// try await runtime.stopContainer(container)
/// try await runtime.removeContainer(container)
/// ```
public struct Container: Sendable, Identifiable {
    // MARK: - Properties

    /// Unique identifier for this container.
    ///
    /// For Docker, this is the container ID (short or full form).
    /// For Apple Containerization, this is a UUID.
    public let id: String

    /// Human-readable name for this container.
    public let name: String

    /// The container runtime managing this container.
    public let runtimeType: ContainerRuntimeType

    /// Current state of the container.
    public private(set) var state: ContainerState

    /// The image this container was created from.
    public let image: ContainerImage

    /// Configuration used to create this container.
    public let configuration: ContainerConfiguration

    /// When the container was created.
    public let createdAt: Date

    /// When the container was started (if running or stopped).
    public var startedAt: Date?

    /// When the container was stopped (if stopped).
    public var stoppedAt: Date?

    /// Exit code if the container has stopped.
    public var exitCode: Int32?

    /// IP address assigned to the container.
    ///
    /// For Apple Containerization, this is a dedicated IP via vmnet.
    /// For Docker, this is the container's IP on the bridge network.
    public var ipAddress: String?

    /// Hostname of the container.
    public var hostname: String

    /// Runtime-specific native container handle.
    ///
    /// This is type-erased to support different runtime implementations:
    /// - Apple Containerization: `LinuxContainer`
    /// - Docker: Container ID string
    ///
    /// Use `nativeContainerAs(_:)` to access the typed handle.
    public let nativeContainer: AnySendable

    // MARK: - Initialization

    /// Creates a new container.
    ///
    /// This is typically called by runtime implementations when creating containers.
    ///
    /// - Parameters:
    ///   - id: Unique container identifier
    ///   - name: Human-readable name
    ///   - runtimeType: The runtime managing this container
    ///   - state: Initial container state
    ///   - image: Source container image
    ///   - configuration: Container configuration
    ///   - createdAt: Creation timestamp
    ///   - hostname: Container hostname
    ///   - nativeContainer: Runtime-specific handle
    public init(
        id: String,
        name: String,
        runtimeType: ContainerRuntimeType,
        state: ContainerState = .created,
        image: ContainerImage,
        configuration: ContainerConfiguration,
        createdAt: Date = Date(),
        hostname: String? = nil,
        nativeContainer: AnySendable
    ) {
        self.id = id
        self.name = name
        self.runtimeType = runtimeType
        self.state = state
        self.image = image
        self.configuration = configuration
        self.createdAt = createdAt
        self.hostname = hostname ?? name
        self.nativeContainer = nativeContainer
    }

    // MARK: - State Management

    /// Updates the container state.
    ///
    /// This is called by runtime implementations to reflect state changes.
    ///
    /// - Parameter newState: The new container state
    /// - Throws: `ContainerRuntimeError.invalidContainerState` if transition is invalid
    public mutating func updateState(_ newState: ContainerState) throws {
        guard state.canTransition(to: newState) else {
            throw ContainerRuntimeError.invalidContainerState(
                containerID: id,
                expected: newState,
                actual: state
            )
        }

        let now = Date()

        switch newState {
        case .running:
            startedAt = now
        case .stopped:
            stoppedAt = now
        default:
            break
        }

        state = newState
    }

    /// Sets the container's IP address.
    ///
    /// Called by the runtime after networking is configured.
    ///
    /// - Parameter address: The IP address string
    public mutating func setIPAddress(_ address: String) {
        self.ipAddress = address
    }

    /// Sets the container's exit code.
    ///
    /// Called by the runtime when the container stops.
    ///
    /// - Parameter code: The exit code
    public mutating func setExitCode(_ code: Int32) {
        self.exitCode = code
    }

    // MARK: - Native Container Access

    /// Retrieves the native container handle as a specific type.
    ///
    /// - Parameter type: The expected type of the native container
    /// - Returns: The native container cast to the specified type, or `nil` if cast fails
    public func nativeContainerAs<T: Sendable>(_ type: T.Type) -> T? {
        nativeContainer.value as? T
    }

    // MARK: - Computed Properties

    /// Whether the container is currently running.
    public var isRunning: Bool {
        state == .running
    }

    /// Whether the container can be started.
    public var canStart: Bool {
        state == .created
    }

    /// Whether the container can be stopped.
    public var canStop: Bool {
        state == .running || state == .paused
    }

    /// Whether the container can be removed.
    public var canRemove: Bool {
        state == .stopped || state == .created
    }

    /// Duration the container has been running (or was running).
    public var runDuration: TimeInterval? {
        guard let start = startedAt else { return nil }
        let end = stoppedAt ?? Date()
        return end.timeIntervalSince(start)
    }

    /// Short form of the container ID.
    public var shortID: String {
        String(id.prefix(12))
    }
}

// MARK: - Container + Equatable

extension Container: Equatable {
    public static func == (lhs: Container, rhs: Container) -> Bool {
        lhs.id == rhs.id && lhs.runtimeType == rhs.runtimeType
    }
}

// MARK: - Container + Hashable

extension Container: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(runtimeType)
    }
}

// MARK: - Container + CustomStringConvertible

extension Container: CustomStringConvertible {
    public var description: String {
        "Container(\(name), id: \(shortID), state: \(state), runtime: \(runtimeType.displayName))"
    }
}

// MARK: - ContainerState

/// Represents the lifecycle state of a container.
public enum ContainerState: String, Sendable, Codable, CaseIterable {
    /// Container has been created but not started.
    case created = "created"

    /// Container is running.
    case running = "running"

    /// Container execution is paused.
    case paused = "paused"

    /// Container is in the process of stopping.
    case stopping = "stopping"

    /// Container has stopped.
    case stopped = "stopped"

    /// Container has been removed.
    case removed = "removed"

    /// Container is in an error state.
    case error = "error"

    /// Human-readable display name.
    public var displayName: String {
        rawValue.capitalized
    }

    /// SF Symbol icon name for this state.
    public var iconName: String {
        switch self {
        case .created:
            return "plus.circle"
        case .running:
            return "play.circle.fill"
        case .paused:
            return "pause.circle.fill"
        case .stopping:
            return "stop.circle"
        case .stopped:
            return "stop.circle.fill"
        case .removed:
            return "trash.circle"
        case .error:
            return "exclamationmark.circle.fill"
        }
    }

    /// Whether this state allows process execution.
    public var allowsExecution: Bool {
        self == .running
    }

    /// Checks if a transition to another state is valid.
    ///
    /// - Parameter target: The target state
    /// - Returns: `true` if the transition is allowed
    public func canTransition(to target: ContainerState) -> Bool {
        switch (self, target) {
        // From created
        case (.created, .running),
             (.created, .removed),
             (.created, .error):
            return true

        // From running
        case (.running, .paused),
             (.running, .stopping),
             (.running, .stopped),
             (.running, .error):
            return true

        // From paused
        case (.paused, .running),
             (.paused, .stopping),
             (.paused, .stopped):
            return true

        // From stopping
        case (.stopping, .stopped),
             (.stopping, .error):
            return true

        // From stopped
        case (.stopped, .removed),
             (.stopped, .running):  // Some runtimes allow restart
            return true

        // From error
        case (.error, .removed):
            return true

        // Same state is always valid (no-op)
        case let (from, to) where from == to:
            return true

        default:
            return false
        }
    }
}

// MARK: - AnySendable

/// Type-erased sendable wrapper for runtime-specific container handles.
///
/// This allows `Container` to hold runtime-specific objects while maintaining
/// `Sendable` conformance.
public struct AnySendable: @unchecked Sendable {
    /// The wrapped value.
    public let value: Any

    /// Creates a new `AnySendable` wrapper.
    ///
    /// - Parameter value: The value to wrap (must be Sendable at runtime)
    public init<T: Sendable>(_ value: T) {
        self.value = value
    }

    /// Creates an empty wrapper.
    public init() {
        self.value = ()
    }
}

// MARK: - ContainerStats

/// Runtime statistics for a container.
public struct ContainerStats: Sendable {
    /// CPU usage percentage (0.0 to 100.0).
    public let cpuUsagePercent: Double

    /// Memory usage in bytes.
    public let memoryUsageBytes: UInt64

    /// Memory limit in bytes.
    public let memoryLimitBytes: UInt64

    /// Network bytes received.
    public let networkRxBytes: UInt64

    /// Network bytes transmitted.
    public let networkTxBytes: UInt64

    /// Block I/O read bytes.
    public let blockReadBytes: UInt64

    /// Block I/O write bytes.
    public let blockWriteBytes: UInt64

    /// Timestamp of this measurement.
    public let timestamp: Date

    /// Memory usage as a fraction of limit.
    public var memoryUsageFraction: Double {
        guard memoryLimitBytes > 0 else { return 0.0 }
        return Double(memoryUsageBytes) / Double(memoryLimitBytes)
    }

    /// Memory usage percentage.
    public var memoryUsagePercent: Double {
        memoryUsageFraction * 100.0
    }

    /// Creates container stats.
    public init(
        cpuUsagePercent: Double,
        memoryUsageBytes: UInt64,
        memoryLimitBytes: UInt64,
        networkRxBytes: UInt64 = 0,
        networkTxBytes: UInt64 = 0,
        blockReadBytes: UInt64 = 0,
        blockWriteBytes: UInt64 = 0,
        timestamp: Date = Date()
    ) {
        self.cpuUsagePercent = cpuUsagePercent
        self.memoryUsageBytes = memoryUsageBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.networkRxBytes = networkRxBytes
        self.networkTxBytes = networkTxBytes
        self.blockReadBytes = blockReadBytes
        self.blockWriteBytes = blockWriteBytes
        self.timestamp = timestamp
    }
}
