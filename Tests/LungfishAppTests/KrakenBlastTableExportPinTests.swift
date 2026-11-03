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
@testable import LungfishTaxonomyUI

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

    /// Ruling BIO-VERIFIED-EXPORT. Verdict says only that an alignment passed the thresholds, so a read that contradicts
    /// the row reads `verified`. Taxon Check says what the read means for the row, by the rule of the counts behind the
    /// badge. Each read ID carries one word, and the read IDs per word equal the result's counts.
    func testTaxonCheckColumnMatchesTheCountsBehindTheBadge() throws {
        let result = taxonCheckResult()
        XCTAssertEqual(
            [result.supportingCount, result.contradictingCount, result.inconclusiveCount], [1, 2, 5], "the fixture's counts"
        )
        let table = BlastVerificationTableExport.tableContent(result: result, separator: "\t")
            .split(separator: "\n")
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        let header = try XCTUnwrap(table.first)
        XCTAssertEqual(Array(header.suffix(2)), ["Queried Taxon", "Taxon Check"])
        let verdictColumn = try XCTUnwrap(header.firstIndex(of: "Verdict"))
        let taxonColumn = try XCTUnwrap(header.firstIndex(of: "Queried Taxon"))
        let checkColumn = try XCTUnwrap(header.firstIndex(of: "Taxon Check"))
        let rows = Array(table.dropFirst())
        XCTAssertTrue(rows.allSatisfy { $0.count == header.count }, "every row holds every column")
        XCTAssertEqual(Set(rows.map { $0[taxonColumn] }), [result.taxonName])

        let contradicting = rows.filter { $0[0] == "read_contradicting" }
        XCTAssertEqual(contradicting.count, 2, "one row per hit")
        for row in contradicting {
            XCTAssertEqual(row[verdictColumn], "verified")
            XCTAssertEqual(row[checkColumn], "contradicting")
        }

        let wordsByRead = Dictionary(grouping: rows) { $0[0] }.mapValues { Set($0.map { $0[checkColumn] }) }
        XCTAssertEqual(wordsByRead, [
            "read_supporting": ["supporting"],
            "read_contradicting": ["contradicting"],
            "pair_conflicting": ["inconclusive"],
            "pair_one_mate_no_hit": ["contradicting"],
            "read_no_hit": ["inconclusive"],
            "read_ambiguous_in_clade": ["inconclusive"],
            "read_error": ["inconclusive"],
            "pair_no_hit": ["inconclusive"],
        ])
        func readCount(_ word: String) -> Int { wordsByRead.values.filter { $0 == [word] }.count }
        XCTAssertEqual(readCount("supporting"), result.supportingCount)
        XCTAssertEqual(readCount("contradicting"), result.contradictingCount)
        XCTAssertEqual(readCount("inconclusive"), result.inconclusiveCount)

        func verdicts(_ id: String) -> [String] { rows.filter { $0[0] == id }.map { $0[verdictColumn] } }
        XCTAssertEqual(verdicts("pair_conflicting"), ["ambiguous", "verified"], "both mates, deciding mate first")
        XCTAssertEqual(verdicts("pair_one_mate_no_hit"), ["verified", "unverified"], "both mates, deciding mate first")

        let csvLines = BlastVerificationTableExport.tableContent(result: result, separator: ",").split(separator: "\n")
        XCTAssertTrue(csvLines[1].hasSuffix(",\"\(result.taxonName)\",supporting"), "the quoted taxon, \(csvLines[1])")
    }

    /// One supporting read, one contradicting read, one pair with conflicting mates, one pair whose second mate has no
    /// hit (the shape of the walk's row10b-hiv.tsv) and one read with no hit. Then three kinds the counts call
    /// inconclusive whatever their match says: an ambiguous read in the clade, an error and a pair with no hit on either
    /// mate. A taxon name with a comma tests the quoting.
    private func taxonCheckResult() -> BlastVerificationResult {
        func hit(_ accession: String, rank: Int = 1) -> BlastHitSummary {
            BlastHitSummary(
                rank: rank, accession: accession, organism: "Organism of \(accession)", taxId: nil,
                percentIdentity: 99, queryCoverage: 98, eValue: 1e-40, bitScore: 200, alignmentLength: 150
            )
        }
        return BlastVerificationResult(
            taxonName: "Human immunodeficiency virus 1, group M",
            taxId: 11676,
            readResults: [
                BlastReadResult(id: "read_supporting", verdict: .verified, topHits: [hit("SUPPORT.1")], matchesQueriedTaxon: true),
                BlastReadResult(
                    id: "read_contradicting", verdict: .verified, topHits: [hit("VECTOR.1"), hit("VECTOR.2", rank: 2)]
                ),
                // `BlastService.fragmentRows`: mates that disagree on the taxon make the fragment ambiguous, and the
                // other mate keeps its own verdict.
                BlastReadResult(
                    id: "pair_conflicting", verdict: .ambiguous, topHits: [hit("SUPPORT.2")], hasLCADisagreement: true,
                    otherMates: [BlastReadResult(id: "pair_conflicting", verdict: .verified, topHits: [hit("VECTOR.3")])]
                ),
                BlastReadResult(
                    id: "pair_one_mate_no_hit", verdict: .verified, topHits: [hit("VECTOR.4")],
                    otherMates: [BlastReadResult(id: "pair_one_mate_no_hit", verdict: .unverified)]
                ),
                BlastReadResult(id: "read_no_hit", verdict: .unverified),
                // `assignVerdict` sets the match from the top hit whatever the verdict, so a read below the thresholds
                // can sit in the clade.
                BlastReadResult(id: "read_ambiguous_in_clade", verdict: .ambiguous, topHits: [hit("SUPPORT.3")], matchesQueriedTaxon: true),
                // A query NCBI returned no usable entry for.
                BlastReadResult(id: "read_error", verdict: .error, errorMessage: "NCBI returned no result for this read"),
                // `BlastService.fragmentRows`: a no-hit mate decides only when no mate has a hit.
                BlastReadResult(
                    id: "pair_no_hit", verdict: .unverified,
                    otherMates: [BlastReadResult(id: "pair_no_hit", verdict: .unverified)]
                ),
            ],
            submittedAt: Date(timeIntervalSince1970: 1_790_000_000),
            completedAt: Date(timeIntervalSince1970: 1_790_000_060),
            rid: "PIN-RID",
            blastProgram: "megablast",
            database: "core_nt"
        )
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
        let taxon = "Escherichia coli"
        let rows: [[String]] = [
            [
                "Read ID", "Verdict", "LCA Flag", "Hit Rank", "Accession", "Organism", "TaxId", "Identity%",
                "Coverage%", "E-value", "Bit Score", "Alignment Length", "Queried Taxon", "Taxon Check",
            ],
            [
                field("read,1"), verified, "true", "1", "NC_000001.1", field("Escherichia coli, strain \"K-12\""),
                "562", "99.50", "98.25", "1e-50", "250.5", "150", taxon, "supporting",
            ],
            [
                field("read,1"), verified, "true", "2", "NC_000002.1", "", "", "90.00", "80.13", "0.0", "100.0", "120",
                taxon, "supporting",
            ],
            ["read_2", unverified, "false", "1", "", "", "", "", "", "", "", "", taxon, "inconclusive"],
            [
                "read_3", ambiguous, "false", "1", "NC_000003.1", "Shigella", "", "88.13", "70.50", "0.002", "55.5", "99",
                taxon, "inconclusive",
            ],
        ]
        return rows.map { $0.joined(separator: separator) }.joined(separator: "\n") + "\n"
    }
}
