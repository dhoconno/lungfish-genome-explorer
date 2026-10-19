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

    func testTheTaxonomyTableBytesAndRecordAtTheBase() throws {
        for (separator, format) in [(",", "csv"), ("\t", "tsv")] {
            let export = try writeTaxonomyTable(separator: separator, fileName: "table.\(format)")
            let content = try String(contentsOf: export.outputURL, encoding: .utf8)
            XCTAssertEqual(content, expectedTaxonomyTable(separator: separator, tree: export.tree), format)

            let envelope = export.envelope
            XCTAssertEqual(envelope.toolName, "Lungfish.app", format)
            XCTAssertEqual(envelope.tool.kind, "gui", format)
            XCTAssertEqual(envelope.workflowName, "lungfish app taxonomy table export", format)
            XCTAssertEqual(
                envelope.argv,
                [CLICommandIdentity.executableName, "export", "taxonomy-table", "--separator", format, "--output", export.outputURL.path],
                format
            )
            XCTAssertEqual(envelope.durableReplayArgv ?? envelope.argv, envelope.argv, format)
            XCTAssertEqual(
                Set(envelope.files.filter { $0.role == .input }.map(\.path)),
                Set(export.inputs.map(\.path)),
                "\(format): the record names the sidecar and the kreport the shown tree came from, never config.inputFiles"
            )
            XCTAssertEqual(Set(envelope.options.explicit.keys), ["outputPath", "separator", "sourcePaths"], format)
            XCTAssertEqual(envelope.options.explicit["separator"]?.stringValue, format)
            XCTAssertEqual(envelope.options.defaults["outputFormat"]?.stringValue, format)
            XCTAssertEqual(
                Set(envelope.options.resolvedDefaults.keys), ["nodeCount", "outputByteCount", "selectedSamples"], format
            )
            XCTAssertEqual(
                envelope.options.resolvedDefaults["selectedSamples"]?.arrayValue?.compactMap(\.stringValue),
                ["reads_1"],
                "\(format): the one sample id of a sidecar result"
            )
            XCTAssertEqual(envelope.options.resolvedDefaults["nodeCount"]?.integerValue, export.tree.allNodes().count, format)
            XCTAssertEqual(envelope.options.resolvedDefaults["outputByteCount"]?.integerValue, content.utf8.count, format)
        }
    }

    // MARK: - The database route (ARCH ruling on F1, C2 and C3)

    /// A folder with a Kraken2 database of two samples and a sample metadata table that gives them different groups,
    /// shown as the sidebar shows it (`configureFromDatabase`, every sample picked) with the `Group` column visible.
    private func makeDatabaseView() throws -> (view: TaxonomyViewController, folder: URL) {
        let folder = scratch.appendingPathComponent("kraken2-batch", isDirectory: true)
        let metadata = folder.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        var rows: [Kraken2ClassificationRow] = []
        for (sample, name, reads) in [("sample-A", "Virus A", 40), ("sample-B", "Virus B", 20)] {
            rows.append(Kraken2ClassificationRow(
                sample: sample, taxonName: "root", taxId: 1, rank: "R", rankDisplayName: "Root",
                readsDirect: 0, readsClade: reads, percentage: 100, parentTaxId: nil, depth: 0
            ))
            rows.append(Kraken2ClassificationRow(
                sample: sample, taxonName: name, taxId: reads, rank: "S", rankDisplayName: "Species",
                readsDirect: reads, readsClade: reads, percentage: 100, parentTaxId: 1, depth: 1
            ))
        }
        let database = try Kraken2Database.create(
            at: folder.appendingPathComponent("kraken2.sqlite"),
            rows: rows,
            metadata: ["total_reads_sample-A": "40", "total_reads_sample-B": "20"]
        )
        try Data("Sample\tGroup\nsample-A\tcase\nsample-B\tcontrol\n".utf8)
            .write(to: metadata.appendingPathComponent("sample_metadata.tsv"))
        let view = TaxonomyViewController()
        _ = view.view
        view.configureFromDatabase(database)
        view.applySampleMetadata(SampleMetadataStore.load(from: folder, knownSampleIds: ["sample-A", "sample-B"]))
        view.testTableView.metadataColumns.persistenceKey = nil
        view.testTableView.metadataColumns.visibleColumns = ["Group"]
        XCTAssertEqual(view.testTableView.metadataColumns.exportHeaders, ["Group"])
        return (view, folder)
    }

    /// The database route (every batch and every indexed result) has no `classificationResult`, so the base record
    /// names no input and no sample. It names the database the tree came from, the metadata table behind the shown
    /// column, and the samples whose trees the table holds.
    func testTheDatabaseRouteRecordNamesTheDatabaseTheMetadataAndTheSamples() throws {
        let shown = try makeDatabaseView()
        let outputURL = scratch.appendingPathComponent("database.tsv")
        try shown.view.writeDelimitedExport(tree: try XCTUnwrap(shown.view.tree), separator: "\t", to: outputURL)
        let envelope = try envelope(of: outputURL)
        XCTAssertEqual(
            Set(envelope.files.filter { $0.role == .input }.map(\.path)),
            [
                shown.folder.appendingPathComponent("kraken2.sqlite").path,
                shown.folder.appendingPathComponent("metadata/sample_metadata.tsv").path,
            ],
            "the database the tree came from and the metadata table the shown column came from"
        )
        XCTAssertEqual(
            envelope.options.resolvedDefaults["selectedSamples"]?.arrayValue?.compactMap(\.stringValue),
            ["sample-A", "sample-B"]
        )
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

    /// A recorded command must parse through the real CLI parser (`CLI-EQUIVALENCE.md`, rule 5). Neither
    /// `export taxonomy-table` nor `export blast-verification-table` has a leaf at the base, so both parses fail
    /// there (`build/lane/m1-base.log` in the lane's worktree holds the failures). The expectation keeps this pin
    /// green at its base and goes in the commit that adds the leaf, which turns the parse green and makes the
    /// strict expectation fail until it is removed.
    func testTheTaxonomyTableRecordsACommandThatParses() throws {
        let argv = try writeTaxonomyTable(separator: ",", fileName: "table.csv").envelope.argv
        try XCTExpectFailure("export taxonomy-table has no leaf at the base. The kraken2 export table commit removes this") {
            XCTAssertNoThrow(try RecordedCLICommand.parse(Self.command(of: argv)), "recorded: \(argv.joined(separator: " "))")
        }
    }

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

    private struct TaxonomyExport {
        let outputURL: URL
        let envelope: ProvenanceEnvelope
        let inputs: [URL]
        let tree: TaxonTree
    }

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

    private func writeTaxonomyTable(separator: String, fileName: String) throws -> TaxonomyExport {
        let fastqs = ["reads_1.fastq", "reads_2.fastq"].map { scratch.appendingPathComponent($0) }
        for input in fastqs {
            try "@r1\nACGT\n+\n!!!!\n".write(to: input, atomically: true, encoding: .utf8)
        }
        let tree = taxonomyTree()
        let config = ClassificationConfig(
            inputFiles: fastqs,
            isPairedEnd: true,
            databaseName: "pin-db",
            databasePath: scratch.appendingPathComponent("db"),
            outputDirectory: scratch
        )
        let result = ClassificationResult(
            config: config,
            tree: tree,
            reportURL: scratch.appendingPathComponent("classification.kreport"),
            outputURL: scratch.appendingPathComponent("classification.kraken"),
            brackenURL: nil,
            runtime: 1,
            toolVersion: "2.1.3",
            provenanceId: nil
        )
        // The sidecar and the kreport are the files the shown tree comes from (ARCH ruling on F1, C2).
        try "100.00\t300\t0\tR\t1\troot\n".write(to: result.reportURL, atomically: true, encoding: .utf8)
        try result.save(to: scratch)
        let inputs = [scratch.appendingPathComponent(ClassificationResult.sidecarFilename), result.reportURL]
        let controller = TaxonomyViewController()
        _ = controller.view
        controller.configure(result: result)
        let outputURL = scratch.appendingPathComponent(fileName)
        try controller.writeDelimitedExport(tree: tree, separator: separator, to: outputURL)
        return TaxonomyExport(outputURL: outputURL, envelope: try envelope(of: outputURL), inputs: inputs, tree: tree)
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
