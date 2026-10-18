// NvdContigsExport.swift - The NVD contigs export that the viewer and its CLI leaf share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The NVD contigs export (Phase 2.12 lane 12.31 M4, ARCH ruling 1.1).
///
/// The view and `nvd export contigs` write the table with `contigsTSV`, so the two agree on the bytes. The rows are
/// the database's best hits of the picked samples after the search, in the database's order, which the outline's
/// sort and grouping never change.
public enum NvdContigsExport {
    /// The leaf's path under `lungfish-cli` (ARCH ruling 1.1).
    public static let commandPath = ["nvd", "export", "contigs"]
    /// The workflow name the leaf's record carries (ARCH ruling 1.4).
    public static let workflowName = "lungfish nvd export contigs"
    /// The result folder's database, which the viewer opens and the leaf reads.
    public static let databaseFileName = "hits.sqlite"
    /// The result folder's manifest, which names the experiment.
    public static let manifestFileName = "manifest.json"

    /// The leaf's invocation for a view state, with absolute standardized paths. The begin helper passes its
    /// `arguments()` to the runner and to the row's command, and the leaf records its `canonicalArgv()`.
    public static func invocation(
        resultURL: URL,
        state: ViewerTableExportState,
        outputURL: URL,
        force: Bool,
        emitsEvents: Bool = true
    ) -> ViewerExportInvocation {
        ViewerExportInvocation(
            commandPath: commandPath,
            input: resultURL.standardizedFileURL.path,
            state: state,
            output: outputURL.standardizedFileURL.path,
            force: force,
            emitsEvents: emitsEvents
        )
    }

    /// The best hits the view shows for `samples`, which are every best hit of those samples, or those the search
    /// matches when `searchText` is not empty, in the database's order.
    public static func shownHits(in database: NvdDatabase, samples: [String], searchText: String) throws -> [NvdBlastHit] {
        searchText.isEmpty
            ? try database.bestHits(forSamples: samples)
            : try database.searchBestHits(query: searchText, samples: samples)
    }

    /// The contigs table of `hits`, each row with its own sample's metadata values.
    public static func contigsTSV(
        hits: [NvdBlastHit],
        metadataHeaders: [String],
        metadataValuesBySample: [String: [String]]
    ) -> String {
        var lines: [String] = []
        var header = "sample_id\tcontig\tlength\tclassification\trank\taccession\tsubject\tpident\tevalue\tbitscore\tmapped_reads\treads_per_billion"
        if !metadataHeaders.isEmpty {
            header += "\t" + metadataHeaders.joined(separator: "\t")
        }
        lines.append(header)

        for hit in hits {
            var line = "\(hit.sampleId)\t\(hit.qseqid)\t\(hit.qlen)\t\(hit.adjustedTaxidName)\t\(hit.adjustedTaxidRank)\t\(hit.sseqid)\t\(hit.stitle)\t\(String(format: "%.2f", hit.pident))\t\(hit.evalue)\t\(String(format: "%.1f", hit.bitscore))\t\(hit.mappedReads)\t\(String(format: "%.0f", hit.readsPerBillion))"
            let metaValues = metadataValuesBySample[hit.sampleId] ?? []
            if !metaValues.isEmpty {
                line += "\t" + metaValues.joined(separator: "\t")
            }
            lines.append(line)
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
