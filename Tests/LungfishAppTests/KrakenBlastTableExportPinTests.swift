// KrakenBlastTableExportPinTests.swift - The Kraken2 taxonomy table and BLAST drawer table exports at their base
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishCore
@testable import LungfishIO
@testable import LungfishKit
import LungfishTestSupport
import LungfishWorkflow

/// Phase 2.12 lane 12.33, M1 (QA 1). Pins the bytes and the record of the taxonomy view's CSV and TSV and of the
/// BLAST drawer's CSV and TSV as the in-app writers leave them at the lane's base, for a quoted field, a read with
/// no hits and a read with hits. The lane converts both exports to `kraken2 export table` and `blast export table`.
/// The bytes stay equal. The record moves to `lungfish-cli` and names what the leaf reads, which the prediction
/// rows of the lane report list (BIO 4, 6 and 7).
@MainActor
final class KrakenBlastTableExportPinTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "kraken-blast-table-pin")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

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

    // MARK: - The BLAST drawer table (census A9)

    func testTheBlastTableBytesAndRecordAtTheBase() throws {
        for (separator, format) in [(",", "csv"), ("\t", "tsv")] {
            let export = try writeBlastTable(separator: separator, fileName: "blast.\(format)")
            let content = try String(contentsOf: export.outputURL, encoding: .utf8)
            XCTAssertEqual(content, expectedBlastTable(separator: separator), format)

            let envelope = export.envelope
            XCTAssertEqual(envelope.toolName, "Lungfish.app", format)
            XCTAssertEqual(envelope.tool.kind, "gui", format)
            XCTAssertEqual(envelope.workflowName, "lungfish app blast verification table export", format)
            XCTAssertEqual(
                envelope.argv,
                [
                    CLICommandIdentity.executableName, "export", "blast-verification-table",
                    "--separator", format, "--output", export.outputURL.path,
                ],
                format
            )
            XCTAssertEqual(envelope.durableReplayArgv ?? envelope.argv, envelope.argv, format)
            XCTAssertTrue(
                envelope.files.filter { $0.role == .input }.isEmpty,
                "\(format): the record names no input at the base (sourceURLs is empty), a BIO 6 prediction row"
            )
            XCTAssertEqual(Set(envelope.options.explicit.keys), ["outputPath", "separator", "taxId", "taxonName"], format)
            XCTAssertEqual(envelope.options.explicit["separator"]?.stringValue, format)
            XCTAssertEqual(envelope.options.explicit["taxonName"]?.stringValue, "Escherichia coli", format)
            XCTAssertEqual(envelope.options.explicit["taxId"]?.integerValue, 562, format)
            XCTAssertTrue(envelope.options.defaults.isEmpty, format)
            XCTAssertEqual(Set(envelope.options.resolvedDefaults.keys), ["outputByteCount", "totalReads"], format)
            XCTAssertEqual(envelope.options.resolvedDefaults["totalReads"]?.integerValue, 3, format)
            XCTAssertEqual(envelope.options.resolvedDefaults["outputByteCount"]?.integerValue, content.utf8.count, format)
        }
    }

    // MARK: - The recorded commands parse (QA 1)

    /// A recorded command must parse through the real CLI parser (`CLI-EQUIVALENCE.md`, rule 5).
    /// `export blast-verification-table` has no leaf at the base, so the parse fails there. The expectation keeps this
    /// pin green at its base and goes in the commit that adds the leaf. The taxonomy table's recorded command is
    /// parsed by TaxonomyTableExportRowTests and the parity class since `kraken2 export table` exists.
    func testTheBlastTableRecordsACommandThatParses() throws {
        let argv = try writeBlastTable(separator: ",", fileName: "blast.csv").envelope.argv
        try XCTExpectFailure("export blast-verification-table has no leaf at the base. The blast export table commit removes this") {
            XCTAssertNoThrow(try RecordedCLICommand.parse(Self.command(of: argv)), "recorded: \(argv.joined(separator: " "))")
        }
    }

    /// The command the Operations row would hold for a recorded argv.
    private static func command(of argv: [String]) -> String {
        OperationCenter.buildCLICommand(subcommand: argv[1], args: Array(argv.dropFirst(2)))
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

    private struct BlastExport {
        let outputURL: URL
        let envelope: ProvenanceEnvelope
    }

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

    private func writeBlastTable(separator: String, fileName: String) throws -> BlastExport {
        let tab = BlastResultsDrawerTab(frame: .zero)
        let outputURL = scratch.appendingPathComponent(fileName)
        tab.writeExportFile(result: blastResult(), to: outputURL, separator: separator)
        return BlastExport(outputURL: outputURL, envelope: try envelope(of: outputURL))
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

    // MARK: - Shared

    private func envelope(of outputURL: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL)))
    }
}
