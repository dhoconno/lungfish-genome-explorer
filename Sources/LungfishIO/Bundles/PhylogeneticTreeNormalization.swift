import CryptoKit
import Foundation
import SQLite3

enum TreeNormalizer {
    static func normalizedTree(from root: ParsedTreeNode, rooted: Bool) -> PhylogeneticTreeNormalizedTree {
        var nodes: [PartialNode] = []
        _ = collect(
            node: root,
            parentID: nil,
            path: "root",
            cumulativeDivergence: 0,
            nodes: &nodes
        )
        let finalNodes = nodes.map { partial in
            PhylogeneticTreeNormalizedNode(
                id: partial.id,
                rawLabel: partial.rawLabel,
                displayLabel: partial.displayLabel,
                parentID: partial.parentID,
                childIDs: partial.childIDs,
                isTip: partial.isTip,
                branchLength: partial.branchLength,
                cumulativeDivergence: partial.cumulativeDivergence,
                metadata: partial.metadata,
                support: partial.support,
                descendantTipCount: partial.descendantTipCount
            )
        }
        return PhylogeneticTreeNormalizedTree(schemaVersion: 1, treeID: "tree-1", rooted: rooted, nodes: finalNodes)
    }

    private static func collect(
        node: ParsedTreeNode,
        parentID: String?,
        path: String,
        cumulativeDivergence: Double,
        nodes: inout [PartialNode]
    ) -> (id: String, descendantTipCount: Int) {
        let id = stableID(path: path, node: node)
        var childIDs: [String] = []
        var descendantTipCount = node.children.isEmpty ? 1 : 0
        let nodeDivergence = cumulativeDivergence + (node.branchLength ?? 0)
        for (idx, child) in node.children.enumerated() {
            let childResult = collect(
                node: child,
                parentID: id,
                path: "\(path).\(idx)",
                cumulativeDivergence: nodeDivergence,
                nodes: &nodes
            )
            childIDs.append(childResult.id)
            descendantTipCount += childResult.descendantTipCount
        }

        let support = supportValue(for: node)
        nodes.insert(
            PartialNode(
                id: id,
                rawLabel: node.rawLabel,
                displayLabel: node.displayLabel.isEmpty ? "Internal node" : node.displayLabel,
                parentID: parentID,
                childIDs: childIDs,
                isTip: node.children.isEmpty,
                branchLength: node.branchLength,
                cumulativeDivergence: parentID == nil ? 0 : nodeDivergence,
                metadata: node.metadata,
                support: support,
                descendantTipCount: descendantTipCount
            ),
            at: 0
        )
        return (id, descendantTipCount)
    }

    private static func stableID(path: String, node: ParsedTreeNode) -> String {
        let content = "\(path)|\(node.rawLabel ?? "")|\(node.displayLabel)|\(node.children.count)"
        let digest = PhylogeneticTreeBundleImporter.sha256Hex(for: Data(content.utf8))
        return "node-\(digest.prefix(16))"
    }

    private static func supportValue(for node: ParsedTreeNode) -> PhylogeneticTreeSupport? {
        if let posterior = node.metadata["posterior"] {
            return PhylogeneticTreeSupport(rawValue: posterior, interpretation: "posterior")
        }
        guard !node.children.isEmpty, let raw = node.rawLabel else { return nil }
        guard let value = Double(raw) else {
            return PhylogeneticTreeSupport(rawValue: raw, interpretation: "unknown")
        }
        if value >= 0, value <= 1 {
            return PhylogeneticTreeSupport(rawValue: raw, interpretation: "posterior")
        }
        if value > 1, value <= 100 {
            return PhylogeneticTreeSupport(rawValue: raw, interpretation: "bootstrap")
        }
        return PhylogeneticTreeSupport(rawValue: raw, interpretation: "unknown")
    }

    private struct PartialNode {
        let id: String
        let rawLabel: String?
        let displayLabel: String
        let parentID: String?
        let childIDs: [String]
        let isTip: Bool
        let branchLength: Double?
        let cumulativeDivergence: Double?
        let metadata: [String: String]
        let support: PhylogeneticTreeSupport?
        let descendantTipCount: Int
    }
}

enum TreeWarningCollector {
    static func warnings(for tree: PhylogeneticTreeNormalizedTree) -> [String] {
        var warnings: [String] = []
        let nonRootNodes = tree.nodes.filter { $0.parentID != nil }
        if nonRootNodes.contains(where: { $0.branchLength == nil }) {
            warnings.append("Tree contains one or more edges without branch lengths.")
        }
        if nonRootNodes.contains(where: { ($0.branchLength ?? 0) < 0 }) {
            warnings.append("Tree contains one or more negative branch lengths.")
        }
        for node in tree.nodes where !node.isTip {
            if let support = node.support {
                if support.interpretation == "posterior", node.rawLabel == support.rawValue {
                    warnings.append("Internal support value '\(support.rawValue)' was interpreted as posterior probability.")
                } else if support.interpretation == "unknown" {
                    warnings.append("Internal support value '\(support.rawValue)' has unknown interpretation.")
                }
            }
        }
        return Array(NSOrderedSet(array: warnings)) as? [String] ?? warnings
    }
}

enum NewickWriter {
    static func write(_ root: ParsedTreeNode) -> String {
        writeNode(root) + ";"
    }

    private static func writeNode(_ node: ParsedTreeNode) -> String {
        var result = ""
        if !node.children.isEmpty {
            result += "(" + node.children.map(writeNode).joined(separator: ",") + ")"
        }
        if !node.displayLabel.isEmpty {
            result += escapedLabel(node.displayLabel)
        } else if let rawLabel = node.rawLabel {
            result += escapedLabel(rawLabel)
        }
        if let branchLength = node.branchLength {
            result += ":\(branchLength)"
        }
        return result
    }

    private static func escapedLabel(_ label: String) -> String {
        let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        if label.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return label
        }
        return "'" + label.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
