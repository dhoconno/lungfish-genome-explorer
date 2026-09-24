import CryptoKit
import Foundation
import SQLite3

struct PhylogeneticTreeSubtreeExporter {
    let bundle: PhylogeneticTreeBundle
    let nodesByID: [String: PhylogeneticTreeNormalizedNode]

    init(bundle: PhylogeneticTreeBundle) {
        self.bundle = bundle
        self.nodesByID = Dictionary(uniqueKeysWithValues: bundle.normalizedTree.nodes.map { ($0.id, $0) })
    }

    func export(nodeID: String) throws -> PhylogeneticTreeSubtreeExport {
        let trimmed = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let node = nodesByID[trimmed] else {
            throw PhylogeneticTreeBundleError.nodeNotFound("node \(nodeID)")
        }
        return try export(node: node)
    }

    func export(label: String) throws -> PhylogeneticTreeSubtreeExport {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = bundle.normalizedTree.nodes.filter { node in
            node.displayLabel == trimmed || node.rawLabel == trimmed
        }
        guard matches.isEmpty == false else {
            throw PhylogeneticTreeBundleError.nodeNotFound("label \(label)")
        }
        guard matches.count == 1, let node = matches.first else {
            throw PhylogeneticTreeBundleError.ambiguousNodeLabel(label)
        }
        return try export(node: node)
    }

    private func export(node: PhylogeneticTreeNormalizedNode) throws -> PhylogeneticTreeSubtreeExport {
        PhylogeneticTreeSubtreeExport(
            selectedNodeID: node.id,
            selectedLabel: nodeLabel(for: node) ?? node.displayLabel,
            newick: try writeNode(node) + ";",
            descendantTipCount: node.descendantTipCount
        )
    }

    private func writeNode(_ node: PhylogeneticTreeNormalizedNode) throws -> String {
        var result = ""
        if node.childIDs.isEmpty == false {
            let children = try node.childIDs.map { childID in
                guard let child = nodesByID[childID] else {
                    throw PhylogeneticTreeBundleError.parseFailed("Normalized tree references missing child node \(childID).")
                }
                return try writeNode(child)
            }
            result += "(" + children.joined(separator: ",") + ")"
        }
        if let label = nodeLabel(for: node), label.isEmpty == false {
            result += escapedLabel(label)
        }
        if let branchLength = node.branchLength {
            result += ":\(branchLength)"
        }
        return result
    }

    private func nodeLabel(for node: PhylogeneticTreeNormalizedNode) -> String? {
        if node.isTip {
            return node.displayLabel
        }
        if node.rawLabel != nil {
            return node.displayLabel
        }
        if node.displayLabel != "Internal node" {
            return node.displayLabel
        }
        return nil
    }

    private func escapedLabel(_ label: String) -> String {
        let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        if label.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return label
        }
        return "'" + label.replacingOccurrences(of: "'", with: "''") + "'"
    }
}

/// Rewrites a tree as Newick rooted on a chosen node.
///
/// The normalized tree is walked as an undirected graph starting from the selected node.
/// Internal node labels follow the Newick convention of annotating the edge above the node
/// (support values), so a label travels with its edge when the new root reverses that edge.
/// If the old root is left with a single onward neighbour it is spliced out and the two branch
/// lengths are summed, so the tree keeps its total length and gains no unary node.
struct PhylogeneticTreeRerooter {
    let bundle: PhylogeneticTreeBundle
    let nodesByID: [String: PhylogeneticTreeNormalizedNode]
    let neighborsByID: [String: [String]]

    init(bundle: PhylogeneticTreeBundle) {
        self.bundle = bundle
        self.nodesByID = Dictionary(uniqueKeysWithValues: bundle.normalizedTree.nodes.map { ($0.id, $0) })
        // TreeNormalizer records every edge twice (parent.childIDs and child.parentID), so the
        // adjacency list must be deduplicated or every branch is written once per duplicate entry.
        // Children keep their original order and the parent comes last, so a rerooted clade reads
        // the same way as the source tree.
        var neighbors: [String: [String]] = [:]
        func connect(_ first: String, to second: String) {
            if neighbors[first, default: []].contains(second) == false {
                neighbors[first, default: []].append(second)
            }
        }
        for node in bundle.normalizedTree.nodes {
            for childID in node.childIDs {
                connect(node.id, to: childID)
            }
            if let parentID = node.parentID {
                connect(node.id, to: parentID)
            }
        }
        for node in bundle.normalizedTree.nodes {
            for childID in node.childIDs {
                connect(childID, to: node.id)
            }
            if let parentID = node.parentID {
                connect(parentID, to: node.id)
            }
        }
        self.neighborsByID = neighbors
    }

    func newick(rootedOn selected: PhylogeneticTreeNormalizedNode) throws -> String {
        if selected.isTip, let parentID = selected.parentID {
            let tip = label(for: selected) + ":0.0"
            let rest = try writeDirected(nodeID: parentID, previousID: selected.id, branchLength: selected.branchLength) ?? ""
            return "(\(tip),\(rest));"
        }
        let children = try (neighborsByID[selected.id] ?? []).compactMap { childID in
            try writeDirected(nodeID: childID, previousID: selected.id, branchLength: edgeLength(between: selected.id, and: childID))
        }
        return "(\(children.joined(separator: ",")))\(labelForNewRoot(selected));"
    }

    /// Writes the subtree hanging off `nodeID` when approached from `previousID`.
    /// Returns nil when the node contributes nothing (an old root left with no onward edge).
    private func writeDirected(nodeID: String, previousID: String, branchLength: Double?) throws -> String? {
        guard let node = nodesByID[nodeID] else {
            throw PhylogeneticTreeBundleError.nodeNotFound(nodeID)
        }
        let onwardIDs = (neighborsByID[nodeID] ?? []).filter { $0 != previousID }
        if node.parentID == nil, node.isTip == false {
            if onwardIDs.isEmpty {
                return nil
            }
            if onwardIDs.count == 1, let onlyID = onwardIDs.first {
                let merged = summedLength(branchLength, edgeLength(between: nodeID, and: onlyID))
                return try writeDirected(nodeID: onlyID, previousID: nodeID, branchLength: merged)
            }
        }
        let children = try onwardIDs.compactMap { childID in
            try writeDirected(nodeID: childID, previousID: nodeID, branchLength: edgeLength(between: nodeID, and: childID))
        }
        var result = children.isEmpty ? "" : "(\(children.joined(separator: ",")))"
        result += edgeLabel(for: node, approachedFrom: previousID)
        if let branchLength {
            result += ":\(branchLength)"
        }
        return result
    }

    private func summedLength(_ first: Double?, _ second: Double?) -> Double? {
        if first == nil, second == nil {
            return nil
        }
        return (first ?? 0) + (second ?? 0)
    }

    /// The label written for `node` given the node it was reached from in the rerooted walk.
    /// Tip labels stay with the tip. An internal label annotates the edge to the node's original
    /// parent, so when that edge is walked in reverse the label is written on the original parent.
    private func edgeLabel(for node: PhylogeneticTreeNormalizedNode, approachedFrom previousID: String) -> String {
        if node.isTip || node.parentID == previousID {
            return label(for: node)
        }
        guard let previous = nodesByID[previousID], previous.isTip == false, previous.parentID == node.id else {
            return ""
        }
        return label(for: previous)
    }

    private func edgeLength(between firstID: String, and secondID: String) -> Double? {
        if nodesByID[secondID]?.parentID == firstID {
            return nodesByID[secondID]?.branchLength
        }
        if nodesByID[firstID]?.parentID == secondID {
            return nodesByID[firstID]?.branchLength
        }
        return nil
    }

    private func labelForNewRoot(_ node: PhylogeneticTreeNormalizedNode) -> String {
        if node.isTip {
            return ""
        }
        // A label on the new root annotated its old parent edge, which is now written on the old parent.
        return node.parentID == nil ? label(for: node) : ""
    }

    private func label(for node: PhylogeneticTreeNormalizedNode) -> String {
        if node.isTip {
            return escapedLabel(node.displayLabel)
        }
        if node.rawLabel != nil || node.displayLabel != "Internal node" {
            return escapedLabel(node.displayLabel)
        }
        return ""
    }

    private func escapedLabel(_ label: String) -> String {
        let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        if label.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return label
        }
        return "'" + label.replacingOccurrences(of: "'", with: "''") + "'"
    }
}

struct PhylogeneticTreeRelabeler {
    let bundle: PhylogeneticTreeBundle
    let nodesByID: [String: PhylogeneticTreeNormalizedNode]

    init(bundle: PhylogeneticTreeBundle) {
        self.bundle = bundle
        self.nodesByID = Dictionary(uniqueKeysWithValues: bundle.normalizedTree.nodes.map { ($0.id, $0) })
    }

    func newick(labelsByTip: [String: String]) throws -> String {
        guard let root = bundle.normalizedTree.nodes.first(where: { $0.parentID == nil }) else {
            throw PhylogeneticTreeBundleError.parseFailed("Normalized tree has no root node.")
        }
        return try writeNode(root, labelsByTip: labelsByTip) + ";"
    }

    private func writeNode(_ node: PhylogeneticTreeNormalizedNode, labelsByTip: [String: String]) throws -> String {
        var result = ""
        if node.childIDs.isEmpty == false {
            let children = try node.childIDs.map { childID in
                guard let child = nodesByID[childID] else {
                    throw PhylogeneticTreeBundleError.parseFailed("Normalized tree references missing child node \(childID).")
                }
                return try writeNode(child, labelsByTip: labelsByTip)
            }
            result += "(" + children.joined(separator: ",") + ")"
        }
        if let label = label(for: node, labelsByTip: labelsByTip), label.isEmpty == false {
            result += escapedLabel(label)
        }
        if let branchLength = node.branchLength {
            result += ":\(branchLength)"
        }
        return result
    }

    private func label(for node: PhylogeneticTreeNormalizedNode, labelsByTip: [String: String]) -> String? {
        if node.isTip {
            return labelsByTip[node.displayLabel] ?? labelsByTip[node.rawLabel ?? ""] ?? node.displayLabel
        }
        if node.rawLabel != nil || node.displayLabel != "Internal node" {
            return node.displayLabel
        }
        return nil
    }

    private func escapedLabel(_ label: String) -> String {
        let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        if label.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return label
        }
        return "'" + label.replacingOccurrences(of: "'", with: "''") + "'"
    }
}

struct TreeTipMetadataTable {
    let headers: [String]
    let rows: [[String: String]]

    static func load(from url: URL) throws -> TreeTipMetadataTable {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PhylogeneticTreeBundleError.missingBundleFile("metadata.tsv")
        }
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let headerLine = lines.first else {
            throw PhylogeneticTreeBundleError.parseFailed("metadata.tsv is empty.")
        }
        let headers = headerLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard headers.isEmpty == false else {
            throw PhylogeneticTreeBundleError.parseFailed("metadata.tsv has no header row.")
        }
        let rows = lines.dropFirst().map { line in
            let values = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return Dictionary(uniqueKeysWithValues: headers.enumerated().map { index, header in
                (header, index < values.count ? values[index] : "")
            })
        }
        return TreeTipMetadataTable(headers: headers, rows: rows)
    }

    func labelsByTip(column: String) throws -> [String: String] {
        guard headers.contains(column) else {
            throw PhylogeneticTreeBundleError.nodeNotFound("metadata column \(column)")
        }
        let idColumn = ["id", "sample", "sample_id", "name", "tip"].first { headers.contains($0) } ?? headers[0]
        return rows.reduce(into: [String: String]()) { result, row in
            guard let id = row[idColumn]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  id.isEmpty == false,
                  let label = row[column]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  label.isEmpty == false else { return }
            result[id] = label
        }
    }
}
