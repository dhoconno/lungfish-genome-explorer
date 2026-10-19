// Kraken2TaxonomyTableExport.swift - The Kraken2 taxonomy table export that the viewer and its CLI leaf share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The Kraken2 taxonomy table export (Phase 2.12 lane 12.33, ARCH ruling 1.1 row A7).
///
/// The view and `kraken2 export table` build the table with the functions of this type, so the view and the leaf
/// agree on the bytes and on the record's inputs.
public enum Kraken2TaxonomyTableExport {
    /// The leaf's path under `lungfish-cli` (ARCH ruling 1.1, row A7).
    public static let commandPath = ["kraken2", "export", "table"]
    /// The workflow name the leaf's record carries (ARCH ruling 1.4).
    public static let workflowName = "lungfish kraken2 export table"
    /// The viewer index of a batch or an indexed result, which the database form of the leaf reads.
    public static let databaseFileName = "kraken2.sqlite"

    /// The leaf's invocation for a view state, with absolute standardized paths. The begin helper passes its
    /// `arguments()` to the runner and to the row's command, and the leaf records its `canonicalArgv()`.
    public static func invocation(
        resultURL: URL,
        samples: [String],
        metadataColumns: [String],
        format: ViewerExportDelimitedFormat,
        outputURL: URL,
        force: Bool,
        emitsEvents: Bool = true
    ) -> ViewerExportInvocation {
        ViewerExportInvocation(
            commandPath: commandPath,
            input: resultURL.standardizedFileURL.path,
            state: ViewerTableExportState(samples: samples, metadataColumns: metadataColumns),
            outputFormat: format.rawValue,
            output: outputURL.standardizedFileURL.path,
            force: force,
            emitsEvents: emitsEvents
        )
    }

    /// The sidecar a Kraken2 run writes beside its report, which the sidecar form of the leaf reads.
    public static var sidecarFileName: String { ClassificationResult.sidecarFilename }

    /// The one sample id of a sidecar result. The view uses it as the table's metadata sample and the record names
    /// it as the selected sample (ARCH ruling on 12.33 F1, C2).
    public static func sidecarSampleId(config: ClassificationConfig) -> String {
        config.sampleDisplayName
            ?? config.inputFiles.first?.deletingPathExtension().lastPathComponent
            ?? "sample"
    }

    /// The files the table of a sidecar result is read from, in the order the record lists them, which are the
    /// sidecar, the Kraken2 report and the Bracken file when the result has one. A caller keeps only the files that
    /// exist. The reads the run classified are not among them, since the table never opens them (BIO 6).
    public static func sidecarInputURLs(folder: URL, result: ClassificationResult) -> [URL] {
        [folder.appendingPathComponent(sidecarFileName), result.reportURL] + (result.brackenURL.map { [$0] } ?? [])
    }

    /// The sample metadata files of a result folder, the table and its edit journal, that an export reads when it
    /// writes a metadata column. Empty when it writes none. A caller keeps only the files that exist.
    public static func metadataInputURLs(in resultURL: URL, writesMetadata: Bool) -> [URL] {
        guard writesMetadata else { return [] }
        let folder = resultURL.appendingPathComponent("metadata", isDirectory: true)
        return [
            folder.appendingPathComponent("sample_metadata.tsv"),
            folder.appendingPathComponent("sample_metadata_edits.json"),
        ]
    }
}

extension Kraken2TaxonomyTableExport {
    /// Builds the delimited text content for export.
    ///
    /// Writes a header row followed by all nodes in depth-first order.
    ///
    /// - Parameters:
    ///   - tree: The taxonomy tree to export.
    ///   - separator: Column separator character.
    ///   - metadataHeaders: The visible metadata column headers, appended to the header row.
    ///   - metadataValues: The values of those columns for the sample, appended to every row.
    /// - Returns: The complete file content as a string.
    public static func buildDelimitedExport(
        tree: TaxonTree,
        separator: String,
        metadataHeaders: [String],
        metadataValues: [String]
    ) -> String {
        var lines: [String] = []

        // Header
        var headers = ["Name", "Rank", "Reads (Clade)", "Reads (Direct)", "Clade %", "Direct %"]
        // Append visible metadata column headers
        headers.append(contentsOf: metadataHeaders)
        lines.append(headers.joined(separator: separator))

        // Depth-first traversal
        let allNodes = tree.allNodes()
        for node in allNodes {
            let cladePercent = tree.totalReads > 0
                ? String(format: "%.4f", Double(node.readsClade) / Double(tree.totalReads) * 100)
                : "0.0000"
            let directPercent = tree.totalReads > 0
                ? String(format: "%.4f", Double(node.readsDirect) / Double(tree.totalReads) * 100)
                : "0.0000"

            // Escape fields that may contain the separator (mainly for CSV)
            let name = escapeField(node.name, separator: separator)
            let rank = escapeField(node.rank.displayName, separator: separator)

            var row = [
                name,
                rank,
                "\(node.readsClade)",
                "\(node.readsDirect)",
                cladePercent,
                directPercent,
            ]
            for value in metadataValues {
                row.append(escapeField(value, separator: separator))
            }
            lines.append(row.joined(separator: separator))
        }

        // Include unclassified node if present
        if let unclassified = tree.unclassifiedNode {
            let cladePercent = tree.totalReads > 0
                ? String(format: "%.4f", Double(unclassified.readsClade) / Double(tree.totalReads) * 100)
                : "0.0000"
            var row = [
                escapeField(unclassified.name, separator: separator),
                escapeField(unclassified.rank.displayName, separator: separator),
                "\(unclassified.readsClade)",
                "\(unclassified.readsDirect)",
                cladePercent,
                cladePercent,
            ]
            for value in metadataValues {
                row.append(escapeField(value, separator: separator))
            }
            lines.append(row.joined(separator: separator))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Escapes a field value for delimited output.
    ///
    /// For CSV, fields containing commas, quotes, or newlines are quoted.
    /// For TSV, fields are returned unmodified (tabs in taxon names are rare).
    ///
    /// - Parameters:
    ///   - value: The field value.
    ///   - separator: The column separator.
    /// - Returns: The escaped field value.
    private static func escapeField(_ value: String, separator: String) -> String {
        guard separator == "," else { return value }
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }

    /// Builds a synthetic multi-sample taxonomy tree where each selected sample appears
    /// as its own top-level node containing that sample's taxonomy hierarchy.
    public static func mergedTree(for sampleTrees: [(sampleId: String, tree: TaxonTree)]) -> TaxonTree {
        let totalReads = sampleTrees.reduce(0) { $0 + $1.tree.totalReads }
        let root = TaxonNode(
            taxId: 1,
            name: "Root",
            rank: .root,
            depth: 0,
            readsDirect: 0,
            readsClade: totalReads,
            fractionClade: 1.0,
            fractionDirect: 0.0,
            parentTaxId: nil
        )

        var syntheticSampleTaxId = -1
        for (sampleId, sampleTree) in sampleTrees {
            let sampleReads = sampleTree.root.readsClade
            let sampleFraction = totalReads > 0 ? Double(sampleReads) / Double(totalReads) : 0.0
            let sampleNode = TaxonNode(
                taxId: syntheticSampleTaxId,
                name: sampleId,
                rank: TaxonomicRank(code: "no rank"),
                depth: 1,
                readsDirect: 0,
                readsClade: sampleReads,
                fractionClade: sampleFraction,
                fractionDirect: 0.0,
                parentTaxId: 1
            )
            syntheticSampleTaxId -= 1

            for child in sampleTree.root.children {
                sampleNode.addChild(cloneTaxonSubtree(child))
            }
            root.addChild(sampleNode)
        }

        return TaxonTree(root: root, unclassifiedNode: nil, totalReads: totalReads)
    }

    private static func cloneTaxonSubtree(_ node: TaxonNode) -> TaxonNode {
        let copy = TaxonNode(
            taxId: node.taxId,
            name: node.name,
            rank: node.rank,
            depth: node.depth,
            readsDirect: node.readsDirect,
            readsClade: node.readsClade,
            fractionClade: node.fractionClade,
            fractionDirect: node.fractionDirect,
            parentTaxId: node.parentTaxId
        )
        for child in node.children {
            copy.addChild(cloneTaxonSubtree(child))
        }
        return copy
    }
}
