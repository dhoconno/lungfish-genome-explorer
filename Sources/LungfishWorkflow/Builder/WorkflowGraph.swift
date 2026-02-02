// WorkflowGraph.swift - DAG data structure for workflow builder
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - WorkflowGraph

/// A directed acyclic graph (DAG) representing a bioinformatics workflow.
///
/// The graph maintains nodes and connections, ensuring the graph remains acyclic.
/// It supports validation, topological sorting for execution order, and
/// export to workflow languages like Nextflow and Snakemake.
///
/// ## Example
/// ```swift
/// var graph = WorkflowGraph(name: "RNA-Seq Pipeline")
///
/// // Add nodes
/// let fastqNode = graph.addNode(type: .fastqInput, position: CGPoint(x: 100, y: 100))
/// let qcNode = graph.addNode(type: .qualityControl, position: CGPoint(x: 300, y: 100))
///
/// // Connect nodes
/// try graph.addConnection(
///     sourceNodeId: fastqNode.id,
///     sourcePortId: "reads",
///     targetNodeId: qcNode.id,
///     targetPortId: "reads"
/// )
///
/// // Get execution order
/// let order = try graph.topologicalSort()
/// ```
public struct WorkflowGraph: Sendable, Codable, Identifiable {
    /// Unique identifier for this graph
    public let id: UUID

    /// Name of the workflow
    public var name: String

    /// Description of the workflow
    public var description: String?

    /// Version of the workflow
    public var version: String

    /// Author of the workflow
    public var author: String?

    /// All nodes in the graph
    public private(set) var nodes: [UUID: WorkflowNode]

    /// All connections in the graph
    public private(set) var connections: [UUID: WorkflowConnection]

    /// Date the workflow was created
    public let createdAt: Date

    /// Date the workflow was last modified
    public var modifiedAt: Date

    /// Creates a new empty workflow graph.
    ///
    /// - Parameters:
    ///   - id: Unique identifier (auto-generated if not provided)
    ///   - name: Name of the workflow
    ///   - description: Optional description
    ///   - version: Version string (default: "1.0.0")
    ///   - author: Optional author name
    public init(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        version: String = "1.0.0",
        author: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.author = author
        self.nodes = [:]
        self.connections = [:]
        self.createdAt = Date()
        self.modifiedAt = Date()
    }

    // MARK: - Node Management

    /// Adds a new node to the graph.
    ///
    /// - Parameters:
    ///   - type: The type of node to add
    ///   - position: Position in the canvas
    ///   - label: Optional custom label
    /// - Returns: The newly created node
    @discardableResult
    public mutating func addNode(
        type: WorkflowNodeType,
        position: CGPoint,
        label: String? = nil
    ) -> WorkflowNode {
        let node = WorkflowNode(type: type, label: label, position: position)
        nodes[node.id] = node
        modifiedAt = Date()
        return node
    }

    /// Adds an existing node to the graph.
    ///
    /// - Parameter node: The node to add
    /// - Throws: `WorkflowGraphError.duplicateNode` if a node with the same ID exists
    public mutating func addNode(_ node: WorkflowNode) throws {
        guard nodes[node.id] == nil else {
            throw WorkflowGraphError.duplicateNode(node.id)
        }
        nodes[node.id] = node
        modifiedAt = Date()
    }

    /// Removes a node and all its connections from the graph.
    ///
    /// - Parameter nodeId: The ID of the node to remove
    /// - Returns: The removed node, or `nil` if not found
    @discardableResult
    public mutating func removeNode(_ nodeId: UUID) -> WorkflowNode? {
        guard let node = nodes.removeValue(forKey: nodeId) else {
            return nil
        }

        // Remove all connections involving this node
        let connectionsToRemove = connections.values.filter {
            $0.sourceNodeId == nodeId || $0.targetNodeId == nodeId
        }
        for connection in connectionsToRemove {
            connections.removeValue(forKey: connection.id)
        }

        modifiedAt = Date()
        return node
    }

    /// Gets a node by its ID.
    ///
    /// - Parameter nodeId: The ID of the node to get
    /// - Returns: The node, or `nil` if not found
    public func getNode(_ nodeId: UUID) -> WorkflowNode? {
        nodes[nodeId]
    }

    /// Updates a node in the graph.
    ///
    /// - Parameter node: The updated node
    /// - Throws: `WorkflowGraphError.nodeNotFound` if the node doesn't exist
    public mutating func updateNode(_ node: WorkflowNode) throws {
        guard nodes[node.id] != nil else {
            throw WorkflowGraphError.nodeNotFound(node.id)
        }
        nodes[node.id] = node
        modifiedAt = Date()
    }

    /// Returns all nodes as an array.
    public var allNodes: [WorkflowNode] {
        Array(nodes.values)
    }

    // MARK: - Connection Management

    /// Adds a connection between two nodes.
    ///
    /// - Parameters:
    ///   - sourceNodeId: ID of the source node
    ///   - sourcePortId: ID of the source output port
    ///   - targetNodeId: ID of the target node
    ///   - targetPortId: ID of the target input port
    /// - Returns: The newly created connection
    /// - Throws: Various `WorkflowGraphError` if the connection is invalid
    @discardableResult
    public mutating func addConnection(
        sourceNodeId: UUID,
        sourcePortId: String,
        targetNodeId: UUID,
        targetPortId: String
    ) throws -> WorkflowConnection {
        // Get the nodes
        guard let sourceNode = nodes[sourceNodeId] else {
            throw WorkflowGraphError.nodeNotFound(sourceNodeId)
        }
        guard let targetNode = nodes[targetNodeId] else {
            throw WorkflowGraphError.nodeNotFound(targetNodeId)
        }

        // Create the connection
        let connection = WorkflowConnection(
            sourceNodeId: sourceNodeId,
            sourcePortId: sourcePortId,
            targetNodeId: targetNodeId,
            targetPortId: targetPortId
        )

        // Validate the connection
        if let error = connection.validate(sourceNode: sourceNode, targetNode: targetNode) {
            throw WorkflowGraphError.invalidConnection(error)
        }

        // Check for duplicate connection
        let isDuplicate = connections.values.contains { existing in
            existing.sourceNodeId == sourceNodeId &&
            existing.sourcePortId == sourcePortId &&
            existing.targetNodeId == targetNodeId &&
            existing.targetPortId == targetPortId
        }
        if isDuplicate {
            throw WorkflowGraphError.invalidConnection(.duplicateConnection)
        }

        // Check for cycles
        if wouldCreateCycle(from: sourceNodeId, to: targetNodeId) {
            throw WorkflowGraphError.invalidConnection(.wouldCreateCycle)
        }

        connections[connection.id] = connection
        modifiedAt = Date()
        return connection
    }

    /// Removes a connection from the graph.
    ///
    /// - Parameter connectionId: The ID of the connection to remove
    /// - Returns: The removed connection, or `nil` if not found
    @discardableResult
    public mutating func removeConnection(_ connectionId: UUID) -> WorkflowConnection? {
        let connection = connections.removeValue(forKey: connectionId)
        if connection != nil {
            modifiedAt = Date()
        }
        return connection
    }

    /// Gets a connection by its ID.
    ///
    /// - Parameter connectionId: The ID of the connection to get
    /// - Returns: The connection, or `nil` if not found
    public func getConnection(_ connectionId: UUID) -> WorkflowConnection? {
        connections[connectionId]
    }

    /// Returns all connections as an array.
    public var allConnections: [WorkflowConnection] {
        Array(connections.values)
    }

    /// Returns all connections originating from a node.
    public func outgoingConnections(from nodeId: UUID) -> [WorkflowConnection] {
        connections.values.filter { $0.sourceNodeId == nodeId }
    }

    /// Returns all connections targeting a node.
    public func incomingConnections(to nodeId: UUID) -> [WorkflowConnection] {
        connections.values.filter { $0.targetNodeId == nodeId }
    }

    // MARK: - Cycle Detection

    /// Checks if adding a connection would create a cycle in the graph.
    ///
    /// Uses depth-first search to detect if there's a path from target to source.
    ///
    /// - Parameters:
    ///   - source: The source node ID
    ///   - target: The target node ID
    /// - Returns: `true` if adding this edge would create a cycle
    public func wouldCreateCycle(from source: UUID, to target: UUID) -> Bool {
        // If source == target, it's obviously a cycle
        if source == target {
            return true
        }

        // Check if there's already a path from target back to source
        // using DFS
        var visited = Set<UUID>()
        var stack = [target]

        while !stack.isEmpty {
            let current = stack.removeLast()

            if current == source {
                return true
            }

            if visited.contains(current) {
                continue
            }
            visited.insert(current)

            // Add all nodes reachable from current
            for connection in outgoingConnections(from: current) {
                if !visited.contains(connection.targetNodeId) {
                    stack.append(connection.targetNodeId)
                }
            }
        }

        return false
    }

    /// Checks if the graph contains any cycles.
    ///
    /// - Returns: `true` if the graph has cycles
    public func hasCycles() -> Bool {
        var visited = Set<UUID>()
        var recursionStack = Set<UUID>()

        func dfs(_ nodeId: UUID) -> Bool {
            visited.insert(nodeId)
            recursionStack.insert(nodeId)

            for connection in outgoingConnections(from: nodeId) {
                let next = connection.targetNodeId
                if !visited.contains(next) {
                    if dfs(next) {
                        return true
                    }
                } else if recursionStack.contains(next) {
                    return true
                }
            }

            recursionStack.remove(nodeId)
            return false
        }

        for nodeId in nodes.keys {
            if !visited.contains(nodeId) {
                if dfs(nodeId) {
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Topological Sort

    /// Returns the nodes in topological order (execution order).
    ///
    /// Uses Kahn's algorithm for topological sorting.
    ///
    /// - Returns: Array of nodes in topological order
    /// - Throws: `WorkflowGraphError.cycleDetected` if the graph has cycles
    public func topologicalSort() throws -> [WorkflowNode] {
        var inDegree = [UUID: Int]()
        var queue = [UUID]()
        var result = [WorkflowNode]()

        // Initialize in-degree for all nodes
        for nodeId in nodes.keys {
            inDegree[nodeId] = 0
        }

        // Calculate in-degree for each node
        for connection in connections.values {
            inDegree[connection.targetNodeId, default: 0] += 1
        }

        // Find all nodes with no incoming edges
        for (nodeId, degree) in inDegree where degree == 0 {
            queue.append(nodeId)
        }

        // Process nodes
        while !queue.isEmpty {
            let nodeId = queue.removeFirst()
            if let node = nodes[nodeId] {
                result.append(node)
            }

            // Reduce in-degree for adjacent nodes
            for connection in outgoingConnections(from: nodeId) {
                let targetId = connection.targetNodeId
                inDegree[targetId]! -= 1
                if inDegree[targetId] == 0 {
                    queue.append(targetId)
                }
            }
        }

        // Check if all nodes were processed
        if result.count != nodes.count {
            throw WorkflowGraphError.cycleDetected
        }

        return result
    }

    // MARK: - Validation

    /// Validates the entire workflow graph.
    ///
    /// - Returns: Array of validation issues, empty if valid
    public func validate() -> [WorkflowValidationIssue] {
        var issues = [WorkflowValidationIssue]()

        // Check for empty graph
        if nodes.isEmpty {
            issues.append(.emptyWorkflow)
        }

        // Check for cycles
        if hasCycles() {
            issues.append(.containsCycles)
        }

        // Check for disconnected input nodes
        let inputNodes = nodes.values.filter { $0.type.category == .input }
        for node in inputNodes {
            if outgoingConnections(from: node.id).isEmpty {
                issues.append(.disconnectedInput(nodeId: node.id, nodeName: node.label))
            }
        }

        // Check for unconnected required ports
        for node in nodes.values {
            for port in node.inputPorts where port.isRequired {
                let hasConnection = connections.values.contains { connection in
                    connection.targetNodeId == node.id && connection.targetPortId == port.id
                }
                if !hasConnection {
                    issues.append(.missingRequiredInput(
                        nodeId: node.id,
                        nodeName: node.label,
                        portName: port.name
                    ))
                }
            }
        }

        // Check for output nodes without input
        let outputNodes = nodes.values.filter { $0.type.category == .output }
        for node in outputNodes {
            if incomingConnections(to: node.id).isEmpty {
                issues.append(.disconnectedOutput(nodeId: node.id, nodeName: node.label))
            }
        }

        return issues
    }

    /// Returns whether the workflow is valid (has no validation issues).
    public var isValid: Bool {
        validate().isEmpty
    }

    // MARK: - Statistics

    /// Returns the number of nodes in the graph.
    public var nodeCount: Int {
        nodes.count
    }

    /// Returns the number of connections in the graph.
    public var connectionCount: Int {
        connections.count
    }

    /// Returns input nodes (nodes with no incoming connections from the workflow).
    public var inputNodes: [WorkflowNode] {
        nodes.values.filter { $0.type.category == .input }
    }

    /// Returns output nodes (nodes that produce final outputs).
    public var outputNodes: [WorkflowNode] {
        nodes.values.filter { $0.type.category == .output }
    }
}

// MARK: - WorkflowGraphError

/// Errors that can occur when manipulating a workflow graph.
public enum WorkflowGraphError: Error, LocalizedError, Sendable {
    case nodeNotFound(UUID)
    case duplicateNode(UUID)
    case connectionNotFound(UUID)
    case invalidConnection(ConnectionValidationError)
    case cycleDetected
    case emptyGraph

    public var errorDescription: String? {
        switch self {
        case .nodeNotFound(let id):
            return "Node not found: \(id)"
        case .duplicateNode(let id):
            return "Node already exists: \(id)"
        case .connectionNotFound(let id):
            return "Connection not found: \(id)"
        case .invalidConnection(let error):
            return "Invalid connection: \(error.localizedDescription)"
        case .cycleDetected:
            return "Cycle detected in workflow graph"
        case .emptyGraph:
            return "Workflow graph is empty"
        }
    }
}

// MARK: - WorkflowValidationIssue

/// Issues found during workflow validation.
public enum WorkflowValidationIssue: Sendable, Hashable {
    case emptyWorkflow
    case containsCycles
    case disconnectedInput(nodeId: UUID, nodeName: String)
    case disconnectedOutput(nodeId: UUID, nodeName: String)
    case missingRequiredInput(nodeId: UUID, nodeName: String, portName: String)

    /// Human-readable description of the issue
    public var description: String {
        switch self {
        case .emptyWorkflow:
            return "Workflow has no nodes"
        case .containsCycles:
            return "Workflow contains cycles"
        case .disconnectedInput(_, let name):
            return "Input node '\(name)' is not connected to anything"
        case .disconnectedOutput(_, let name):
            return "Output node '\(name)' has no input"
        case .missingRequiredInput(_, let nodeName, let portName):
            return "Node '\(nodeName)' is missing required input '\(portName)'"
        }
    }

    /// Severity of the issue
    public var severity: ValidationSeverity {
        switch self {
        case .emptyWorkflow:
            return .error
        case .containsCycles:
            return .error
        case .disconnectedInput:
            return .warning
        case .disconnectedOutput:
            return .warning
        case .missingRequiredInput:
            return .error
        }
    }
}

// MARK: - ValidationSeverity

/// Severity level for validation issues.
public enum ValidationSeverity: Sendable, Hashable {
    case warning
    case error
}
