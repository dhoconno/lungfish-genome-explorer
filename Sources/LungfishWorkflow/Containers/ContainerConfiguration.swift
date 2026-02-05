// ContainerConfiguration.swift - Unified container configuration model
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Workflow Integration Lead (Role 14)
// Advisor: Apple Containerization Expert (Role 21)

import Foundation

// MARK: - ContainerConfiguration

/// Configuration for creating a container.
///
/// `ContainerConfiguration` provides a unified interface for configuring containers
/// across different runtimes (Apple Containerization and Docker). The configuration
/// includes resource limits, mount bindings, environment variables, and network settings.
///
/// ## Resource Allocation
///
/// CPU and memory limits can be specified to control resource usage:
///
/// ```swift
/// let config = ContainerConfiguration(
///     cpuCount: 4,
///     memoryBytes: 8.gib(),
///     mounts: [
///         MountBinding(source: "/data", destination: "/workspace/data")
///     ]
/// )
/// ```
///
/// ## Environment Variables
///
/// Environment variables are passed to all processes in the container:
///
/// ```swift
/// var config = ContainerConfiguration()
/// config.environment = [
///     "NXF_HOME": "/workspace/.nextflow",
///     "PATH": "/usr/local/bin:/usr/bin"
/// ]
/// ```
///
/// ## Thread Safety
///
/// `ContainerConfiguration` is `Sendable` and can be safely passed across
/// actor boundaries.
public struct ContainerConfiguration: Sendable, Codable, Equatable {
    // MARK: - Resource Limits

    /// Number of CPU cores to allocate.
    ///
    /// If `nil`, the container uses the system default (typically all available cores
    /// for Apple Containerization, or Docker's default limit).
    public var cpuCount: Int?

    /// Memory limit in bytes.
    ///
    /// If `nil`, the container uses the system default. Use the `.gib()` and `.mib()`
    /// extensions on integers for convenience.
    public var memoryBytes: UInt64?

    // MARK: - Filesystem Configuration

    /// Mount bindings for mapping host paths into the container.
    public var mounts: [MountBinding]

    /// Hostname for the container.
    ///
    /// If `nil`, the runtime generates a default hostname based on the container name.
    public var hostname: String?

    /// Working directory inside the container.
    ///
    /// This is the initial working directory for executed processes.
    public var workingDirectory: String?

    // MARK: - Environment

    /// Environment variables to set in the container.
    ///
    /// These are passed to all processes executed in the container.
    public var environment: [String: String]

    // MARK: - Network Configuration

    /// Network mode for the container.
    public var networkMode: NetworkMode

    /// Port mappings (only applicable for Docker runtime).
    ///
    /// Apple Containerization uses dedicated IPs, so port mappings are not needed.
    public var portMappings: [PortMapping]

    // MARK: - Process Configuration

    /// Command and arguments to run in the container.
    ///
    /// If set, this command will be executed as the main process when the container starts.
    /// The first element is the executable path, followed by arguments.
    public var command: [String]?

    // MARK: - Runtime-Specific Options

    /// Additional Docker-specific options.
    ///
    /// These are passed directly to the `docker run` command as extra arguments.
    public var dockerOptions: [String]

    /// User ID to run processes as inside the container.
    ///
    /// If `nil`, processes run as root (or the image's default user).
    public var userID: UInt32?

    /// Group ID to run processes as inside the container.
    public var groupID: UInt32?

    // MARK: - Initialization

    /// Creates a new container configuration with the specified options.
    ///
    /// - Parameters:
    ///   - cpuCount: Number of CPU cores to allocate
    ///   - memoryBytes: Memory limit in bytes
    ///   - mounts: Mount bindings for host paths
    ///   - hostname: Container hostname
    ///   - workingDirectory: Initial working directory
    ///   - environment: Environment variables
    ///   - networkMode: Network configuration mode
    ///   - portMappings: Port mappings (Docker only)
    ///   - command: Command and arguments to run
    ///   - dockerOptions: Additional Docker options
    ///   - userID: User ID for processes
    ///   - groupID: Group ID for processes
    public init(
        cpuCount: Int? = nil,
        memoryBytes: UInt64? = nil,
        mounts: [MountBinding] = [],
        hostname: String? = nil,
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        networkMode: NetworkMode = .bridge,
        portMappings: [PortMapping] = [],
        command: [String]? = nil,
        dockerOptions: [String] = [],
        userID: UInt32? = nil,
        groupID: UInt32? = nil
    ) {
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.mounts = mounts
        self.hostname = hostname
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.networkMode = networkMode
        self.portMappings = portMappings
        self.command = command
        self.dockerOptions = dockerOptions
        self.userID = userID
        self.groupID = groupID
    }

    // MARK: - Factory Methods

    /// Creates a default configuration suitable for bioinformatics workloads.
    ///
    /// Allocates reasonable resources for typical bioinformatics tools:
    /// - CPU: All available cores
    /// - Memory: 8 GiB
    /// - Network: Bridge mode
    ///
    /// - Parameter workspacePath: Host path to mount as `/workspace`
    /// - Returns: A configured `ContainerConfiguration`
    public static func bioinformaticsDefault(workspacePath: URL) -> ContainerConfiguration {
        ContainerConfiguration(
            cpuCount: ProcessInfo.processInfo.activeProcessorCount,
            memoryBytes: 8.gib(),
            mounts: [
                MountBinding(
                    source: workspacePath.path,
                    destination: "/workspace",
                    readOnly: false
                )
            ],
            workingDirectory: "/workspace",
            environment: [
                "LC_ALL": "C.UTF-8",
                "LANG": "C.UTF-8"
            ],
            networkMode: .bridge
        )
    }

    /// Creates a minimal configuration for quick operations.
    ///
    /// Uses minimal resources suitable for version checks, quick commands, etc:
    /// - CPU: 1 core
    /// - Memory: 1 GiB
    ///
    /// - Returns: A minimal `ContainerConfiguration`
    public static func minimal() -> ContainerConfiguration {
        ContainerConfiguration(
            cpuCount: 1,
            memoryBytes: 1.gib()
        )
    }
}

// MARK: - MountBinding

/// Represents a bind mount from host filesystem into a container.
///
/// Mount bindings allow host directories to be accessible inside containers.
/// This is essential for workflow execution where input/output files reside
/// on the host filesystem.
///
/// ## Example
///
/// ```swift
/// // Mount host data directory as read-only
/// let dataMount = MountBinding(
///     source: "/Users/researcher/data",
///     destination: "/data",
///     readOnly: true
/// )
///
/// // Mount output directory as read-write
/// let outputMount = MountBinding(
///     source: "/Users/researcher/results",
///     destination: "/output",
///     readOnly: false
/// )
/// ```
public struct MountBinding: Sendable, Codable, Equatable, Identifiable {
    /// Unique identifier for this mount binding.
    public var id: String { "\(source):\(destination)" }

    /// Path on the host filesystem.
    public let source: String

    /// Path inside the container.
    public let destination: String

    /// Whether the mount is read-only.
    ///
    /// Read-only mounts provide better security for input data.
    public let readOnly: Bool

    /// Propagation mode for the mount.
    public let propagation: MountPropagation

    /// Creates a new mount binding.
    ///
    /// - Parameters:
    ///   - source: Host filesystem path
    ///   - destination: Container filesystem path
    ///   - readOnly: Whether mount is read-only (default: false)
    ///   - propagation: Mount propagation mode (default: .private)
    public init(
        source: String,
        destination: String,
        readOnly: Bool = false,
        propagation: MountPropagation = .private
    ) {
        self.source = source
        self.destination = destination
        self.readOnly = readOnly
        self.propagation = propagation
    }

    /// Creates a mount binding from URLs.
    ///
    /// - Parameters:
    ///   - source: Host filesystem URL
    ///   - destination: Container filesystem path
    ///   - readOnly: Whether mount is read-only
    public init(source: URL, destination: String, readOnly: Bool = false) {
        self.init(source: source.path, destination: destination, readOnly: readOnly)
    }

    /// Returns the mount specification string for Docker.
    ///
    /// Format: `source:destination[:ro]`
    public var dockerMountSpec: String {
        var spec = "\(source):\(destination)"
        if readOnly {
            spec += ":ro"
        }
        return spec
    }
}

// MARK: - MountPropagation

/// Mount propagation modes for bind mounts.
public enum MountPropagation: String, Sendable, Codable {
    /// Mount events are private to this mount namespace.
    case `private` = "private"

    /// Mount events propagate into this mount.
    case slave = "slave"

    /// Mount events propagate bidirectionally.
    case shared = "shared"

    /// Recursive private propagation.
    case rprivate = "rprivate"

    /// Recursive slave propagation.
    case rslave = "rslave"

    /// Recursive shared propagation.
    case rshared = "rshared"
}

// MARK: - NetworkMode

/// Network configuration modes for containers.
public enum NetworkMode: String, Sendable, Codable {
    /// Bridge networking (default for Docker).
    ///
    /// Container gets its own network namespace with NAT.
    case bridge = "bridge"

    /// Host networking.
    ///
    /// Container shares the host's network namespace.
    /// Not recommended for security reasons.
    case host = "host"

    /// No networking.
    ///
    /// Container has no network access.
    case none = "none"

    /// Apple vmnet shared networking.
    ///
    /// Container gets a dedicated IP address via vmnet.
    /// Only available with Apple Containerization.
    case vmnetShared = "vmnet_shared"

    /// Apple vmnet bridged networking.
    ///
    /// Container is bridged to host network.
    /// Only available with Apple Containerization.
    case vmnetBridged = "vmnet_bridged"

    /// Returns the Docker network flag value.
    public var dockerNetworkFlag: String {
        switch self {
        case .bridge:
            return "bridge"
        case .host:
            return "host"
        case .none:
            return "none"
        case .vmnetShared, .vmnetBridged:
            // vmnet modes are Apple-specific, fall back to bridge for Docker
            return "bridge"
        }
    }
}

// MARK: - PortMapping

/// Maps a container port to a host port.
///
/// Port mappings are primarily used with Docker to expose container services
/// on the host network. Apple Containerization uses dedicated IPs, making
/// port mappings unnecessary.
public struct PortMapping: Sendable, Codable, Equatable, Identifiable {
    /// Unique identifier for this port mapping.
    public var id: String { "\(hostPort):\(containerPort)" }

    /// Port on the host.
    public let hostPort: UInt16

    /// Port inside the container.
    public let containerPort: UInt16

    /// Protocol (tcp or udp).
    public let `protocol`: PortProtocol

    /// Host IP to bind to.
    ///
    /// If `nil`, binds to all interfaces (0.0.0.0).
    public let hostIP: String?

    /// Creates a new port mapping.
    ///
    /// - Parameters:
    ///   - hostPort: Port on the host
    ///   - containerPort: Port inside the container
    ///   - protocol: Protocol (default: tcp)
    ///   - hostIP: Host IP to bind to
    public init(
        hostPort: UInt16,
        containerPort: UInt16,
        protocol: PortProtocol = .tcp,
        hostIP: String? = nil
    ) {
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.protocol = `protocol`
        self.hostIP = hostIP
    }

    /// Creates a port mapping where host and container ports are the same.
    ///
    /// - Parameter port: The port number
    /// - Returns: A `PortMapping` with matching host and container ports
    public static func same(_ port: UInt16) -> PortMapping {
        PortMapping(hostPort: port, containerPort: port)
    }

    /// Returns the Docker port mapping flag.
    ///
    /// Format: `-p [hostIP:]hostPort:containerPort[/protocol]`
    public var dockerFlag: String {
        var spec = ""
        if let ip = hostIP {
            spec += "\(ip):"
        }
        spec += "\(hostPort):\(containerPort)"
        if `protocol` != .tcp {
            spec += "/\(`protocol`.rawValue)"
        }
        return spec
    }
}

// MARK: - PortProtocol

/// Network protocols for port mappings.
public enum PortProtocol: String, Sendable, Codable {
    case tcp = "tcp"
    case udp = "udp"
}

// MARK: - Memory Size Extensions

extension Int {
    /// Converts gigabytes to bytes.
    ///
    /// - Returns: Value in bytes as `UInt64`
    public func gib() -> UInt64 {
        UInt64(self) * 1024 * 1024 * 1024
    }

    /// Converts mebibytes to bytes.
    ///
    /// - Returns: Value in bytes as `UInt64`
    public func mib() -> UInt64 {
        UInt64(self) * 1024 * 1024
    }
}

extension UInt64 {
    /// Formats bytes as a human-readable string.
    ///
    /// - Returns: Formatted string (e.g., "8.0 GiB", "512 MiB")
    public var formattedBytes: String {
        let gib = Double(self) / (1024 * 1024 * 1024)
        if gib >= 1.0 {
            return String(format: "%.1f GiB", gib)
        }

        let mib = Double(self) / (1024 * 1024)
        if mib >= 1.0 {
            return String(format: "%.0f MiB", mib)
        }

        let kib = Double(self) / 1024
        return String(format: "%.0f KiB", kib)
    }
}
