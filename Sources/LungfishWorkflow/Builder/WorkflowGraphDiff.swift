// WorkflowGraphDiff.swift - Saved workflow diff model
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct WorkflowGraphDiff: Sendable {
    public struct JSONReport: Codable, Sendable, Equatable {
        public let fromName: String
        public let toName: String
        public let fromVersion: String
        public let toVersion: String
        public let hasChanges: Bool
        public let changes: [String]
    }

    public let from: WorkflowGraph
    public let to: WorkflowGraph
    public let changes: [String]

    public var hasChanges: Bool { !changes.isEmpty }

    public var jsonReport: JSONReport {
        JSONReport(fromName: from.name, toName: to.name, fromVersion: from.version, toVersion: to.version, hasChanges: hasChanges, changes: changes)
    }

    public var textDescription: String {
        var lines = ["Workflow diff: \(from.name) (\(from.version)) -> \(to.name) (\(to.version))"]
        lines.append(contentsOf: changes.isEmpty ? ["No workflow changes."] : changes.map { "- \($0)" })
        return lines.joined(separator: "\n")
    }

    public static func compare(_ from: WorkflowGraph, _ to: WorkflowGraph) -> WorkflowGraphDiff {
        var changes: [String] = []
        if from.version != to.version { changes.append("Version: \(from.version) -> \(to.version)") }
        if from.name != to.name { changes.append("Name: \(from.name) -> \(to.name)") }
        if from.description != to.description { changes.append("Description changed") }

        let fromNodes = from.allNodes.sorted(by: nodeSort)
        let toNodes = to.allNodes.sorted(by: nodeSort)
        let fromIDs = Set(fromNodes.map(\.id))
        let toIDs = Set(toNodes.map(\.id))

        let added = toNodes.filter { !fromIDs.contains($0.id) }
        if !added.isEmpty { changes.append("Added nodes: \(added.map(nodeSummary).joined(separator: ", "))") }
        let removed = fromNodes.filter { !toIDs.contains($0.id) }
        if !removed.isEmpty { changes.append("Removed nodes: \(removed.map(nodeSummary).joined(separator: ", "))") }

        for id in fromIDs.intersection(toIDs).sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let old = from.getNode(id), let new = to.getNode(id) else { continue }
            changes.append(contentsOf: nodeChanges(from: old, to: new))
        }

        let fromConnectionKeys = Set(from.allConnections.map(connectionKey))
        let toConnectionKeys = Set(to.allConnections.map(connectionKey))
        let addedConnections = toConnectionKeys.subtracting(fromConnectionKeys).sorted()
        if !addedConnections.isEmpty { changes.append("Added connections: \(addedConnections.joined(separator: ", "))") }
        let removedConnections = fromConnectionKeys.subtracting(toConnectionKeys).sorted()
        if !removedConnections.isEmpty { changes.append("Removed connections: \(removedConnections.joined(separator: ", "))") }

        return WorkflowGraphDiff(from: from, to: to, changes: changes)
    }

    private static func nodeChanges(from old: WorkflowNode, to new: WorkflowNode) -> [String] {
        var changes: [String] = []
        let prefix = "Node \(new.label)"
        if old.label != new.label { changes.append("Node renamed: \(old.label) -> \(new.label)") }
        if old.type != new.type { changes.append("\(prefix) type: \(old.type.rawValue) -> \(new.type.rawValue)") }
        if old.notes != new.notes { changes.append("\(prefix) notes changed") }
        for key in Set(old.parameters.keys).union(new.parameters.keys).sorted() where old.parameters[key] != new.parameters[key] {
            changes.append("\(prefix) parameter \(key): \(old.parameters[key] ?? "<unset>") -> \(new.parameters[key] ?? "<unset>")")
        }
        return changes
    }

    private static func nodeSort(_ lhs: WorkflowNode, _ rhs: WorkflowNode) -> Bool {
        lhs.label == rhs.label ? lhs.id.uuidString < rhs.id.uuidString : lhs.label < rhs.label
    }

    private static func nodeSummary(_ node: WorkflowNode) -> String { "\(node.label) [\(node.type.rawValue)]" }

    private static func connectionKey(_ connection: WorkflowConnection) -> String {
        "\(connection.sourceNodeId.uuidString).\(connection.sourcePortId)->\(connection.targetNodeId.uuidString).\(connection.targetPortId)"
    }
}
