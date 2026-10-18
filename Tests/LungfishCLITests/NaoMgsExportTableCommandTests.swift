// NaoMgsExportTableCommandTests.swift - lungfish-cli nao-mgs export table
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.31 M4. BIO ruling on 12.31 M4 (M4-2, M4-3), ARCH ruling G2 section 5. The leaf applies the
// viewer's sample selection, search, column filters and first sort key, writes each row with its own sample's
// metadata, names only the files it read, and parses the arguments the app's begin helper builds.

import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

final class NaoMgsExportTableCommandTests: XCTestCase {
    private var folder: URL!
    private var resultFolder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NaoMgsExportTable-\(UUID().uuidString)", isDirectory: true)
        resultFolder = folder.appendingPathComponent("naomgs-result", isDirectory: true)
        let metadataFolder = resultFolder.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataFolder, withIntermediateDirectories: true)
        // The import's source file sits in the result folder, and the record must never name it (M4-2).
        let source = resultFolder.appendingPathComponent("virus_hits.tsv")
        try Data("source\n".utf8).write(to: source)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(NaoMgsManifest(
            sampleName: "naomgs-leaf", sourceFilePath: source.path, hitCount: 15, taxonCount: 5,
            topTaxon: "Taxon 2", topTaxonId: 2
        )).write(to: resultFolder.appendingPathComponent("manifest.json"))
        let counts: [(sample: String, taxId: Int, hits: Int)] = [
            ("sample-A", 1, 3), ("sample-A", 2, 5), ("sample-A", 3, 1), ("sample-B", 4, 2), ("sample-C", 5, 4),
        ]
        try NaoMgsDatabase.create(
            at: resultFolder.appendingPathComponent("hits.sqlite"),
            hits: counts.flatMap { entry in
                (0..<entry.hits).map { Self.hit(sample: entry.sample, taxId: entry.taxId, read: $0) }
            }
        )
        try Data("Sample\tCohort\nsample-A\tcase\nsample-B\tcontrol\nsample-C\tcase\n".utf8)
            .write(to: metadataFolder.appendingPathComponent("sample_metadata.tsv"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private static func hit(sample: String, taxId: Int, read: Int) -> NaoMgsVirusHit {
        NaoMgsVirusHit(
            sample: sample, seqId: "\(sample)-\(taxId)-\(read)", taxId: taxId,
            bestAlignmentScore: 120, cigar: "100M", queryStart: 0, queryEnd: 100, refStart: read * 100,
            refEnd: read * 100 + 100, readSequence: String(repeating: "A", count: 100),
            readQuality: String(repeating: "I", count: 100), subjectSeqId: "NC_\(taxId)", subjectTitle: "Taxon \(taxId)",
            bitScore: 210, eValue: 1e-40, percentIdentity: 99, editDistance: 1, fragmentLength: 100,
            isReverseComplement: false, pairStatus: "CP", queryLength: 100
        )
    }

    private func command(_ arguments: [String]) throws -> NaoMgsCommand.ExportTableSubcommand {
        let parsed = try LungfishCLI.parseAsRoot(arguments)
        return try XCTUnwrap(parsed as? NaoMgsCommand.ExportTableSubcommand)
    }

    private func leafArguments(output: URL, extra: [String] = []) -> [String] {
        ["nao-mgs", "export", "table", resultFolder.path] + extra + ["--output", output.path]
    }

    /// The state the viewer pin sets. Samples A and B, a search every row matches, `hits >= 2` and hits ascending.
    private var viewState: [String] {
        let filter = ViewerTableExportState.encodedFilter(ColumnFilter(columnId: "hits", op: .greaterOrEqual, value: "2"))
        return [
            "--sample", "sample-A", "--sample", "sample-B", "--search", "sample", "--sort", "hits:ascending",
            "--filter", filter, "--filter-match", "all", "--metadata-column", "Cohort",
        ]
    }

    private static func envelope(of outputURL: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL)))
    }

    private static func inputNames(of outputURL: URL) throws -> [String] {
        try envelope(of: outputURL).files.filter { $0.role == .input }
            .map { URL(fileURLWithPath: $0.path).lastPathComponent }.sorted()
    }

    func testAppliesTheViewStateInTheViewersOrder() throws {
        let output = folder.appendingPathComponent("rows.tsv")
        _ = try command(leafArguments(output: output, extra: viewState)).export()
        let lines = try String(contentsOf: output, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].hasPrefix("sample\ttaxon_id\tname\thit_count\t"))
        XCTAssertTrue(lines[0].hasSuffix("\taccession_count\tCohort"))
        XCTAssertEqual(lines.dropFirst().map { $0.split(separator: "\t").prefix(2).joined(separator: ":") }, [
            "sample-B:4", "sample-A:1", "sample-A:2",
        ])
        XCTAssertEqual(lines.dropFirst().map { $0.split(separator: "\t").last.map(String.init) }, [
            "control", "case", "case",
        ])
    }

    func testRecordNamesTheLeafItsArgvAndTheAppliedState() throws {
        let output = folder.appendingPathComponent("record.tsv")
        let arguments = leafArguments(output: output, extra: viewState)
        _ = try command(arguments).export()
        let envelope = try Self.envelope(of: output)
        XCTAssertEqual(envelope.tool.name, "lungfish-cli")
        XCTAssertEqual(envelope.tool.kind, "cli")
        XCTAssertEqual(envelope.workflowName, "lungfish nao-mgs export table")
        XCTAssertEqual(envelope.argv, ["lungfish-cli"] + arguments)
        XCTAssertEqual(envelope.durableReplayArgv, envelope.argv)
        let resolved = envelope.options.resolvedDefaults
        XCTAssertEqual(resolved.keys.sorted(), [
            "columnFilterComposition", "columnFilters", "metadataColumns", "rowCount", "sampleName", "searchText",
            "selectedSamples", "sortKeys", "sourceSampleCount",
        ])
        XCTAssertEqual(resolved["rowCount"]?.integerValue, 3)
        XCTAssertEqual(resolved["sampleName"]?.stringValue, "naomgs-leaf")
        XCTAssertEqual(resolved["selectedSamples"]?.arrayValue?.compactMap(\.stringValue), ["sample-A", "sample-B"])
        XCTAssertEqual(resolved["sourceSampleCount"]?.integerValue, 3)
        XCTAssertEqual(resolved["columnFilterComposition"]?.stringValue, "all")
        XCTAssertEqual(resolved["columnFilters"]?.arrayValue?.count, 1)
        XCTAssertEqual(resolved["sortKeys"]?.arrayValue?.compactMap(\.stringValue), ["hits:ascending"])
        XCTAssertEqual(resolved["searchText"]?.stringValue, "sample")
        XCTAssertEqual(resolved["metadataColumns"]?.arrayValue?.compactMap(\.stringValue), ["Cohort"])
    }

    /// BIO ruling on 12.31 M4. The record names the database, the manifest and the metadata files that exist, the
    /// journal only when present, neither metadata file without --metadata-column, and never the source file.
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

        try assertRefusedBeforeWriting(extra: ["--sample", "sample-Z"])
        try assertRefusedBeforeWriting(extra: ["--sort", "hits:ascending", "--sort", "name:ascending"])
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
    func testNaoMgsTableLeafParsesTheGUIArguments() throws {
        let invocation = NaoMgsSummaryExport.invocation(
            resultURL: resultFolder,
            state: ViewerTableExportState(
                samples: ["sample-A", "sample-B"],
                searchText: "virus",
                sortKeys: [ViewerExportSortKey(column: "hits", ascending: true)],
                filters: ColumnFilterSet(
                    filters: [ColumnFilter(columnId: "hits", op: .greaterOrEqual, value: "10")],
                    composition: .any
                ),
                metadataColumns: ["Cohort"]
            ),
            outputURL: folder.appendingPathComponent("gui.tsv"),
            force: true
        )
        let arguments = invocation.arguments()
        let leaf = try command(arguments)
        XCTAssertEqual(try leaf.invocation(), invocation)
        XCTAssertEqual(try leaf.invocation().canonicalArgv(), [CLICommandIdentity.executableName] + arguments)
        XCTAssertEqual(Array(arguments.prefix(3)), NaoMgsSummaryExport.commandPath)
        XCTAssertEqual(NaoMgsCommand.ExportTableSubcommand.configuration.commandName, NaoMgsSummaryExport.commandPath.last)
    }

    func testNaoMgsTableLeafRefusesAnOptionItDoesNotTake() {
        let output = folder.appendingPathComponent("refuse.tsv")
        XCTAssertThrowsError(try command(leafArguments(output: output, extra: ["--output-format", "tsv"])))
        XCTAssertThrowsError(try command(leafArguments(output: output, extra: ["--column", "hits"])))
        XCTAssertThrowsError(try command(leafArguments(output: output, extra: ["--mode", "flat"])))
    }
}
