// TaxonNode.swift - Taxonomy tree node and tree wrapper for Kraken2 results
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A node in the taxonomic tree representing a single taxon.
///
/// `TaxonNode` is a reference type because the taxonomy forms a tree with
/// parent-child relationships. After construction by ``KreportParser``, the tree
/// is treated as immutable and safe to share across isolation domains.
///
/// ## Thread Safety
///
/// `TaxonNode` conforms to `@unchecked Sendable` because the tree is built
/// once during parsing and then read-only. No mutation occurs after the parser
/// returns the completed ``TaxonTree``.
///
/// ## Tree Structure
///
/// Each node maintains a weak reference to its ``parent`` and strong references
/// to its ``children``. The root node's parent is `nil`.
///
/// ```
/// root (taxId: 1)
///   +-- Bacteria (taxId: 2)
///   |     +-- Proteobacteria (taxId: 1224)
///   |     +-- Firmicutes (taxId: 1239)
///   +-- Archaea (taxId: 2157)
/// ```
public final class TaxonNode: @unchecked Sendable {

    // MARK: - Properties

    /// NCBI taxonomy identifier for this taxon.
    public let taxId: Int

    /// Scientific name of this taxon.
    public let name: String

    /// Taxonomic rank (species, genus, family, etc.).
    public let rank: TaxonomicRank

    /// Depth level in the tree (0 = root, 1 = domain, etc.).
    ///
    /// This is derived from the indentation in the Kraken2 report and may not
    /// correspond exactly to ``rank``'s ``TaxonomicRank/ringIndex`` because
    /// intermediate ranks can appear at any depth.
    public let depth: Int

    /// Number of reads classified directly to this taxon (not descendants).
    ///
    /// In the Kraken2 report, this is column 3 (`read_count`).
    public let readsDirect: Int

    /// Number of reads in this taxon's clade (this taxon + all descendants).
    ///
    /// In the Kraken2 report, this is column 2 (`clade_count`).
    public let readsClade: Int

    /// Fraction of total reads in this taxon's clade.
    ///
    /// Computed as `readsClade / totalReads`. Ranges from 0.0 to 1.0.
    public let fractionClade: Double

    /// Fraction of total reads classified directly to this taxon.
    ///
    /// Computed as `readsDirect / totalReads`. Ranges from 0.0 to 1.0.
    public let fractionDirect: Double

    /// Bracken-adjusted read count, if Bracken output has been merged.
    ///
    /// This is `nil` until ``BrackenParser/mergeBracken(url:into:)`` is called.
    public internal(set) var brackenReads: Int?

    /// Bracken-adjusted fraction, if Bracken output has been merged.
    ///
    /// This is `nil` until ``BrackenParser/mergeBracken(url:into:)`` is called.
    public internal(set) var brackenFraction: Double?

    /// Weak reference to the parent node. `nil` for the root and unclassified nodes.
    public internal(set) weak var parent: TaxonNode?

    /// Child nodes in taxonomic order (as they appear in the report).
    public internal(set) var children: [TaxonNode]

    /// NCBI taxonomy ID of the parent node, for serialization.
    public let parentTaxId: Int?

    // MARK: - Initialization

    /// Creates a new taxon node.
    ///
    /// - Parameters:
    ///   - taxId: NCBI taxonomy identifier.
    ///   - name: Scientific name.
    ///   - rank: Taxonomic rank.
    ///   - depth: Depth level in the tree.
    ///   - readsDirect: Reads classified directly to this taxon.
    ///   - readsClade: Reads in this taxon's clade.
    ///   - fractionClade: Clade fraction of total reads.
    ///   - fractionDirect: Direct fraction of total reads.
    ///   - parentTaxId: Parent taxon's taxonomy ID, or `nil` for root.
    public init(
        taxId: Int,
        name: String,
        rank: TaxonomicRank,
        depth: Int,
        readsDirect: Int,
        readsClade: Int,
        fractionClade: Double,
        fractionDirect: Double,
        parentTaxId: Int?
    ) {
        self.taxId = taxId
        self.name = name
        self.rank = rank
        self.depth = depth
        self.readsDirect = readsDirect
        self.readsClade = readsClade
        self.fractionClade = fractionClade
        self.fractionDirect = fractionDirect
        self.parentTaxId = parentTaxId
        self.children = []
    }

    // MARK: - Tree Traversal

    /// Returns all nodes in this subtree in pre-order (self, then children recursively).
    ///
    /// - Returns: An array of all descendant nodes including self.
    public func allDescendants() -> [TaxonNode] {
        var result = [self]
        for child in children {
            result.append(contentsOf: child.allDescendants())
        }
        return result
    }

    /// Returns all leaf nodes (nodes with no children) in this subtree.
    ///
    /// - Returns: An array of leaf nodes.
    public func leaves() -> [TaxonNode] {
        if children.isEmpty {
            return [self]
        }
        return children.flatMap { $0.leaves() }
    }

    /// Returns the path from the root to this node.
    ///
    /// - Returns: An array starting with the root and ending with self.
    public func pathFromRoot() -> [TaxonNode] {
        var path: [TaxonNode] = [self]
        var current = self
        while let p = current.parent {
            path.insert(p, at: 0)
            current = p
        }
        return path
    }
}

// MARK: - Equatable & Hashable

extension TaxonNode: Equatable {
    public static func == (lhs: TaxonNode, rhs: TaxonNode) -> Bool {
        lhs.taxId == rhs.taxId
    }
}

extension TaxonNode: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(taxId)
    }
}

// MARK: - CustomStringConvertible

extension TaxonNode: CustomStringConvertible {
    public var description: String {
        "\(rank.code) \(name) (taxId: \(taxId), clade: \(readsClade), direct: \(readsDirect))"
    }
}

// MARK: - TaxonTree

/// An immutable taxonomy tree built from a Kraken2 kreport file.
///
/// `TaxonTree` is the primary data structure produced by ``KreportParser``. It
/// wraps a root ``TaxonNode`` and provides efficient lookup by taxonomy ID,
/// filtering by rank, and summary statistics.
///
/// ## Thread Safety
///
/// `TaxonTree` conforms to `Sendable` because both the struct itself and the
/// underlying `TaxonNode` tree are immutable after construction.
///
/// ## Usage
///
/// ```swift
/// let tree = try KreportParser.parse(url: kreportURL)
///
/// // Summary statistics
/// print("Total reads: \(tree.totalReads)")
/// print("Species count: \(tree.speciesCount)")
///
/// // Lookup
/// if let ecoli = tree.node(taxId: 562) {
///     print("E. coli: \(ecoli.readsClade) reads")
/// }
///
/// // Filter by rank
/// let species = tree.nodes(at: .species)
/// ```
public struct TaxonTree: Sendable {

    // MARK: - Properties

    /// The root node of the taxonomy tree.
    public let root: TaxonNode

    /// The unclassified node, if present in the report.
    ///
    /// In a Kraken2 report, the unclassified line (rank code `U`) represents
    /// reads that could not be assigned to any taxon. This node is not part of
    /// the tree hierarchy.
    public let unclassifiedNode: TaxonNode?

    /// Total number of reads processed by Kraken2.
    public let totalReads: Int

    /// Number of reads classified to at least one taxon.
    public let classifiedReads: Int

    /// Number of reads that could not be classified.
    public let unclassifiedReads: Int

    /// Fraction of reads that were unclassified (0.0 to 1.0).
    public var unclassifiedFraction: Double {
        guard totalReads > 0 else { return 0.0 }
        return Double(unclassifiedReads) / Double(totalReads)
    }

    /// Fraction of reads that were classified (0.0 to 1.0).
    public var classifiedFraction: Double {
        guard totalReads > 0 else { return 0.0 }
        return Double(classifiedReads) / Double(totalReads)
    }

    /// Precomputed index of taxonomy ID to node for O(1) lookup.
    private let taxIdIndex: [Int: TaxonNode]

    // MARK: - Initialization

    /// Creates a taxonomy tree from a parsed root node and optional unclassified node.
    ///
    /// This initializer precomputes the taxonomy ID index for efficient lookup.
    ///
    /// - Parameters:
    ///   - root: The root node of the taxonomy tree.
    ///   - unclassifiedNode: The unclassified node, if present.
    ///   - totalReads: Total number of reads processed.
    public init(root: TaxonNode, unclassifiedNode: TaxonNode?, totalReads: Int) {
        self.root = root
        self.unclassifiedNode = unclassifiedNode
        self.totalReads = totalReads
        self.classifiedReads = root.readsClade
        self.unclassifiedReads = unclassifiedNode?.readsClade ?? (totalReads - root.readsClade)

        // Build tax ID index
        var index: [Int: TaxonNode] = [:]
        for node in root.allDescendants() {
            index[node.taxId] = node
        }
        if let unclassified = unclassifiedNode {
            index[unclassified.taxId] = unclassified
        }
        self.taxIdIndex = index
    }

    // MARK: - Lookup

    /// Finds a node by its NCBI taxonomy ID.
    ///
    /// - Parameter taxId: The taxonomy ID to search for.
    /// - Returns: The matching node, or `nil` if not found.
    /// - Complexity: O(1) amortized via precomputed index.
    public func node(taxId: Int) -> TaxonNode? {
        taxIdIndex[taxId]
    }

    /// Finds all nodes matching a given name (case-insensitive substring match).
    ///
    /// - Parameter name: The name to search for.
    /// - Returns: An array of matching nodes, possibly empty.
    public func find(name: String) -> [TaxonNode] {
        let lowered = name.lowercased()
        return allNodes().filter { $0.name.lowercased().contains(lowered) }
    }

    /// Returns all nodes at a given taxonomic rank.
    ///
    /// - Parameter rank: The rank to filter by.
    /// - Returns: An array of nodes at that rank.
    public func nodes(at rank: TaxonomicRank) -> [TaxonNode] {
        allNodes().filter { $0.rank == rank }
    }

    /// Returns all nodes in the tree in pre-order traversal.
    ///
    /// This includes the root and all descendants but excludes the unclassified
    /// node (which is not part of the tree hierarchy).
    ///
    /// - Returns: An array of all nodes in pre-order.
    public func allNodes() -> [TaxonNode] {
        root.allDescendants()
    }

    // MARK: - Statistics

    /// The number of distinct species in the tree.
    public var speciesCount: Int {
        nodes(at: .species).count
    }

    /// The number of distinct genera in the tree.
    public var generaCount: Int {
        nodes(at: .genus).count
    }

    /// The species with the highest clade read count.
    ///
    /// Returns `nil` if no species-rank nodes exist in the tree.
    public var dominantSpecies: TaxonNode? {
        nodes(at: .species).max(by: { $0.readsClade < $1.readsClade })
    }

    /// Shannon diversity index (H') computed over species-level nodes.
    ///
    /// H' = -sum(p_i * ln(p_i)) where p_i is the fraction of reads for each
    /// species relative to classified reads only.
    ///
    /// - Returns: The Shannon diversity index, or 0.0 if fewer than 2 species.
    public var shannonDiversity: Double {
        let speciesNodes = nodes(at: .species).filter { $0.readsClade > 0 }
        guard speciesNodes.count >= 2, classifiedReads > 0 else { return 0.0 }

        var h = 0.0
        for node in speciesNodes {
            let p = Double(node.readsClade) / Double(classifiedReads)
            if p > 0 {
                h -= p * log(p)
            }
        }
        return h
    }

    /// Simpson diversity index (1 - D) computed over species-level nodes.
    ///
    /// 1 - D = 1 - sum(p_i^2) where p_i is the fraction of reads for each
    /// species relative to classified reads only.
    ///
    /// - Returns: The Simpson diversity index (0.0 to 1.0), or 0.0 if fewer
    ///   than 2 species.
    public var simpsonDiversity: Double {
        let speciesNodes = nodes(at: .species).filter { $0.readsClade > 0 }
        guard speciesNodes.count >= 2, classifiedReads > 0 else { return 0.0 }

        var sumPSquared = 0.0
        for node in speciesNodes {
            let p = Double(node.readsClade) / Double(classifiedReads)
            sumPSquared += p * p
        }
        return 1.0 - sumPSquared
    }
}

// MARK: - CustomStringConvertible

extension TaxonTree: CustomStringConvertible {
    public var description: String {
        """
        TaxonTree(totalReads: \(totalReads), classified: \(classifiedReads), \
        unclassified: \(unclassifiedReads), species: \(speciesCount), \
        genera: \(generaCount))
        """
    }
}
