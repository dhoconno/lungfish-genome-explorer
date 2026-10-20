// KrakenBlastTableExportPinTests.swift - The Kraken2 taxonomy table and BLAST results table bytes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishCore
@testable import LungfishIO
@testable import LungfishKit
import LungfishTestSupport
@testable import LungfishWorkflow

/// Phase 2.12 lane 12.33, M1 (QA 1), reduced by Phase 2.13. Pins the bytes of the taxonomy view's CSV and TSV and of
/// the BLAST results table, for a quoted field, a read with no hits and a read with hits. Both exports run as leaves
/// (`kraken2 export table` and `blast export table`), so the in-app writers that these pins first held are gone,
/// and so are the records they pinned. Each leaf's record is pinned by its own replay class
/// (Kraken2TableExportCLIGUIParityReplayTests and BlastTableExportCLIGUIParityReplayTests), and the bytes stay here.
@MainActor
final class KrakenBlastTableExportPinTests: XCTestCase {
    // MARK: - The taxonomy table (census A7)

    /// The taxonomy builder's bytes for a quoted field and an unclassified row, in both separators. The record these
    /// pins carried at the base is pinned by Kraken2TableExportCLIGUIParityReplayTests on its frozen side A and on
    /// the leaf, and the recorded command is parsed by TaxonomyTableExportRowTests.
    func testTheTaxonomyTableBytes() {
        let tree = taxonomyTree()
        for (separator, format) in [(",", "csv"), ("\t", "tsv")] {
            let content = Kraken2TaxonomyTableExport.buildDelimitedExport(
                tree: tree, separator: separator, metadataHeaders: [], metadataValues: []
            )
            XCTAssertEqual(content, expectedTaxonomyTable(separator: separator, tree: tree), format)
        }
    }

    // MARK: - The BLAST results table (census A9)

    /// The BLAST table builder's bytes for a quoted read id and organism, a read with no hits and a read with hits,
    /// in both separators. The leaf `blast export table` writes these bytes, and BlastTableExportCLIGUIParityReplayTests
    /// pins its record.
    func testTheBlastTableBytes() {
        for (separator, format) in [(",", "csv"), ("\t", "tsv")] {
            XCTAssertEqual(
                BlastVerificationTableExport.tableContent(result: blastResult(), separator: separator),
                expectedBlastTable(separator: separator),
                format
            )
        }
    }

    // MARK: - Taxonomy fixture

    /// A tree with a root, a taxon whose name holds a comma and quotes, a plain taxon and an unclassified node.
    private func taxonomyTree() -> TaxonTree {
        let root = TaxonNode(
            taxId: 1, name: "root", rank: .root, depth: 0,
            readsDirect: 0, readsClade: 300, fractionClade: 0.75, fractionDirect: 0,
            parentTaxId: nil
        )
        let quoted = TaxonNode(
            taxId: 9, name: "Candidatus \"Foo, bar\"", rank: .species, depth: 1,
            readsDirect: 200, readsClade: 200, fractionClade: 0.5, fractionDirect: 0.5,
            parentTaxId: 1
        )
        quoted.parent = root
        let plain = TaxonNode(
            taxId: 10, name: "Plain virus", rank: .species, depth: 1,
            readsDirect: 100, readsClade: 100, fractionClade: 0.25, fractionDirect: 0.25,
            parentTaxId: 1
        )
        plain.parent = root
        root.children = [quoted, plain]
        let unclassified = TaxonNode(
            taxId: 0, name: "unclassified", rank: .unclassified, depth: 0,
            readsDirect: 100, readsClade: 100, fractionClade: 0.25, fractionDirect: 0.25,
            parentTaxId: nil
        )
        return TaxonTree(root: root, unclassifiedNode: unclassified, totalReads: 400)
    }

    private func expectedTaxonomyTable(separator: String, tree: TaxonTree) -> String {
        let unclassifiedRank = tree.unclassifiedNode?.rank.displayName ?? ""
        // The taxonomy builder quotes a field that holds the separator, so the TSV leaves this name as it is. The
        // BLAST builder also quotes a field that holds a quote, so its TSV quotes the same kind of name.
        let quotedName = separator == "," ? "\"Candidatus \"\"Foo, bar\"\"\"" : "Candidatus \"Foo, bar\""
        let rows: [[String]] = [
            ["Name", "Rank", "Reads (Clade)", "Reads (Direct)", "Clade %", "Direct %"],
            ["root", "Root", "300", "0", "75.0000", "0.0000"],
            [quotedName, "Species", "200", "200", "50.0000", "50.0000"],
            ["Plain virus", "Species", "100", "100", "25.0000", "25.0000"],
            ["unclassified", unclassifiedRank, "100", "100", "25.0000", "25.0000"],
        ]
        return rows.map { $0.joined(separator: separator) }.joined(separator: "\n") + "\n"
    }

    // MARK: - BLAST fixture

    /// A read with two hits whose id and organism hold a comma and quotes, a read with no hits and no top-level
    /// fields, and a read with no hits and top-level fields.
    private func blastResult() -> BlastVerificationResult {
        let hits = [
            BlastHitSummary(
                rank: 1, accession: "NC_000001.1", organism: "Escherichia coli, strain \"K-12\"", taxId: 562,
                percentIdentity: 99.5, queryCoverage: 98.25, eValue: 1e-50, bitScore: 250.46, alignmentLength: 150
            ),
            BlastHitSummary(
                rank: 2, accession: "NC_000002.1", organism: nil, taxId: nil,
                percentIdentity: 90, queryCoverage: 80.126, eValue: 0.0, bitScore: 100.04, alignmentLength: 120
            ),
        ]
        return BlastVerificationResult(
            taxonName: "Escherichia coli",
            taxId: 562,
            readResults: [
                BlastReadResult(
                    id: "read,1", verdict: .verified, topHitOrganism: "Escherichia coli", topHitAccession: "NC_000001.1",
                    percentIdentity: 99.5, queryCoverage: 98.25, eValue: 1e-50, alignmentLength: 150, bitScore: 250.46,
                    topHits: hits, hasLCADisagreement: true, matchesQueriedTaxon: true
                ),
                BlastReadResult(id: "read_2", verdict: .unverified),
                BlastReadResult(
                    id: "read_3", verdict: .ambiguous, topHitOrganism: "Shigella", topHitAccession: "NC_000003.1",
                    percentIdentity: 88.126, queryCoverage: 70.5, eValue: 0.002, alignmentLength: 99, bitScore: 55.5
                ),
            ],
            submittedAt: Date(timeIntervalSince1970: 1_790_000_000),
            completedAt: Date(timeIntervalSince1970: 1_790_000_060),
            rid: "PIN-RID",
            blastProgram: "megablast",
            database: "core_nt"
        )
    }

    private func expectedBlastTable(separator: String) -> String {
        func field(_ value: String) -> String {
            guard value.contains(separator) || value.contains("\"") || value.contains("\n") else { return value }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let verified = BlastVerdict.verified.rawValue
        let unverified = BlastVerdict.unverified.rawValue
        let ambiguous = BlastVerdict.ambiguous.rawValue
        let rows: [[String]] = [
            [
                "Read ID", "Verdict", "LCA Flag", "Hit Rank", "Accession", "Organism", "TaxId", "Identity%",
                "Coverage%", "E-value", "Bit Score", "Alignment Length",
            ],
            [
                field("read,1"), verified, "true", "1", "NC_000001.1", field("Escherichia coli, strain \"K-12\""),
                "562", "99.50", "98.25", "1e-50", "250.5", "150",
            ],
            [field("read,1"), verified, "true", "2", "NC_000002.1", "", "", "90.00", "80.13", "0.0", "100.0", "120"],
            ["read_2", unverified, "false", "1", "", "", "", "", "", "", "", ""],
            ["read_3", ambiguous, "false", "1", "NC_000003.1", "Shigella", "", "88.13", "70.50", "0.002", "55.5", "99"],
        ]
        return rows.map { $0.joined(separator: separator) }.joined(separator: "\n") + "\n"
    }
}
