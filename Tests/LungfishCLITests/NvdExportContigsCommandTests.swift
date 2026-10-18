// NvdExportContigsCommandTests.swift - lungfish-cli nvd export contigs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.31 M4. BIO ruling on 12.31 M4 (M4-2, M4-3), ARCH ruling G2 section 5. The leaf applies the
// viewer's sample selection and search, writes the viewer pin's bytes with each row's own sample's metadata, names
// only the files it read and never the run folder, and parses the arguments the app's begin helper builds.

import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

final class NvdExportContigsCommandTests: XCTestCase {
    private var folder: URL!
    private var resultFolder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NvdExportContigs-\(UUID().uuidString)", isDirectory: true)
        resultFolder = folder.appendingPathComponent("nvd-result", isDirectory: true)
        let metadataFolder = resultFolder.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataFolder, withIntermediateDirectories: true)
        // The run folder the import read sits in the result folder, and the record must never name it (M4-3).
        let runFolder = resultFolder.appendingPathComponent("nvd-run", isDirectory: true)
        try FileManager.default.createDirectory(at: runFolder, withIntermediateDirectories: true)
        try Data("run\n".utf8).write(to: runFolder.appendingPathComponent("blast_concatenated.csv"))
        let samples = ["sample1", "sample2", "sample3"]
        try NvdDatabase.create(
            at: resultFolder.appendingPathComponent("hits.sqlite"),
            hits: [
                Self.hit(sample: "sample1", contig: "contig_1", name: "Alpha virus", reads: 30),
                Self.hit(sample: "sample1", contig: "contig_2", name: "Beta phage", reads: 50),
                Self.hit(sample: "sample2", contig: "contig_1", name: "Gamma virus", reads: 20),
                Self.hit(sample: "sample3", contig: "contig_1", name: "Alpha virus", reads: 40),
            ],
            samples: samples.map {
                NvdSampleMetadata(
                    sampleId: $0, bamPath: "\($0).bam", fastaPath: "\($0).fasta",
                    totalReads: 1000, contigCount: 1, hitCount: 1
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(NvdManifest(
            experiment: "exp-leaf", sampleCount: 3, contigCount: 4, hitCount: 4, blastDbVersion: "db",
            snakemakeRunId: "run-1", sourceDirectoryPath: runFolder.path,
            samples: samples.map {
                NvdSampleSummary(
                    sampleId: $0, contigCount: 1, hitCount: 1, totalReads: 1000,
                    bamRelativePath: "\($0).bam", fastaRelativePath: "\($0).fasta"
                )
            },
            cachedTopContigs: nil
        )).write(to: resultFolder.appendingPathComponent("manifest.json"))
        try Data("Sample\tCohort\nsample1\tcase\nsample2\tcontrol\nsample3\tcase\n".utf8)
            .write(to: metadataFolder.appendingPathComponent("sample_metadata.tsv"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private static func hit(sample: String, contig: String, name: String, reads: Int) -> NvdBlastHit {
        NvdBlastHit(
            experiment: "exp-leaf", blastTask: "blastn", sampleId: sample, qseqid: contig, qlen: 8,
            sseqid: "NC_\(sample)_\(contig)", stitle: name, taxRank: "species", length: 8, pident: 100, evalue: 0,
            bitscore: 50, sscinames: name, staxids: "1234", blastDbVersion: "db", snakemakeRunId: "run-1",
            mappedReads: reads, totalReads: 1000, statDbVersion: "stats-1", adjustedTaxid: "1234",
            adjustmentMethod: "dominant", adjustedTaxidName: name, adjustedTaxidRank: "species", hitRank: 1,
            readsPerBillion: Double(reads) * 1_000_000
        )
    }

    private func command(_ arguments: [String]) throws -> NvdCommand.ExportContigsSubcommand {
        let parsed = try LungfishCLI.parseAsRoot(arguments)
        return try XCTUnwrap(parsed as? NvdCommand.ExportContigsSubcommand)
    }

    private func leafArguments(output: URL, extra: [String] = []) -> [String] {
        ["nvd", "export", "contigs", resultFolder.path] + extra + ["--output", output.path]
    }

    /// The state the viewer pin sets. Samples 1 and 2, the search `virus` and `Cohort` shown.
    private let viewState = [
        "--sample", "sample1", "--sample", "sample2", "--search", "virus", "--metadata-column", "Cohort",
    ]

    private static func envelope(of outputURL: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL)))
    }

    private static func inputNames(of outputURL: URL) throws -> [String] {
        try envelope(of: outputURL).files.filter { $0.role == .input }
            .map { URL(fileURLWithPath: $0.path).lastPathComponent }.sorted()
    }

    /// The bytes of `NvdContigsExportPinTests.testBytesHoldTheShownContigsInDatabaseOrder`.
    func testWritesTheViewerPinsBytes() throws {
        let output = folder.appendingPathComponent("rows.tsv")
        _ = try command(leafArguments(output: output, extra: viewState)).export()
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), [
            "sample_id\tcontig\tlength\tclassification\trank\taccession\tsubject\tpident\tevalue\tbitscore\tmapped_reads\treads_per_billion\tCohort",
            "sample1\tcontig_1\t8\tAlpha virus\tspecies\tNC_sample1_contig_1\tAlpha virus\t100.00\t0.0\t50.0\t30\t30000000\tcase",
            "sample2\tcontig_1\t8\tGamma virus\tspecies\tNC_sample2_contig_1\tGamma virus\t100.00\t0.0\t50.0\t20\t20000000\tcontrol",
        ].joined(separator: "\n") + "\n")
    }

    func testRecordNamesTheLeafItsArgvAndTheAppliedState() throws {
        let output = folder.appendingPathComponent("record.tsv")
        let arguments = leafArguments(output: output, extra: viewState)
        _ = try command(arguments).export()
        let envelope = try Self.envelope(of: output)
        XCTAssertEqual(envelope.tool.name, "lungfish-cli")
        XCTAssertEqual(envelope.tool.kind, "cli")
        XCTAssertEqual(envelope.workflowName, "lungfish nvd export contigs")
        XCTAssertEqual(envelope.argv, ["lungfish-cli"] + arguments)
        XCTAssertEqual(envelope.durableReplayArgv, envelope.argv)
        let resolved = envelope.options.resolvedDefaults
        XCTAssertEqual(resolved.keys.sorted(), [
            "experiment", "metadataColumns", "rowCount", "searchQuery", "selectedSamples", "sourceSampleCount",
        ])
        XCTAssertEqual(resolved["rowCount"]?.integerValue, 2)
        XCTAssertEqual(resolved["experiment"]?.stringValue, "exp-leaf")
        XCTAssertEqual(resolved["sourceSampleCount"]?.integerValue, 3)
        XCTAssertEqual(resolved["selectedSamples"]?.arrayValue?.compactMap(\.stringValue), ["sample1", "sample2"])
        XCTAssertEqual(resolved["searchQuery"]?.stringValue, "virus")
        XCTAssertEqual(resolved["metadataColumns"]?.arrayValue?.compactMap(\.stringValue), ["Cohort"])
        XCTAssertEqual(envelope.options.explicit.keys.sorted(), ["metadataColumns", "outputPath", "samples", "searchText"])
    }

    /// BIO ruling on 12.31 M4. The record names the database, the manifest and the metadata files that exist, the
    /// journal only when present, neither metadata file without --metadata-column, and never the run folder.
    func testInputsAreTheDatabaseManifestAndMetadata() throws {
        let shown = folder.appendingPathComponent("shown.tsv")
        _ = try command(leafArguments(output: shown, extra: ["--metadata-column", "Cohort"])).export()
        XCTAssertEqual(try Self.inputNames(of: shown), ["hits.sqlite", "manifest.json", "sample_metadata.tsv"])
        XCTAssertTrue(try Self.envelope(of: shown).files.filter { $0.role == .input }.allSatisfy { $0.checksumSHA256 != nil })

        try Data("[]".utf8).write(to: resultFolder.appendingPathComponent("metadata/sample_metadata_edits.json"))
        let journal = folder.appendingPathComponent("journal.tsv")
        _ = try command(leafArguments(output: journal, extra: ["--metadata-column", "Cohort"])).export()
        XCTAssertEqual(
            try Self.inputNames(of: journal),
            ["hits.sqlite", "manifest.json", "sample_metadata.tsv", "sample_metadata_edits.json"]
        )

        let hidden = folder.appendingPathComponent("hidden.tsv")
        _ = try command(leafArguments(output: hidden)).export()
        XCTAssertEqual(try Self.inputNames(of: hidden), ["hits.sqlite", "manifest.json"])
        XCTAssertEqual(
            try Self.envelope(of: hidden).options.resolvedDefaults["selectedSamples"]?.arrayValue?.compactMap(\.stringValue),
            ["sample1", "sample2", "sample3"],
            "no --sample exports every sample"
        )
    }

    func testRefusesBeforeWriting() throws {
        let existing = folder.appendingPathComponent("exists.tsv")
        try Data("keep".utf8).write(to: existing)
        XCTAssertThrowsError(try command(leafArguments(output: existing)).export()) { error in
            XCTAssertTrue(error is ViewerExportRefusal, "\(error)")
        }
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep")
        _ = try command(leafArguments(output: existing, extra: ["--force"])).export()
        XCTAssertNotEqual(try String(contentsOf: existing, encoding: .utf8), "keep")

        try assertRefusedBeforeWriting(extra: ["--sample", "sample9"])
        try assertRefusedBeforeWriting(extra: ["--metadata-column", "Nope"])
        let database = resultFolder.appendingPathComponent("hits.sqlite")
        let before = try Data(contentsOf: database)
        XCTAssertThrowsError(try command(leafArguments(output: database, extra: ["--force"])).export()) { error in
            XCTAssertTrue(error is ViewerExportRefusal, "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: database), before)
        try FileManager.default.removeItem(at: resultFolder.appendingPathComponent("metadata/sample_metadata.tsv"))
        try assertRefusedBeforeWriting(extra: ["--metadata-column", "Cohort"])
        try FileManager.default.removeItem(at: database)
        try assertRefusedBeforeWriting(extra: [])
    }

    private func assertRefusedBeforeWriting(extra: [String], line: UInt = #line) throws {
        let output = folder.appendingPathComponent("refused.tsv")
        XCTAssertThrowsError(try command(leafArguments(output: output, extra: extra)).export(), line: line) { error in
            XCTAssertTrue(error is ViewerExportRefusal, "\(error)", line: line)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path), line: line)
    }

    /// ARCH ruling G2 section 5. The arguments the begin helper builds parse through the root into the leaf, whose
    /// canonical argv is the executable name and the same array.
    func testNvdContigsLeafParsesTheGUIArguments() throws {
        let invocation = NvdContigsExport.invocation(
            resultURL: resultFolder,
            state: ViewerTableExportState(
                samples: ["sample1", "sample2"], searchText: "virus", metadataColumns: ["Cohort"]
            ),
            outputURL: folder.appendingPathComponent("gui.tsv"),
            force: true
        )
        let arguments = invocation.arguments()
        let leaf = try command(arguments)
        XCTAssertEqual(try leaf.invocation(), invocation)
        XCTAssertEqual(try leaf.invocation().canonicalArgv(), [CLICommandIdentity.executableName] + arguments)
        XCTAssertEqual(Array(arguments.prefix(3)), NvdContigsExport.commandPath)
        XCTAssertEqual(NvdCommand.ExportContigsSubcommand.configuration.commandName, NvdContigsExport.commandPath.last)
    }

    func testNvdContigsLeafRefusesAnOptionItDoesNotTake() {
        let output = folder.appendingPathComponent("refuse.tsv")
        XCTAssertThrowsError(try command(leafArguments(output: output, extra: ["--sort", "mappedReads:ascending"])))
        XCTAssertThrowsError(try command(leafArguments(output: output, extra: ["--filter", "x"])))
        XCTAssertThrowsError(try command(leafArguments(output: output, extra: ["--output-format", "tsv"])))
    }
}
