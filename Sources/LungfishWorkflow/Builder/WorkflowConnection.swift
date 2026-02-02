// WorkflowConnection.swift - Connection model for workflow graph
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - WorkflowConnection

/// A connection between two nodes in a workflow graph.
///
/// Connections represent data flow from an output port of one node
/// to an input port of another node. The connection is only valid
/// if the data types are compatible.
///
/// ## Example
/// ```swift
/// let connection = WorkflowConnection(
///     sourceNodeId: inputNode.id,
///     sourcePortId: "reads",
///     targetNodeId: trimmingNode.id,
///     targetPortId: "reads"
/// )
/// ```
public struct WorkflowConnection: Sendable, Codable, Identifiable, Hashable {
    /// Unique identifier for this connection
    public let id: UUID

    /// ID of the source (output) node
    public let sourceNodeId: UUID

    /// ID of the source output port
    public let sourcePortId: String

    /// ID of the target (input) node
    public let targetNodeId: UUID

    /// ID of the target input port
    public let targetPortId: String

    /// Optional label for the connection
    public var label: String?

    /// Whether this connection is currently selected
    public var isSelected: Bool = false

    /// Creates a new connection.
    ///
    /// - Parameters:
    ///   - id: Unique identifier (auto-generated if not provided)
    ///   - sourceNodeId: ID of the source (output) node
    ///   - sourcePortId: ID of the source output port
    ///   - targetNodeId: ID of the target (input) node
    ///   - targetPortId: ID of the target input port
    ///   - label: Optional label for the connection
    public init(
        id: UUID = UUID(),
        sourceNodeId: UUID,
        sourcePortId: String,
        targetNodeId: UUID,
        targetPortId: String,
        label: String? = nil
    ) {
        self.id = id
        self.sourceNodeId = sourceNodeId
        self.sourcePortId = sourcePortId
        self.targetNodeId = targetNodeId
        self.targetPortId = targetPortId
        self.label = label
    }

    // MARK: - Validation

    /// Validates that this connection is valid given the source and target nodes.
    ///
    /// - Parameters:
    ///   - sourceNode: The source node
    ///   - targetNode: The target node
    /// - Returns: `nil` if valid, or an error describing why the connection is invalid
    public func validate(
        sourceNode: WorkflowNode,
        targetNode: WorkflowNode
    ) -> ConnectionValidationError? {
        // Check that nodes are different
        guard sourceNodeId != targetNodeId else {
            return .selfConnection
        }

        // Find the ports
        guard let sourcePort = sourceNode.outputPort(withId: sourcePortId) else {
            return .sourcePortNotFound(sourcePortId)
        }

        guard let targetPort = targetNode.inputPort(withId: targetPortId) else {
            return .targetPortNotFound(targetPortId)
        }

        // Check port directions
        guard sourcePort.direction == .output else {
            return .invalidSourceDirection
        }

        guard targetPort.direction == .input else {
            return .invalidTargetDirection
        }

        // Check type compatibility
        guard sourcePort.dataType.isCompatible(with: targetPort.dataType) else {
            return .incompatibleTypes(
                source: sourcePort.dataType,
                target: targetPort.dataType
            )
        }

        return nil
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: WorkflowConnection, rhs: WorkflowConnection) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - ConnectionValidationError

/// Errors that can occur when validating a connection.
public enum ConnectionValidationError: Error, LocalizedError, Sendable, Equatable {
    case selfConnection
    case sourcePortNotFound(String)
    case targetPortNotFound(String)
    case invalidSourceDirection
    case invalidTargetDirection
    case incompatibleTypes(source: PortDataType, target: PortDataType)
    case duplicateConnection
    case wouldCreateCycle

    public var errorDescription: String? {
        switch self {
        case .selfConnection:
            return "Cannot connect a node to itself"
        case .sourcePortNotFound(let portId):
            return "Source port '\(portId)' not found"
        case .targetPortNotFound(let portId):
            return "Target port '\(portId)' not found"
        case .invalidSourceDirection:
            return "Source must be an output port"
        case .invalidTargetDirection:
            return "Target must be an input port"
        case .incompatibleTypes(let source, let target):
            return "Incompatible types: cannot connect \(source.displayName) to \(target.displayName)"
        case .duplicateConnection:
            return "A connection already exists between these ports"
        case .wouldCreateCycle:
            return "This connection would create a cycle in the workflow"
        }
    }
}

// MARK: - ConnectionEndpoint

/// Represents one end of a connection (for use during connection creation).
public struct ConnectionEndpoint: Sendable, Hashable {
    /// The node ID
    public let nodeId: UUID

    /// The port ID
    public let portId: String

    /// The port direction
    public let direction: PortDirection

    /// The data type of the port
    public let dataType: PortDataType

    /// Creates a connection endpoint.
    public init(nodeId: UUID, portId: String, direction: PortDirection, dataType: PortDataType) {
        self.nodeId = nodeId
        self.portId = portId
        self.direction = direction
        self.dataType = dataType
    }

    /// Creates an endpoint from a node and port.
    public init?(node: WorkflowNode, portId: String) {
        self.nodeId = node.id

        if let inputPort = node.inputPort(withId: portId) {
            self.portId = portId
            self.direction = .input
            self.dataType = inputPort.dataType
        } else if let outputPort = node.outputPort(withId: portId) {
            self.portId = portId
            self.direction = .output
            self.dataType = outputPort.dataType
        } else {
            return nil
        }
    }
}
