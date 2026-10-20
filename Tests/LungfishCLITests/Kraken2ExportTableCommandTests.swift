// Kraken2ExportTableCommandTests.swift - lungfish-cli kraken2 export table
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.33, ARCH ruling on F1 and BIO 6. The leaf reads the file the viewer's tree came from, a
// database of several samples or the sidecar of one run, merges several samples as the viewer does, gives each row
// its own sample's metadata, names only the files it read, and parses the arguments the app's begin helper builds.

import ArgumentParser
import SQLite3
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

final class Kraken2ExportTableCommandTests: XCTestCase {
    private var folder: URL!
    private var batchFolder: URL!
    private var runFolder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kraken2ExportTable-\(UUID().uuidString)", isDirectory: true)
        batchFolder = folder.appendingPathComponent("kraken2-batch", isDirectory: true)
        runFolder = folder.appendingPathComponent("kraken2-run", isDirectory: true)
        let metadata = batchFolder.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runFolder, withIntermediateDirectories: true)

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
        try Kraken2Database.create(
            at: batchFolder.appendingPathComponent("kraken2.sqlite"),
            rows: rows,
            metadata: ["total_reads_sample-A": "40", "total_reads_sample-B": "20"]
        )
        try Data("Sample\tGroup\nsample-A\tcase\nsample-B\tcontrol\n".utf8)
            .write(to: metadata.appendingPathComponent("sample_metadata.tsv"))

        let report = runFolder.appendingPathComponent("classification.kreport")
        try "100.00\t10\t0\tR\t1\troot\n 90.00\t9\t9\tS\t562\t    Escherichia coli\n"
            .write(to: report, atomically: true, encoding: .utf8)
        let config = ClassificationConfig(
            inputFiles: [runFolder.appendingPathComponent("sample-run_R1.fastq")],
            isPairedEnd: false,
            databaseName: "test-db",
            databasePath: folder.appendingPathComponent("db"),
            outputDirectory: runFolder
        )
        try ClassificationResult(
            config: config,
            tree: try KreportParser.parse(url: report),
            reportURL: report,
            outputURL: runFolder.appendingPathComponent("classification.kraken"),
            brackenURL: nil,
            runtime: 1,
            toolVersion: "2.1.3",
            provenanceId: nil
        ).save(to: runFolder)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var database: URL { batchFolder.appendingPathComponent("kraken2.sqlite") }
    private var sidecar: URL { runFolder.appendingPathComponent("classification-result.json") }

    private func command(_ arguments: [String]) throws -> Kraken2Command.ExportTableSubcommand {
        let parsed = try LungfishCLI.parseAsRoot(arguments)
        return try XCTUnwrap(parsed as? Kraken2Command.ExportTableSubcommand)
    }

    private func leafArguments(_ source: URL, output: URL, extra: [String] = []) -> [String] {
        ["kraken2", "export", "table", source.path] + extra + ["--output-format", "tsv", "--output", output.path]
    }

    private static func envelope(of outputURL: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL)))
    }

    private static func inputNames(_ envelope: ProvenanceEnvelope) -> [String] {
        envelope.files.filter { $0.role == .input }.map { URL(fileURLWithPath: $0.path).lastPathComponent }.sorted()
    }

    private static func cells(_ output: URL) throws -> [[String]] {
        try String(contentsOf: output, encoding: .utf8).split(separator: "\n")
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    /// Every sample of the database is the merged tree, each row carries its own sample's value, and the record names
    /// the database and the metadata table with their digests and the samples the table holds.
    func testTheDatabaseFormMergesTheSamplesAndGivesEachItsMetadata() throws {
        let output = folder.appendingPathComponent("merged.tsv")
        _ = try command(leafArguments(database, output: output, extra: ["--metadata-column", "Group"])).export()
        let rows = try Self.cells(output)
        XCTAssertEqual(rows.count, 6)
        for row in rows {
            XCTAssertEqual(row.count, 7, "\(row)")
        }
        let groups = Dictionary(uniqueKeysWithValues: rows.dropFirst().map { ($0[0], $0.last ?? "") })
        XCTAssertEqual(
            groups,
            ["Root": "", "sample-A": "case", "Virus A": "case", "sample-B": "control", "Virus B": "control"]
        )
        let envelope = try Self.envelope(of: output)
        XCTAssertEqual(Self.inputNames(envelope), ["kraken2.sqlite", "sample_metadata.tsv"])
        XCTAssertTrue(envelope.files.filter { $0.role == .input }.allSatisfy { $0.checksumSHA256 != nil })
        let resolved = envelope.options.resolvedDefaults
        XCTAssertEqual(Set(resolved.keys), ["nodeCount", "outputByteCount", "selectedSamples"])
        XCTAssertEqual(resolved["selectedSamples"]?.arrayValue?.compactMap(\.stringValue), ["sample-A", "sample-B"])
        XCTAssertEqual(Set(envelope.options.explicit.keys), ["metadataColumns", "outputFormat", "outputPath"])
    }

    /// One sample is its own tree, the folder selects the database, and no metadata file is an input without a column.
    func testOneSampleIsItsOwnTreeAndAFolderSelectsTheDatabase() throws {
        let output = folder.appendingPathComponent("one.tsv")
        _ = try command(leafArguments(batchFolder, output: output, extra: ["--sample", "sample-B"])).export()
        XCTAssertEqual(try Self.cells(output).map(\.first), ["Name", "root", "Virus B"])
        let envelope = try Self.envelope(of: output)
        XCTAssertEqual(Self.inputNames(envelope), ["kraken2.sqlite"])
        XCTAssertEqual(
            envelope.options.resolvedDefaults["selectedSamples"]?.arrayValue?.compactMap(\.stringValue), ["sample-B"]
        )
        XCTAssertEqual(envelope.options.explicit["samples"]?.arrayValue?.compactMap(\.stringValue), ["sample-B"])
    }

    /// The sidecar form rebuilds the tree from the sidecar and the report, and names those two files and no read.
    func testTheSidecarFormReadsTheSidecarAndTheReport() throws {
        let output = folder.appendingPathComponent("run.tsv")
        _ = try command(leafArguments(sidecar, output: output)).export()
        XCTAssertEqual(try Self.cells(output).map(\.first), ["Name", "root", "Escherichia coli"])
        let envelope = try Self.envelope(of: output)
        XCTAssertEqual(Self.inputNames(envelope), ["classification-result.json", "classification.kreport"])
        XCTAssertEqual(
            envelope.options.resolvedDefaults["selectedSamples"]?.arrayValue?.compactMap(\.stringValue),
            ["sample-run_R1"]
        )
    }

    /// One Kraken2 folder holds both files, so the file picks the form (ARCH ruling on F1, C7).
    func testTheFileNamedPicksTheFormOfAFolderThatHoldsBoth() throws {
        for name in ["classification-result.json", "classification.kreport"] {
            try FileManager.default.copyItem(
                at: runFolder.appendingPathComponent(name), to: batchFolder.appendingPathComponent(name)
            )
        }
        let byFolder = folder.appendingPathComponent("by-folder.tsv")
        _ = try command(leafArguments(batchFolder, output: byFolder)).export()
        XCTAssertEqual(Self.inputNames(try Self.envelope(of: byFolder)), ["kraken2.sqlite"])
        let bySidecar = folder.appendingPathComponent("by-sidecar.tsv")
        _ = try command(leafArguments(
            batchFolder.appendingPathComponent("classification-result.json"), output: bySidecar
        )).export()
        XCTAssertEqual(
            Self.inputNames(try Self.envelope(of: bySidecar)), ["classification-result.json", "classification.kreport"]
        )
    }

    func testRecordNamesTheLeafAndItsCanonicalArgv() throws {
        let output = folder.appendingPathComponent("record.csv")
        let arguments = ["kraken2", "export", "table", database.path, "--output-format", "csv", "--output", output.path]
        _ = try command(arguments).export()
        let envelope = try Self.envelope(of: output)
        XCTAssertEqual(envelope.tool.name, "lungfish-cli")
        XCTAssertEqual(envelope.tool.kind, "cli")
        XCTAssertEqual(envelope.workflowName, "lungfish kraken2 export table")
        XCTAssertEqual(envelope.argv, ["lungfish-cli"] + arguments)
        XCTAssertEqual(envelope.durableReplayArgv, envelope.argv)
    }

    /// Each refusal comes before any write (exit 3), and `--force` never lets the output replace an input.
    func testRefusalsComeBeforeAnyWrite() throws {
        let exists = folder.appendingPathComponent("exists.tsv")
        try Data("keep".utf8).write(to: exists)
        XCTAssertThrowsError(try command(leafArguments(database, output: exists)).export()) { error in
            XCTAssertTrue(error is ViewerExportRefusal, "\(error)")
        }
        XCTAssertEqual(try String(contentsOf: exists, encoding: .utf8), "keep")
        _ = try command(leafArguments(database, output: exists, extra: ["--force"])).export()
        XCTAssertNotEqual(try String(contentsOf: exists, encoding: .utf8), "keep")

        try assertRefused(database, extra: ["--sample", "sample-Z"])
        try assertRefused(sidecar, extra: ["--sample", "sample-A"])
        try assertRefused(folder, extra: [])
        try assertRefused(runFolder.appendingPathComponent("classification.kreport"), extra: [])
        try assertRefused(database, extra: ["--metadata-column", "Nope"])
        try assertRefused(sidecar, extra: ["--metadata-column", "Group"])

        let before = try Data(contentsOf: database)
        XCTAssertThrowsError(try command(leafArguments(database, output: database, extra: ["--force"])).export()) { error in
            XCTAssertTrue(error is ViewerExportRefusal, "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: database), before)
    }

    private func assertRefused(_ source: URL, extra: [String], line: UInt = #line) throws {
        let output = folder.appendingPathComponent("refused-\(UUID().uuidString).tsv")
        XCTAssertThrowsError(try command(leafArguments(source, output: output, extra: extra)).export(), line: line) { error in
            XCTAssertTrue(error is ViewerExportRefusal, "\(error)", line: line)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path), line: line)
    }

    /// ARCH ruling G2 section 5. The arguments the begin helper builds parse through the root into the leaf, whose
    /// canonical argv is the executable name and the same array.
    func testKraken2TableLeafParsesTheGUIArguments() throws {
        let invocation = Kraken2TaxonomyTableExport.invocation(
            sourceURL: database,
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
        XCTAssertEqual(Array(arguments.prefix(3)), Kraken2TaxonomyTableExport.commandPath)
        XCTAssertEqual(Kraken2Command.ExportTableSubcommand.configuration.commandName, Kraken2TaxonomyTableExport.commandPath.last)
    }

    // MARK: - KR-STALE (Phase 2.13 lane 13.35, BIO-R1 items 7 and 8)

    /// Ages the database to the older builder's format by deleting the format key, as `TaxonomyReopenBrackenTests` does.
    private func makeDatabaseStale() {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(
            sqlite3_exec(
                handle, "DELETE FROM metadata WHERE key = '\(Kraken2Database.formatVersionMetadataKey)'", nil, nil, nil
            ),
            SQLITE_OK
        )
    }

    /// For one sample and for a merge alike, the leaf refuses the stale database with exit 3 and before any write, so
    /// neither the output nor its record sidecar exists. Only the closing words depend on the reports.
    private func assertStaleRefusal(closing: String, line: UInt = #line) {
        let reason = "was built by an older version of Lungfish and may hold Bracken's estimates in place of Kraken2's read counts. "
        for extra in [[], ["--sample", "sample-A"]] {
            let output = folder.appendingPathComponent("stale-\(UUID().uuidString).tsv")
            XCTAssertThrowsError(
                try command(leafArguments(database, output: output, extra: extra)).export(), line: line
            ) { error in
                guard let message = (error as? ViewerExportRefusal)?.message else { return XCTFail("\(error)", line: line) }
                XCTAssertTrue(message.hasPrefix("The Kraken2 database at "), message, line: line)
                XCTAssertTrue(message.hasSuffix("kraken2.sqlite " + reason + closing), message, line: line)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), line: line)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path), line: line
            )
        }
    }

    /// R3. The database may hold Bracken's estimates under headers that name Kraken2's reads. With its reports in
    /// the folder the message says to open the result in Lungfish, which rebuilds it.
    func testTheLeafRefusesAStaleDatabaseWithItsReportsPresent() throws {
        try FileManager.default.copyItem(
            at: runFolder.appendingPathComponent("classification.kreport"),
            to: batchFolder.appendingPathComponent("classification.kreport")
        )
        makeDatabaseStale()
        assertStaleRefusal(closing: "Open the result in Lungfish to rebuild it from its reports, then export again.")
    }

    /// R3. The reports are gone, so nothing can tell which numbers the database holds and it cannot be rebuilt.
    func testTheLeafRefusesAStaleDatabaseWhoseReportsAreGone() {
        makeDatabaseStale()
        assertStaleRefusal(closing: "Its reports are gone, so it cannot be rebuilt or exported.")
    }

    func testKraken2TableLeafRefusesAnOptionItDoesNotTake() {
        let output = folder.appendingPathComponent("refuse.tsv")
        XCTAssertThrowsError(try command(leafArguments(database, output: output, extra: ["--search", "beta"])))
        XCTAssertThrowsError(try command(leafArguments(database, output: output, extra: ["--sort", "name:ascending"])))
    }
}
