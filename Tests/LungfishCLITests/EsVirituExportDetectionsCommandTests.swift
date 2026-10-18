// EsVirituExportDetectionsCommandTests.swift - lungfish-cli esviritu export detections
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.31 M3. BIO ruling on 12.31 G1 (G1-4) and G3, ARCH ruling G2 section 5. The leaf writes each
// row with its own sample's metadata, cuts the rows to --sample, names only the files it read, and parses the
// arguments the app's begin helper builds.

import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class EsVirituExportDetectionsCommandTests: XCTestCase {
    private var folder: URL!
    private var resultFolder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("EsVirituExportDetections-\(UUID().uuidString)", isDirectory: true)
        resultFolder = folder.appendingPathComponent("esviritu-batch", isDirectory: true)
        let metadataFolder = resultFolder.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataFolder, withIntermediateDirectories: true)
        try EsVirituDatabase.create(
            at: resultFolder.appendingPathComponent("esviritu.sqlite"),
            rows: [Self.row(sample: "sample-A", accession: "NC_A", reads: 40), Self.row(sample: "sample-B", accession: "NC_B", reads: 20)],
            metadata: ["tool": "test"]
        )
        try Data("Sample\tGroup\nsample-A\tcase\nsample-B\tcontrol\n".utf8)
            .write(to: metadataFolder.appendingPathComponent("sample_metadata.tsv"))
        try Data("{}".utf8).write(to: resultFolder.appendingPathComponent(EsVirituBatchAggregatedManifest.filename))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private static func row(sample: String, accession: String, reads: Int) -> EsVirituDetectionRow {
        EsVirituDetectionRow(
            sample: sample, virusName: "Virus \(accession)", description: nil, contigLength: 100, segment: nil,
            accession: accession, assembly: "GCF_\(accession)", assemblyLength: 100, kingdom: "Viruses",
            phylum: nil, tclass: nil, torder: nil, family: "Testviridae", genus: nil, species: nil, subspecies: nil,
            rpkmf: 1, readCount: reads, uniqueReads: reads, coveredBases: 90, meanCoverage: 2,
            avgReadIdentity: 99, pi: 0, filteredReadsInSample: 1_000, bamPath: nil, bamIndexPath: nil
        )
    }

    private func command(_ arguments: [String]) throws -> EsVirituCommand.ExportDetectionsSubcommand {
        let parsed = try LungfishCLI.parseAsRoot(arguments)
        return try XCTUnwrap(parsed as? EsVirituCommand.ExportDetectionsSubcommand)
    }

    private func leafArguments(output: URL, extra: [String] = []) -> [String] {
        ["esviritu", "export", "detections", resultFolder.path] + extra
            + ["--output-format", "tsv", "--output", output.path]
    }

    private static func envelope(of outputURL: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL)))
    }

    func testEachRowCarriesItsOwnSampleMetadata() throws {
        let output = folder.appendingPathComponent("rows.tsv")
        _ = try command(leafArguments(output: output, extra: ["--metadata-column", "Group"])).export()
        let lines = try String(contentsOf: output, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        let fieldCount = lines[0].split(separator: "\t", omittingEmptySubsequences: false).count
        XCTAssertEqual(fieldCount, 23)
        for line in lines {
            XCTAssertEqual(line.split(separator: "\t", omittingEmptySubsequences: false).count, fieldCount)
        }
        XCTAssertTrue(lines[1].hasPrefix("sample-A\t"))
        XCTAssertTrue(lines[1].hasSuffix("\tcase"))
        XCTAssertTrue(lines[2].hasPrefix("sample-B\t"))
        XCTAssertTrue(lines[2].hasSuffix("\tcontrol"))
    }

    func testSampleOptionCutsTheRows() throws {
        let output = folder.appendingPathComponent("one.tsv")
        _ = try command(leafArguments(output: output, extra: ["--sample", "sample-A"])).export()
        let lines = try String(contentsOf: output, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].hasPrefix("sample-A\t"))
        let resolved = try Self.envelope(of: output).options.resolvedDefaults
        XCTAssertEqual(resolved["rowCount"]?.integerValue, 1)
        XCTAssertEqual(resolved["selectedSamples"]?.arrayValue?.compactMap(\.stringValue), ["sample-A"])
        XCTAssertEqual(resolved["sampleId"]?.stringValue, "sample-A")
        XCTAssertEqual(resolved["sourceSampleCount"]?.integerValue, 2)
        XCTAssertEqual(resolved.keys.sorted(), [
            "metadataColumns", "rowCount", "sampleId", "selectedSamples", "sourceSampleCount", "tableMode",
        ])
    }

    /// The record names the database and the metadata files it read, the journal only when it exists, never the
    /// batch manifest (G3), and no metadata file without --metadata-column.
    func testMetadataFilesAreInputs() throws {
        func inputNames(_ output: URL) throws -> [String] {
            try Self.envelope(of: output).files.filter { $0.role == .input }
                .map { URL(fileURLWithPath: $0.path).lastPathComponent }.sorted()
        }
        let shown = folder.appendingPathComponent("shown.tsv")
        _ = try command(leafArguments(output: shown, extra: ["--metadata-column", "Group"])).export()
        XCTAssertEqual(try inputNames(shown), ["esviritu.sqlite", "sample_metadata.tsv"])
        XCTAssertTrue(try Self.envelope(of: shown).files.filter { $0.role == .input }.allSatisfy { $0.checksumSHA256 != nil })

        try Data("[]".utf8).write(to: resultFolder.appendingPathComponent("metadata/sample_metadata_edits.json"))
        let journal = folder.appendingPathComponent("journal.tsv")
        _ = try command(leafArguments(output: journal, extra: ["--metadata-column", "Group"])).export()
        XCTAssertEqual(try inputNames(journal), ["esviritu.sqlite", "sample_metadata.tsv", "sample_metadata_edits.json"])

        let hidden = folder.appendingPathComponent("hidden.tsv")
        _ = try command(leafArguments(output: hidden)).export()
        XCTAssertEqual(try inputNames(hidden), ["esviritu.sqlite"])
    }

    func testRecordNamesTheLeafAndItsCanonicalArgv() throws {
        let output = folder.appendingPathComponent("record.csv")
        let arguments = ["esviritu", "export", "detections", resultFolder.path, "--output-format", "csv", "--output", output.path]
        _ = try command(arguments).export()
        let envelope = try Self.envelope(of: output)
        XCTAssertEqual(envelope.tool.name, "lungfish-cli")
        XCTAssertEqual(envelope.tool.kind, "cli")
        XCTAssertEqual(envelope.workflowName, "lungfish esviritu export detections")
        XCTAssertEqual(envelope.argv, ["lungfish-cli"] + arguments)
        XCTAssertEqual(envelope.durableReplayArgv, envelope.argv)
    }

    func testRefusesAnExistingOutputAndAnUnknownSampleBeforeWriting() throws {
        let output = folder.appendingPathComponent("exists.tsv")
        try Data("keep".utf8).write(to: output)
        XCTAssertThrowsError(try command(leafArguments(output: output)).export()) { error in
            XCTAssertTrue(error is ViewerExportRefusal)
        }
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "keep")
        _ = try command(leafArguments(output: output, extra: ["--force"])).export()
        XCTAssertNotEqual(try String(contentsOf: output, encoding: .utf8), "keep")

        let unknown = folder.appendingPathComponent("unknown.tsv")
        XCTAssertThrowsError(try command(leafArguments(output: unknown, extra: ["--sample", "sample-Z"])).export()) { error in
            XCTAssertTrue(error is ViewerExportRefusal)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: unknown.path))
    }

    /// ARCH ruling G2 section 5. The arguments the begin helper builds parse through the root into the leaf, whose
    /// canonical argv is the executable name and the same array.
    func testEsVirituDetectionsLeafParsesTheGUIArguments() throws {
        let invocation = EsVirituDetectionExport.invocation(
            resultURL: resultFolder,
            samples: ["sample-A", "sample-B"],
            metadataColumns: ["Group"],
            format: .csv,
            outputURL: folder.appendingPathComponent("gui.csv"),
            force: true
        )
        let arguments = invocation.arguments()
        let leaf = try command(arguments)
        XCTAssertEqual(try leaf.invocation(), invocation)
        XCTAssertEqual(try leaf.invocation().canonicalArgv(), [CLICommandIdentity.executableName] + arguments)
        XCTAssertEqual(Array(arguments.prefix(3)), EsVirituDetectionExport.commandPath)
        XCTAssertEqual(EsVirituCommand.ExportDetectionsSubcommand.configuration.commandName, EsVirituDetectionExport.commandPath.last)
    }

    func testEsVirituDetectionsLeafRefusesAnOptionItDoesNotTake() {
        let output = folder.appendingPathComponent("refuse.tsv")
        XCTAssertThrowsError(try command(leafArguments(output: output, extra: ["--search", "beta"])))
        XCTAssertThrowsError(try command(leafArguments(output: output, extra: ["--sort", "name:ascending"])))
    }
}
