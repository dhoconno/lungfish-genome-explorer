// BlastVerificationTableExport.swift - The BLAST verification table export that the drawer and its CLI leaf share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// The BLAST verification table export (Phase 2.12 lane 12.33, ARCH ruling 1.1 row A9).
///
/// The drawer and `blast export table` build the table with the function of this type, so the drawer and the leaf
/// agree on the bytes.
public enum BlastVerificationTableExport {
    /// The leaf's path under `lungfish-cli` (ARCH ruling 1.1, row A9).
    public static let commandPath = ["blast", "export", "table"]
    /// The workflow name the leaf's record carries (ARCH ruling 1.4).
    public static let workflowName = "lungfish blast export table"

    /// The leaf's invocation for the record file the drawer shows, with absolute standardized paths. The begin
    /// helper passes its `arguments()` to the runner and to the row's command, and the leaf records its
    /// `canonicalArgv()`.
    public static func invocation(
        recordURL: URL,
        format: ViewerExportDelimitedFormat,
        outputURL: URL,
        force: Bool,
        emitsEvents: Bool = true
    ) -> ViewerExportInvocation {
        ViewerExportInvocation(
            commandPath: commandPath,
            input: recordURL.standardizedFileURL.path,
            outputFormat: format.rawValue,
            output: outputURL.standardizedFileURL.path,
            force: force,
            emitsEvents: emitsEvents
        )
    }
}

extension BlastVerificationTableExport {
    /// The CSV or TSV text of a BLAST verification result.
    ///
    /// CSV/TSV columns: Read ID, Verdict, LCA Flag, Hit Rank, Accession,
    /// Organism, TaxId, Identity%, Coverage%, E-value, Bit Score, Alignment Length,
    /// Queried Taxon, Taxon Check.
    ///
    /// Verdict says only whether a read's alignment passed the quality thresholds, so a read that contradicts the
    /// row can read `verified`. Taxon Check says what the read means for the row: `supporting`, `contradicting` or
    /// `inconclusive` (ruling BIO-VERIFIED-EXPORT). A search that asked no taxon question, such as a contig or sequence
    /// BLAST, has an empty Queried Taxon and a Taxon Check of `no taxon queried`.
    ///
    /// One row per hit (a read with 5 hits produces 5 output rows). A fragment's
    /// mates each get their own rows under the one read ID, deciding mate first.
    ///
    /// - Parameters:
    ///   - result: The saved result.
    ///   - taxonomy: The taxonomy the saved file holds beside the result, or nil when the file holds none.
    ///   - separator: The field separator.
    public static func tableContent(
        result: BlastVerificationResult,
        taxonomy: BlastTaxonomyContext? = nil,
        separator: String
    ) -> String {
        var lines: [String] = []

        // Header
        let header = [
            "Read ID", "Verdict", "LCA Flag", "Hit Rank", "Accession",
            "Organism", "TaxId", "Identity%", "Coverage%", "E-value",
            "Bit Score", "Alignment Length", "Queried Taxon", "Taxon Check"
        ]
        lines.append(header.joined(separator: separator))

        // Data rows
        let asked = asksAboutATaxon(result, taxonomy: taxonomy)
        let queriedTaxon = asked ? escapeField(result.taxonName, separator: separator) : ""
        let rows = result.readResults.flatMap { fragment in
            ([fragment] + (fragment.otherMates ?? [])).map {
                (readResult: $0, taxonCheck: asked ? taxonCheckWord(fragment) : "no taxon queried")
            }
        }
        for (readResult, taxonCheck) in rows {
            if readResult.topHits.isEmpty {
                // Read with no hits: single row with top-level fields
                let row = [
                    escapeField(readResult.id, separator: separator),
                    readResult.verdict.rawValue,
                    readResult.hasLCADisagreement ? "true" : "false",
                    "1",
                    escapeField(readResult.topHitAccession ?? "", separator: separator),
                    escapeField(readResult.topHitOrganism ?? "", separator: separator),
                    "",
                    readResult.percentIdentity.map { String(format: "%.2f", $0) } ?? "",
                    readResult.queryCoverage.map { String(format: "%.2f", $0) } ?? "",
                    readResult.eValue.map { String($0) } ?? "",
                    readResult.bitScore.map { String(format: "%.1f", $0) } ?? "",
                    readResult.alignmentLength.map { String($0) } ?? "",
                    queriedTaxon,
                    taxonCheck,
                ]
                lines.append(row.joined(separator: separator))
            } else {
                // One row per hit
                for hit in readResult.topHits {
                    let row = [
                        escapeField(readResult.id, separator: separator),
                        readResult.verdict.rawValue,
                        readResult.hasLCADisagreement ? "true" : "false",
                        String(hit.rank),
                        escapeField(hit.accession, separator: separator),
                        escapeField(hit.organism ?? "", separator: separator),
                        hit.taxId.map { String($0) } ?? "",
                        String(format: "%.2f", hit.percentIdentity),
                        String(format: "%.2f", hit.queryCoverage),
                        String(hit.eValue),
                        String(format: "%.1f", hit.bitScore),
                        String(hit.alignmentLength),
                        queriedTaxon,
                        taxonCheck,
                    ]
                    lines.append(row.joined(separator: separator))
                }
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Whether the saved search asked about a taxon. A clade that holds an ID or a name is a claim, as `judgesAClaim`
    /// in `BlastService` reads it, and EsViritu saves that with tax ID 0, so the tax ID alone cannot say. A tax ID other
    /// than 0 names a taxon with no clade, which is all an archive that saved no request holds. Tax ID 0 and no clade
    /// is the contig or sequence BLAST.
    private static func asksAboutATaxon(_ result: BlastVerificationResult, taxonomy: BlastTaxonomyContext?) -> Bool {
        if let taxonomy, !taxonomy.cladeTaxIds.isEmpty || !taxonomy.cladeNames.isEmpty { return true }
        return result.taxId != 0
    }

    /// What a fragment says about the queried taxon, by the rule of the counts behind the badge
    /// (`BlastVerificationResult.supportingCount`, `contradictingCount` and `inconclusiveCount`). Every mate of a
    /// fragment carries the one word, since the counts read only the fragment's row. A pair whose mates conflict
    /// counts as neither, and its other mate still holds its own `.verified`.
    private static func taxonCheckWord(_ fragment: BlastReadResult) -> String {
        guard fragment.verdict == .verified else { return "inconclusive" }
        return fragment.matchesQueriedTaxon ? "supporting" : "contradicting"
    }

    /// Escapes a field for CSV output by quoting if it contains the separator,
    /// quotes, or newlines.
    private static func escapeField(_ value: String, separator: String) -> String {
        if value.contains(separator) || value.contains("\"") || value.contains("\n") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }
}
