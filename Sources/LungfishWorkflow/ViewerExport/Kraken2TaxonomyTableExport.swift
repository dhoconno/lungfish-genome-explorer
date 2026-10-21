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
        sourceURL: URL,
        samples: [String],
        metadataColumns: [String],
        format: ViewerExportDelimitedFormat,
        outputURL: URL,
        force: Bool,
        emitsEvents: Bool = true
    ) -> ViewerExportInvocation {
        ViewerExportInvocation(
            commandPath: commandPath,
            input: sourceURL.standardizedFileURL.path,
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

    /// The file a table is read from and the form it selects (ARCH ruling on 12.33 F1, section 2).
    public enum Source: Equatable, Sendable {
        /// `kraken2.sqlite`, which holds every sample of a batch or an indexed result.
        case database(URL)
        /// `classification-result.json`, which holds the one sample of a run.
        case sidecar(URL)

        /// The form a path selects. The two file names select by name, and a folder selects the database when it
        /// holds one and else the sidecar, as the sidebar opens it. Nil for a missing path, a file with another name
        /// and a folder that holds neither file.
        public init?(url: URL, fileManager: FileManager = .default) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
            if isDirectory.boolValue {
                let database = url.appendingPathComponent(Kraken2TaxonomyTableExport.databaseFileName)
                let sidecar = url.appendingPathComponent(Kraken2TaxonomyTableExport.sidecarFileName)
                if fileManager.fileExists(atPath: database.path) {
                    self = .database(database)
                } else if fileManager.fileExists(atPath: sidecar.path) {
                    self = .sidecar(sidecar)
                } else {
                    return nil
                }
            } else if url.lastPathComponent == Kraken2TaxonomyTableExport.databaseFileName {
                self = .database(url)
            } else if url.lastPathComponent == Kraken2TaxonomyTableExport.sidecarFileName {
                self = .sidecar(url)
            } else {
                return nil
            }
        }

        /// The file the table is read from.
        public var fileURL: URL {
            switch self {
            case .database(let url), .sidecar(let url): return url
            }
        }

        /// The result folder, which also holds the `metadata` folder.
        public var folderURL: URL { fileURL.deletingLastPathComponent() }
    }

    /// The tree the viewer shows for the picked samples, which is the one sample's tree as it is and a merged tree
    /// for more. Nil with no sample.
    public static func displayTree(for sampleTrees: [(sampleId: String, tree: TaxonTree)]) -> TaxonTree? {
        guard let first = sampleTrees.first else { return nil }
        return sampleTrees.count == 1 ? first.tree : mergedTree(for: sampleTrees)
    }

    /// The visible metadata columns in the store's column order and each sample's values in that order, as
    /// `MetadataColumnController.exportHeaders` and `exportValues(for:)` give them. Empty with no store.
    public static func metadataTable(
        store: SampleMetadataStore?,
        visibleColumns: Set<String>,
        sampleIds: some Swift.Sequence<String>
    ) -> (headers: [String], valuesBySample: [String: [String]]) {
        guard let store else { return ([], [:]) }
        let headers = store.columnNames.filter { visibleColumns.contains($0) }
        var valuesBySample: [String: [String]] = [:]
        for sampleId in sampleIds {
            valuesBySample[sampleId] = headers.map { store.records[sampleId]?[$0] ?? "" }
        }
        return (headers, valuesBySample)
    }
}

extension Kraken2TaxonomyTableExport {
    /// Builds the delimited text of one sample's tree.
    ///
    /// Writes a header row, then the rows of the tree in depth-first order, then the sample's unclassified row when it
    /// has one. Every Clade % and Direct % divides by the tree's `totalReads`, all the reads of that sample with its
    /// unclassified reads included. The table of several samples comes from
    /// ``buildDelimitedExport(sampleTrees:separator:metadataHeaders:metadataValuesBySample:)``, which writes each
    /// sample's rows with the same function (Phase 2.13 lane 13.35, BIO-R1 item 3).
    ///
    /// - Parameters:
    ///   - tree: One sample's taxonomy tree.
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
        var lines = [headerLine(metadataHeaders: metadataHeaders, separator: separator)]
        let values = fitted(metadataValues, to: metadataHeaders.count)
        lines += rows(of: tree, values: values, separator: separator).map { $0.joined(separator: separator) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Builds the delimited text of the picked samples (Phase 2.13 lane 13.35, BIO-R1 items 1 and 3).
    ///
    /// One tree writes what the one-tree form writes. More trees write the header, the Root row of
    /// ``mergedTree(for:)`` and then each sample's own rows in the order given, with that sample's metadata values. The
    /// first row of a block stands for the one-sample table's root row and carries the sample id and the synthetic
    /// rank in place of its Name and Rank. So a block reads as that sample's own table, every percent divides by that
    /// sample's reads with its unclassified reads included, and a sample with unclassified reads ends its block with
    /// its own unclassified row. The Root row is the sum of every sample's reads with empty metadata fields.
    ///
    /// - Parameters:
    ///   - sampleTrees: The picked samples in the order the table lists them, each with its own tree.
    ///   - separator: Column separator character.
    ///   - metadataHeaders: The visible metadata column headers, appended to the header row.
    ///   - metadataValuesBySample: The values of those columns for each sample id. A sample with no entry gets empty
    ///     fields.
    /// - Returns: The complete file content as a string.
    public static func buildDelimitedExport(
        sampleTrees: [(sampleId: String, tree: TaxonTree)],
        separator: String,
        metadataHeaders: [String],
        metadataValuesBySample: [String: [String]]
    ) -> String {
        let columnCount = metadataHeaders.count
        var lines = [headerLine(metadataHeaders: metadataHeaders, separator: separator)]
        let isMerged = sampleTrees.count > 1
        if isMerged {
            let merged = mergedTree(for: sampleTrees)
            let rootRow = rowFields(
                of: merged.root, totalReads: merged.totalReads, values: fitted([], to: columnCount), separator: separator
            )
            lines.append(rootRow.joined(separator: separator))
        }
        for (sampleId, tree) in sampleTrees {
            let values = fitted(metadataValuesBySample[sampleId] ?? [], to: columnCount)
            var block = rows(of: tree, values: values, separator: separator)
            if isMerged, !block.isEmpty {
                block[0][0] = escapeField(sampleId, separator: separator)
                block[0][1] = escapeField(sampleNodeRank.displayName, separator: separator)
            }
            lines += block.map { $0.joined(separator: separator) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The header row, the six count columns and then the visible metadata columns.
    private static func headerLine(metadataHeaders: [String], separator: String) -> String {
        let counts = ["Name", "Rank", "Reads (Clade)", "Reads (Direct)", "Clade %", "Direct %"]
        return (counts + metadataHeaders).joined(separator: separator)
    }

    /// The metadata values cut or padded with empty fields to the number of columns, so every row is as long as the
    /// header (12.33 ARCH ruling on F1, C3).
    private static func fitted(_ values: [String], to count: Int) -> [String] {
        Array((values + Array(repeating: "", count: count)).prefix(count))
    }

    /// A percent of a sample's reads with four decimals, or zero when the sample has no reads.
    private static func percent(_ reads: Int, of totalReads: Int) -> String {
        totalReads > 0 ? String(format: "%.4f", Double(reads) / Double(totalReads) * 100) : "0.0000"
    }

    /// The fields of one row, which are the name and rank, the four counts and the metadata values, each escaped for
    /// the separator. The Direct % divides `directPercentReads`.
    private static func rowFields(
        name: String,
        rank: String,
        readsClade: Int,
        readsDirect: Int,
        directPercentReads: Int,
        totalReads: Int,
        values: [String],
        separator: String
    ) -> [String] {
        var fields = [
            escapeField(name, separator: separator),
            escapeField(rank, separator: separator),
            "\(readsClade)",
            "\(readsDirect)",
            percent(readsClade, of: totalReads),
            percent(directPercentReads, of: totalReads),
        ]
        for value in values {
            fields.append(escapeField(value, separator: separator))
        }
        return fields
    }

    private static func rowFields(of node: TaxonNode, totalReads: Int, values: [String], separator: String) -> [String] {
        rowFields(
            name: node.name,
            rank: node.rank.displayName,
            readsClade: node.readsClade,
            readsDirect: node.readsDirect,
            directPercentReads: node.readsDirect,
            totalReads: totalReads,
            values: values,
            separator: separator
        )
    }

    /// The rows of one sample's tree, which both forms of the builder write with this function, so a block of the
    /// merged table is the one-sample table by construction. They are the tree's nodes in depth-first order and then
    /// the unclassified row when the sample has one, which divides its clade reads for both percents as it always has.
    private static func rows(of tree: TaxonTree, values: [String], separator: String) -> [[String]] {
        var result = tree.allNodes().map {
            rowFields(of: $0, totalReads: tree.totalReads, values: values, separator: separator)
        }
        if let unclassified = tree.unclassifiedNode {
            result.append(rowFields(
                name: unclassified.name,
                rank: unclassified.rank.displayName,
                readsClade: unclassified.readsClade,
                readsDirect: unclassified.readsDirect,
                directPercentReads: unclassified.readsClade,
                totalReads: tree.totalReads,
                values: values,
                separator: separator
            ))
        }
        return result
    }

    /// The rank a sample's row carries in the merged table and in the viewer's merged tree.
    private static var sampleNodeRank: TaxonomicRank { TaxonomicRank(code: "no rank") }

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
            // A sample's node reads as that sample alone (Phase 2.13 lane 13.35, BIO-R1 item 5). It counts the reads
            // Kraken2 assigned to the sample's root, and its fractions divide by the sample's own reads with the
            // unclassified reads included, so the viewer's `%` column and the exported table give one number for the row.
            let sampleReads = sampleTree.root.readsClade
            let directReads = sampleTree.root.readsDirect
            let ownReads = sampleTree.totalReads
            let sampleNode = TaxonNode(
                taxId: syntheticSampleTaxId,
                name: sampleId,
                rank: sampleNodeRank,
                depth: 1,
                readsDirect: directReads,
                readsClade: sampleReads,
                fractionClade: ownReads > 0 ? Double(sampleReads) / Double(ownReads) : 0.0,
                fractionDirect: ownReads > 0 ? Double(directReads) / Double(ownReads) : 0.0,
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
