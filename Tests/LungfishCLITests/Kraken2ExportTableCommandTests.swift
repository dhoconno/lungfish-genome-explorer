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
        XCTAssertEqual(Set(resolved.keys), ["nodeCount", "outputByteCount", "referenceDatabases", "selectedSamples"])
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

    // MARK: - KR-MERGE-PCT (Phase 2.13 lane 13.35, BIO-R1 items 1 to 3)

    /// The two samples of BIO-R1 item 2 in a folder of their own, with the `Group` column. Sample A has 80 reads, a
    /// root with 70 clade and 30 direct reads, one species of 40 reads and 10 unclassified. Sample B has 60 reads, a
    /// root with 50 clade and 30 direct reads, one species of 20 reads and 10 unclassified.
    private func makePercentBatch() throws -> URL {
        let percentFolder = folder.appendingPathComponent("kraken2-percent", isDirectory: true)
        let metadata = percentFolder.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        var rows: [Kraken2ClassificationRow] = []
        for (sample, name, taxId, clade, total) in [
            ("sample-A", "Species A", 40, 70, 80), ("sample-B", "Species B", 20, 50, 60),
        ] {
            rows.append(Kraken2ClassificationRow(
                sample: sample, taxonName: "root", taxId: 1, rank: "R", rankDisplayName: "Root",
                readsDirect: 30, readsClade: clade, percentage: Double(clade) * 100 / Double(total),
                parentTaxId: nil, depth: 0
            ))
            rows.append(Kraken2ClassificationRow(
                sample: sample, taxonName: name, taxId: taxId, rank: "S", rankDisplayName: "Species",
                readsDirect: clade - 30, readsClade: clade - 30, percentage: Double(clade - 30) * 100 / Double(total),
                parentTaxId: 1, depth: 1
            ))
        }
        try Kraken2Database.create(
            at: percentFolder.appendingPathComponent("kraken2.sqlite"),
            rows: rows,
            metadata: [
                "total_reads_sample-A": "80", "total_reads_sample-B": "60",
                "unclassified_reads_sample-A": "10", "unclassified_reads_sample-B": "10",
            ]
        )
        try Data("Sample\tGroup\nsample-A\tcase\nsample-B\tcontrol\n".utf8)
            .write(to: metadata.appendingPathComponent("sample_metadata.tsv"))
        return percentFolder
    }

    /// Item 2, field for field. Each sample's percents divide by its own reads with the unclassified reads included,
    /// each sample keeps its own unclassified row, the sample's row carries the root's direct reads, and Root stays the
    /// sum of every sample's reads with no value in `Group`.
    func testAMergedTableGivesEachSampleItsOwnPercentAndUnclassifiedRow() throws {
        let batch = try makePercentBatch()
        let output = folder.appendingPathComponent("percent-merged.tsv")
        _ = try command(leafArguments(batch, output: output, extra: ["--metadata-column", "Group"])).export()
        let root = TaxonomicRank.root.displayName
        let sample = TaxonomicRank(code: "no rank").displayName
        let species = TaxonomicRank(code: "S").displayName
        let unclassified = TaxonomicRank.unclassified.displayName
        let rows = try Self.cells(output)
        XCTAssertEqual(rows.first, ["Name", "Rank", "Reads (Clade)", "Reads (Direct)", "Clade %", "Direct %", "Group"])
        XCTAssertEqual(Array(rows.dropFirst()), [
            ["Root", root, "140", "0", "100.0000", "0.0000", ""],
            ["sample-A", sample, "70", "30", "87.5000", "37.5000", "case"],
            ["Species A", species, "40", "40", "50.0000", "50.0000", "case"],
            ["unclassified", unclassified, "10", "10", "12.5000", "12.5000", "case"],
            ["sample-B", sample, "50", "30", "83.3333", "50.0000", "control"],
            ["Species B", species, "20", "20", "33.3333", "33.3333", "control"],
            ["unclassified", unclassified, "10", "10", "16.6667", "16.6667", "control"],
        ])
    }

    /// Item 1. The block of a sample in the merged table is the table of that sample alone, from field 2 on in the
    /// first row, which stands for the one-sample table's root row, and in full in every other row.
    func testEachSampleOfAMergedTableReadsAsItsOwnOneSampleTable() throws {
        let batch = try makePercentBatch()
        let columns = ["--metadata-column", "Group"]
        let merged = folder.appendingPathComponent("own-merged.tsv")
        _ = try command(leafArguments(batch, output: merged, extra: columns)).export()
        let mergedRows = Array(try Self.cells(merged).dropFirst())
        XCTAssertEqual(mergedRows.first?.first, "Root")
        var blockRowCount = 0
        for sample in ["sample-A", "sample-B"] {
            let single = folder.appendingPathComponent("own-\(sample).tsv")
            _ = try command(leafArguments(batch, output: single, extra: columns + ["--sample", sample])).export()
            let singleRows = Array(try Self.cells(single).dropFirst())
            blockRowCount += singleRows.count
            let start = try XCTUnwrap(mergedRows.firstIndex { $0.first == sample }, "no row for \(sample)")
            let block = Array(mergedRows.dropFirst(start).prefix(singleRows.count))
            XCTAssertEqual(block.count, singleRows.count, sample)
            XCTAssertEqual(
                block.first.map { Array($0.dropFirst(2)) }, singleRows.first.map { Array($0.dropFirst(2)) }, sample
            )
            XCTAssertEqual(Array(block.dropFirst()), Array(singleRows.dropFirst()), sample)
        }
        XCTAssertEqual(mergedRows.count, 1 + blockRowCount, "Root and then one block for each sample")
    }

    /// Item 1. The Reads (Direct) of each block add up to the sample's reads, unclassified included, and those of every
    /// row but Root add up to Root's clade reads.
    func testTheDirectReadsOfEachMergedSampleAddUpToItsReads() throws {
        let batch = try makePercentBatch()
        let output = folder.appendingPathComponent("direct-merged.tsv")
        _ = try command(leafArguments(batch, output: output)).export()
        let rows = Array(try Self.cells(output).dropFirst())
        var directBySample: [String: Int] = [:]
        var current = ""
        for row in rows.dropFirst() {
            if row[0] == "sample-A" || row[0] == "sample-B" { current = row[0] }
            directBySample[current, default: 0] += Int(row[3]) ?? 0
        }
        XCTAssertEqual(directBySample, ["sample-A": 80, "sample-B": 60])
        let rootClade = try XCTUnwrap(rows.first.flatMap { Int($0[2]) })
        XCTAssertEqual(rootClade, 140)
        XCTAssertEqual(directBySample.values.reduce(0, +), rootClade)
    }

    // MARK: - KR-REF-DB (Phase 2.13 lane 13.35, R8 of BIO-Q-A2)

    /// The sidecar and the report a Kraken2 run writes for one sample, in a folder named for the sample under `parent`,
    /// classified against the database named. A nil digest stands for a database whose installation recorded none.
    /// Gives the sidecar's URL.
    private func writeSampleResult(
        _ sample: String, in parent: URL, databaseName: String, databaseVersion: String, databaseDigest: String?
    ) throws -> URL {
        let sampleFolder = parent.appendingPathComponent(sample, isDirectory: true)
        try FileManager.default.createDirectory(at: sampleFolder, withIntermediateDirectories: true)
        let report = sampleFolder.appendingPathComponent("classification.kreport")
        try "100.00\t10\t0\tR\t1\troot\n 90.00\t9\t9\tS\t562\t    Escherichia coli\n"
            .write(to: report, atomically: true, encoding: .utf8)
        let config = ClassificationConfig(
            inputFiles: [sampleFolder.appendingPathComponent("\(sample).fastq")],
            isPairedEnd: false,
            databaseName: databaseName,
            databaseVersion: databaseVersion,
            databasePath: folder.appendingPathComponent("db-\(databaseName)", isDirectory: true),
            databaseDigest: databaseDigest,
            outputDirectory: sampleFolder
        )
        try ClassificationResult(
            config: config,
            tree: try KreportParser.parse(url: report),
            reportURL: report,
            outputURL: sampleFolder.appendingPathComponent("classification.kraken"),
            brackenURL: nil,
            runtime: 1,
            toolVersion: "2.1.3",
            provenanceId: nil
        ).save(to: sampleFolder)
        return sampleFolder.appendingPathComponent("classification-result.json")
    }

    /// `makePercentBatch()` with a result folder for each of its two samples, each classified against its own database,
    /// and the batch manifest that names the folders. The manifest names the first sample's database, as a batch run
    /// names the one database it ran with.
    private func makeReferenceBatch(standardDigest: String?) throws -> URL {
        let batch = try makePercentBatch()
        _ = try writeSampleResult(
            "sample-A", in: batch, databaseName: "Viral", databaseVersion: "2024-09-04", databaseDigest: "sha256:viral-digest"
        )
        _ = try writeSampleResult(
            "sample-B", in: batch, databaseName: "Standard-8", databaseVersion: "2025-01-12", databaseDigest: standardDigest
        )
        try MetagenomicsBatchResultStore.saveClassification(
            ClassificationBatchResultManifest(
                header: MetagenomicsBatchManifestHeader(schemaVersion: 2, createdAt: Date(), sampleCount: 2),
                goal: "classify",
                databaseName: "Viral",
                databaseVersion: "2024-09-04",
                summaryTSV: "summary.tsv",
                samples: ["sample-A", "sample-B"].map {
                    MetagenomicsBatchSampleRecord(sampleId: $0, resultDirectory: $0, inputFiles: [], isPairedEnd: false)
                }
            ),
            to: batch
        )
        return batch
    }

    /// The `referenceDatabases` entries of a record, each as the strings the leaf wrote.
    private static func referenceDatabases(of envelope: ProvenanceEnvelope) throws -> [[String: String]] {
        let entries = try XCTUnwrap(envelope.options.resolvedDefaults["referenceDatabases"]?.arrayValue)
        return entries.map { entry -> [String: String] in
            guard case .dictionary(let fields) = entry else { return [:] }
            return fields.compactMapValues(\.stringValue)
        }
    }

    private static let viralEntry = [
        "sample": "sample-A", "name": "Viral", "version": "2024-09-04", "digest": "sha256:viral-digest",
    ]
    private static let standardEntry = [
        "sample": "sample-B", "name": "Standard-8", "version": "2025-01-12", "digest": "sha256:standard-digest",
    ]

    /// The database form. For each sample of the table, in the table's order, the record names the name, version and
    /// digest that the sample's own classification result gives its database. The leaf read the batch manifest and one
    /// sidecar for each sample, so those are inputs, and the reference database itself is never one.
    func testTheDatabaseFormRecordsEachSamplesReferenceDatabase() throws {
        let batch = try makeReferenceBatch(standardDigest: "sha256:standard-digest")
        let output = folder.appendingPathComponent("refs-database.tsv")
        _ = try command(leafArguments(batch, output: output)).export()
        let envelope = try Self.envelope(of: output)
        XCTAssertEqual(try Self.referenceDatabases(of: envelope), [Self.viralEntry, Self.standardEntry])
        XCTAssertEqual(
            Self.inputNames(envelope),
            ["classification-batch-result.json", "classification-result.json", "classification-result.json", "kraken2.sqlite"]
        )
        XCTAssertTrue(envelope.files.filter { $0.role == .input }.allSatisfy { $0.checksumSHA256 != nil })
        XCTAssertFalse(envelope.files.contains { $0.path.contains("/db-") }, "the reference database is not an input")

        let one = folder.appendingPathComponent("refs-database-one.tsv")
        _ = try command(leafArguments(batch, output: one, extra: ["--sample", "sample-B"])).export()
        let oneEnvelope = try Self.envelope(of: one)
        XCTAssertEqual(try Self.referenceDatabases(of: oneEnvelope), [Self.standardEntry])
        XCTAssertEqual(
            Self.inputNames(oneEnvelope), ["classification-batch-result.json", "classification-result.json", "kraken2.sqlite"]
        )
    }

    /// The sidecar form. A run holds one sample, and each of two runs classified against its own database records the
    /// database its own sidecar gives. The sidecar was already an input, so no file is added.
    func testTheSidecarFormRecordsItsReferenceDatabase() throws {
        let runs = folder.appendingPathComponent("refs-runs", isDirectory: true)
        let sidecars = [
            try writeSampleResult(
                "sample-A", in: runs, databaseName: "Viral", databaseVersion: "2024-09-04", databaseDigest: "sha256:viral-digest"
            ),
            try writeSampleResult(
                "sample-B", in: runs, databaseName: "Standard-8", databaseVersion: "2025-01-12",
                databaseDigest: "sha256:standard-digest"
            ),
        ]
        for (sidecar, expected) in zip(sidecars, [Self.viralEntry, Self.standardEntry]) {
            let output = folder.appendingPathComponent("refs-run-\(expected["sample"] ?? "").tsv")
            _ = try command(leafArguments(sidecar, output: output)).export()
            let envelope = try Self.envelope(of: output)
            XCTAssertEqual(try Self.referenceDatabases(of: envelope), [expected])
            XCTAssertEqual(Self.inputNames(envelope), ["classification-result.json", "classification.kreport"])
        }
    }

    /// A database built for one run sits in that run's folder beside the run's `classification-result.json`, with no
    /// batch manifest. The record reads the name, version and digest from the sidecar beside the database, and lists
    /// that sidecar among the inputs.
    func testADatabaseBuiltForOneRunRecordsTheSidecarBesideIt() throws {
        let sidecar = try writeSampleResult(
            "sample-C", in: folder.appendingPathComponent("refs-single", isDirectory: true),
            databaseName: "Viral", databaseVersion: "2024-09-04", databaseDigest: "sha256:viral-digest"
        )
        let singleRun = sidecar.deletingLastPathComponent()
        try Kraken2Database.create(
            at: singleRun.appendingPathComponent("kraken2.sqlite"),
            rows: [
                Kraken2ClassificationRow(
                    sample: "sample-C", taxonName: "root", taxId: 1, rank: "R", rankDisplayName: "Root",
                    readsDirect: 30, readsClade: 70, percentage: 87.5, parentTaxId: nil, depth: 0
                ),
                Kraken2ClassificationRow(
                    sample: "sample-C", taxonName: "Species C", taxId: 40, rank: "S", rankDisplayName: "Species",
                    readsDirect: 40, readsClade: 40, percentage: 50, parentTaxId: 1, depth: 1
                ),
            ],
            metadata: ["total_reads_sample-C": "80", "unclassified_reads_sample-C": "10"]
        )
        let output = folder.appendingPathComponent("refs-single.tsv")
        _ = try command(leafArguments(singleRun, output: output)).export()
        let envelope = try Self.envelope(of: output)
        XCTAssertEqual(try Self.referenceDatabases(of: envelope), [
            ["sample": "sample-C", "name": "Viral", "version": "2024-09-04", "digest": "sha256:viral-digest"],
        ])
        XCTAssertEqual(Self.inputNames(envelope), ["classification-result.json", "kraken2.sqlite"])
    }

    /// A database that holds several samples and has no batch manifest has no run beside it, so a
    /// `classification-result.json` in its folder belongs to no picked sample. Picking one sample of such a database
    /// counts one picked sample but several in the database, and the record must not read that file for it. The
    /// sample reads unknown with the reason, and the file is not an input.
    func testAManySampleDatabaseWithNoManifestNeverReadsAStraySidecarForOnePickedSample() throws {
        let sidecar = try writeSampleResult(
            "sample-C", in: folder.appendingPathComponent("refs-stray", isDirectory: true),
            databaseName: "Viral", databaseVersion: "2024-09-04", databaseDigest: "sha256:viral-digest"
        )
        let strayFolder = sidecar.deletingLastPathComponent()
        let rows = ["sample-C", "sample-D"].flatMap { sample in
            [
                Kraken2ClassificationRow(
                    sample: sample, taxonName: "root", taxId: 1, rank: "R", rankDisplayName: "Root",
                    readsDirect: 30, readsClade: 70, percentage: 87.5, parentTaxId: nil, depth: 0
                ),
                Kraken2ClassificationRow(
                    sample: sample, taxonName: "Species C", taxId: 40, rank: "S", rankDisplayName: "Species",
                    readsDirect: 40, readsClade: 40, percentage: 50, parentTaxId: 1, depth: 1
                ),
            ]
        }
        try Kraken2Database.create(
            at: strayFolder.appendingPathComponent("kraken2.sqlite"),
            rows: rows,
            metadata: [
                "total_reads_sample-C": "80", "unclassified_reads_sample-C": "10",
                "total_reads_sample-D": "80", "unclassified_reads_sample-D": "10",
            ]
        )
        let output = folder.appendingPathComponent("refs-stray.tsv")
        _ = try command(leafArguments(strayFolder, output: output, extra: ["--sample", "sample-C"])).export()
        let envelope = try Self.envelope(of: output)
        XCTAssertEqual(try Self.referenceDatabases(of: envelope), [
            [
                "sample": "sample-C", "name": "unknown", "version": "unknown", "digest": "unknown",
                "reason": "No readable classification-result.json was found for the sample, "
                    + "so its database digest is not recorded.",
            ],
        ])
        XCTAssertEqual(Self.inputNames(envelope), ["kraken2.sqlite"])
    }

    /// A sample whose result holds no digest gets `unknown` with the reason, on both forms. So does a sample whose
    /// result is not in the folder, which keeps the name and version the batch manifest gives and has none without a
    /// manifest.
    func testAReferenceDatabaseWithNoDigestIsRecordedAsUnknownWithItsReason() throws {
        let noDigest = "The sample's classification result records no digest for its database."
        let noResult = "No readable classification-result.json was found for the sample, "
            + "so its database digest is not recorded."

        let batch = try makeReferenceBatch(standardDigest: nil)
        let batchOutput = folder.appendingPathComponent("refs-nodigest.tsv")
        _ = try command(leafArguments(batch, output: batchOutput)).export()
        XCTAssertEqual(try Self.referenceDatabases(of: try Self.envelope(of: batchOutput)), [
            Self.viralEntry,
            ["sample": "sample-B", "name": "Standard-8", "version": "2025-01-12", "digest": "unknown", "reason": noDigest],
        ])

        let sidecar = try writeSampleResult(
            "sample-C", in: folder.appendingPathComponent("refs-nodigest-run", isDirectory: true),
            databaseName: "Viral", databaseVersion: "2024-09-04", databaseDigest: nil
        )
        let runOutput = folder.appendingPathComponent("refs-nodigest-run.tsv")
        _ = try command(leafArguments(sidecar, output: runOutput)).export()
        XCTAssertEqual(try Self.referenceDatabases(of: try Self.envelope(of: runOutput)), [
            ["sample": "sample-C", "name": "Viral", "version": "2024-09-04", "digest": "unknown", "reason": noDigest],
        ])

        try FileManager.default.removeItem(at: batch.appendingPathComponent("sample-B", isDirectory: true))
        let missingOutput = folder.appendingPathComponent("refs-noresult.tsv")
        _ = try command(leafArguments(batch, output: missingOutput)).export()
        XCTAssertEqual(try Self.referenceDatabases(of: try Self.envelope(of: missingOutput)), [
            Self.viralEntry,
            ["sample": "sample-B", "name": "Viral", "version": "2024-09-04", "digest": "unknown", "reason": noResult],
        ])

        let bareOutput = folder.appendingPathComponent("refs-bare.tsv")
        _ = try command(leafArguments(database, output: bareOutput)).export()
        XCTAssertEqual(try Self.referenceDatabases(of: try Self.envelope(of: bareOutput)), ["sample-A", "sample-B"].map {
            ["sample": $0, "name": "unknown", "version": "unknown", "digest": "unknown", "reason": noResult]
        })
    }

    func testKraken2TableLeafRefusesAnOptionItDoesNotTake() {
        let output = folder.appendingPathComponent("refuse.tsv")
        XCTAssertThrowsError(try command(leafArguments(database, output: output, extra: ["--search", "beta"])))
        XCTAssertThrowsError(try command(leafArguments(database, output: output, extra: ["--sort", "name:ascending"])))
    }
}
