// BuildDbTaxTriageCleanupFreezeTests.swift - What `build-db taxtriage` indexes and deletes today, frozen before lanes B2 and S1
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.8 lane TF-W. The app runs `lungfish-cli build-db taxtriage <root> --force` after every TaxTriage run, with no
// `--no-cleanup`, and the command then deletes `count/` (raw FASTQ copies), the fastp FASTQ files and eight folders
// with no recorded step for the removal. Records written before it name those files (BIO T11 and T12). Plan decision T5 gives
// the executor path a recorded removal step and keeps this cleanup for the legacy route, so these assertions stay
// true for the route that exists in 2.8 and a lane that changes the cleanup flips them where its decision says.
//
// The runs use a copy of `Tests/Fixtures/taxtriage-mini` without `minimap2/`, the folder of its BAMs, as
// `BuildDbStreamCapture.taxTriageResultWithoutBAMs` does, because a row that names a BAM makes the command run
// markdup and samtools. `BuildDbCommandMarkdupTests` covers that pass with a managed samtools home, and `minimap2/` is
// in neither the cleanup list nor any removal below. The fixture holds no `count/`, `fastp/` or intermediate folder
// except `top/`, so the tests write small files for the rest.

import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

final class BuildDbTaxTriageCleanupFreezeTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "build-db-taxtriage-cleanup")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - The result folder

    /// Files of a finished TaxTriage sample folder that the cleanup deletes. They are the raw FASTQ copies of `count/`,
    /// the fastp FASTQ files (`.fastq`, `.gz`, `.fastp.fastq.gz`) and the files of seven of the eight intermediate
    /// folders. The eighth, `top/`, comes with the fixture.
    private static let removedSeed = [
        "count/SRR35517702.fastq.gz", "count/SRR35517703.fastq.gz",
        "fastp/SRR35517702.fastp.fastq.gz", "fastp/SRR35517703_1.fastq", "fastp/SRR35517703.trimmed.gz",
        "filterkraken/SRR35517702.filtered.kraken2.report.txt", "get/SRR35517702.get.tsv", "map/SRR35517702.merged.taxid.tsv",
        "samtools/SRR35517702.stats.txt", "bedtools/SRR35517702.bedtools.cov.tsv", "mergedsubspecies/SRR35517702.merged.tsv",
        "mergedkrakenreport/SRR35517702.merged.report.txt",
    ]

    /// Files beside them that the cleanup leaves. They are the fastp reports and logs, a fastp file in a subfolder (the
    /// pass is not recursive), and folders the cleanup does not name.
    private static let keptSeed = [
        "fastp/SRR35517702.fastp.html", "fastp/SRR35517702.fastp.json", "fastp/SRR35517702.fastp.log",
        "fastp/nested/SRR35517702.nested.fastq.gz", "download/SRR35517702.dwnld.references.fasta",
        "krona/SRR35517702.krona.html", "kraken2/SRR35517702.kraken2.report.txt", "pipeline_info/execution_trace.txt",
        "samplesheet.csv", "trace.txt",
    ]

    private func fixture(_ name: String) -> URL {
        BuildDbStreamCapture.fixturesFolder.appendingPathComponent(name, isDirectory: true)
    }

    /// Copies `taxtriage-mini` to `destination` without `minimap2/` and writes the seed files into it.
    private func makeSampleResult(at destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.copyItem(at: fixture("taxtriage-mini"), to: destination)
        try fileManager.removeItem(at: destination.appendingPathComponent("minimap2", isDirectory: true))
        try Self.writeSeed(in: destination)
    }

    private static func writeSeed(in directory: URL) throws {
        for relative in removedSeed + keptSeed {
            let url = directory.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "\(relative)\n".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Every file and folder under `directory`, relative and sorted, hidden files included.
    private func listing(of directory: URL) throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: directory.path).sorted()
    }

    private func buildDb(_ result: URL, _ arguments: [String] = ["--force", "-q"]) async throws {
        let command = try BuildDbCommand.TaxTriageSubcommand.parse([result.path] + arguments)
        try await command.run()
    }

    private func relative(_ path: String, to directory: URL) -> String {
        // `standardizedFileURL` drops `/private` only from a path that exists, so a removed file keeps it.
        let standard = directory.standardizedFileURL.path
        let prefixes = Set([directory.path, standard, directory.resolvingSymlinksInPath().path, "/private" + standard])
        for prefix in prefixes.sorted(by: { $0.count > $1.count }) where path.hasPrefix(prefix + "/") {
            return String(path.dropFirst(prefix.count + 1))
        }
        return path
    }

    private func exists(_ relative: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(relative).path)
    }

    // MARK: - One result folder

    /// BIO T12. The cleanup deletes `count/`, the fastp FASTQ files and the eight intermediate folders (`top/` among
    /// them) and nothing else. Everything the run wrote that is not in that list stays, and the command adds the
    /// database, the folder's record and the database's own record.
    func testTheCleanupRemovesExactlyThePathsItListsAndAddsTheDatabaseAndTwoRecords() async throws {
        let result = root.appendingPathComponent("taxtriage", isDirectory: true)
        try makeSampleResult(at: result)
        let before = try listing(of: result)

        try await buildDb(result)

        let after = try listing(of: result)
        let folders = ["bedtools", "count", "filterkraken", "get", "map", "mergedkrakenreport", "mergedsubspecies", "samtools", "top"]
        let removed = Set(folders + Self.removedSeed + ["top/SRR35517702.top_report.tsv"])
        XCTAssertEqual(Set(before).subtracting(after), removed)
        XCTAssertEqual(
            Set(after).subtracting(before),
            [".lungfish-provenance.json", "taxtriage.sqlite", "taxtriage.sqlite.lungfish-provenance.json"]
        )
        XCTAssertEqual(
            Set(after).subtracting(["taxtriage.sqlite", ".lungfish-provenance.json", "taxtriage.sqlite.lungfish-provenance.json"]),
            Set(before).subtracting(removed),
            "nothing else is touched"
        )
        for kept in Self.keptSeed + ["combine/SRR35517702.combined.gcfmap.tsv", "report/multiqc_data/multiqc_confidences.txt"] {
            XCTAssertTrue(exists(kept, in: result), kept)
        }
        XCTAssertTrue(exists("fastp", in: result), "the fastp folder stays, with its reports")
    }

    /// BIO T12. `--no-cleanup` removes nothing and the record says so in its argv.
    func testNoCleanupRemovesNothing() async throws {
        let result = root.appendingPathComponent("taxtriage", isDirectory: true)
        try makeSampleResult(at: result)
        let before = try listing(of: result)

        try await buildDb(result, ["--force", "--no-cleanup", "-q"])

        let after = try listing(of: result)
        XCTAssertEqual(Set(before).subtracting(after), [])
        XCTAssertTrue(exists("top/SRR35517702.top_report.tsv", in: result))
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: result))
        XCTAssertEqual(Array(try XCTUnwrap(envelope.steps.last).argv.dropFirst()), ["build-db", "taxtriage", result.path, "--force", "--no-cleanup", "--quiet"])
    }

    /// BIO T12 and T13. The rows the command indexes from the fixture, and the database metadata, which holds the
    /// time the database was built and the absolute path of the folder it was built from.
    func testTheRowsItIndexesAndTheMetadataItWrites() async throws {
        let result = root.appendingPathComponent("taxtriage", isDirectory: true)
        try makeSampleResult(at: result)

        try await buildDb(result)

        let database = try TaxTriageDatabase(at: result.appendingPathComponent("taxtriage.sqlite"))
        let samples = try database.fetchSamples().map { "\($0.sample)=\($0.organismCount)" }
        XCTAssertEqual(samples, ["SRR35517702=4", "SRR35517703=4", "SRR35517705=7"])
        let rows = try database.fetchRows(samples: try database.fetchSamples().map(\.sample))
        let summary = rows.map {
            "\($0.sample)|\($0.organism)|\($0.taxId.map(String.init) ?? "nil")|\(String(format: "%.2f", $0.tassScore))|\($0.readsAligned)"
        }.sorted()
        XCTAssertEqual(summary, [
            "SRR35517702|Human bocavirus 3|3052040|0.51|2",
            "SRR35517702|Human coronavirus HKU1|290028|0.21|2",
            "SRR35517702|Influenza A virus (A/New York/392/2004(H3N2))|335341|0.17|2",
            "SRR35517702|Severe acute respiratory syndrome coronavirus 2|2697049|0.66|31",
            "SRR35517703|Bovine coronavirus|11128|0.25|3",
            "SRR35517703|Influenza A virus (A/New York/392/2004(H3N2))|335341|0.23|3",
            "SRR35517703|Severe acute respiratory syndrome coronavirus 2|2697049|0.53|9",
            "SRR35517703|Sewage-associated gemycircularvirus 4|1519399|0.44|1",
            "SRR35517705|Enterobacteria phage P7|10682|0.11|2",
            "SRR35517705|Mycobacterium phage Kumao|2041344|0.14|2",
            "SRR35517705|Pepper chlorotic spot virus|1414655|0.12|1",
            "SRR35517705|Severe acute respiratory syndrome coronavirus 2|2697049|0.51|16",
            "SRR35517705|Staphylococcus phage SPbeta-like|1732063|0.14|4",
            "SRR35517705|ssRNA phage SRR5466337_3|2786389|0.38|14",
            "SRR35517705|ssRNA phage SRR5466369_2|2786405|0.49|993",
        ])
        XCTAssertTrue(rows.allSatisfy { $0.bamPath == nil && $0.uniqueReads == nil }, "no BAM in the copy, so no row names one and no read count is recomputed")

        let metadata = try database.fetchMetadata()
        XCTAssertEqual(metadata.keys.sorted(), ["created_at", "source_dir", "tass_scale", "taxonomy_source", "tool"])
        XCTAssertEqual(metadata["tool"], "taxtriage")
        XCTAssertEqual(metadata["source_dir"], result.path, "the absolute path of the folder it was built from")
        let createdAt = try XCTUnwrap(metadata["created_at"].flatMap { ISO8601DateFormatter().date(from: $0) })
        XCTAssertLessThan(abs(createdAt.timeIntervalSinceNow), 600, "the time it was built")
        XCTAssertEqual(metadata[TaxTriageDatabase.taxonomySourceMetadataKey], "multiqc_confidences")
        XCTAssertEqual(metadata[TaxTriageDatabase.tassScaleMetadataKey], "0-1")
    }

    /// BIO T12. The record the command writes into a folder that has none names its sources before the cleanup runs,
    /// so it names `top/SRR35517702.top_report.tsv`, which the same command then deletes. The other sources stay. The
    /// database's own record beside `taxtriage.sqlite` lists the same sources.
    func testTheRecordItWritesNamesASourceThatItsOwnCleanupDeletes() async throws {
        let result = root.appendingPathComponent("taxtriage", isDirectory: true)
        try makeSampleResult(at: result)

        try await buildDb(result)

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: result))
        XCTAssertEqual(envelope.workflowName, "lungfish build-db taxtriage")
        XCTAssertEqual(envelope.exitStatus, 0)
        let step = try XCTUnwrap(envelope.steps.last)
        XCTAssertEqual(Array(step.argv.dropFirst()), ["build-db", "taxtriage", result.path, "--force", "--quiet"])
        let inputs = step.inputs.map { relative($0.path, to: result) }.sorted()
        XCTAssertEqual(inputs, [
            "combine/SRR35517702.combined.gcfmap.tsv", "combine/SRR35517703.combined.gcfmap.tsv",
            "combine/SRR35517705.combined.gcfmap.tsv", "report/multiqc_data/multiqc_confidences.txt",
            "top/SRR35517702.top_report.tsv",
        ])
        XCTAssertEqual(inputs.filter { !exists($0, in: result) }, ["top/SRR35517702.top_report.tsv"])
        XCTAssertEqual(step.outputs.map { relative($0.path, to: result) }, ["taxtriage.sqlite"])
        let sidecar = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(fromSidecar: result.appendingPathComponent("taxtriage.sqlite.lungfish-provenance.json")))
        XCTAssertEqual(sidecar.workflowName, "lungfish build-db taxtriage")
        let sidecarInputs = try XCTUnwrap(sidecar.steps.last).inputs.map { relative($0.path, to: result) }.sorted()
        XCTAssertEqual(sidecarInputs, inputs, "the database's own record names the same sources, top/ among them")
    }

    // MARK: - A batch root

    /// BIO T11 and T12. The several-sample layout, a root with one folder per sample. A record of such a batch names
    /// every file of every sample folder except `work`, `download` and `workflow-source` (`TaxTriageOutputArtifactPolicy`,
    /// the rule a sample's own record and the batch result keep). `build-db taxtriage` leaves the root record alone,
    /// deletes the cleanup list inside each sample folder, and those names then no longer find their files. A provenance
    /// check of such a result finds them missing. The command runs with the argv the app passes. The record beside the
    /// database is then the only `build-db` record in that root, and it names the top report that the cleanup of the
    /// same command deleted. Since 2.13 K1b the case lays the folders out itself and saves the root record a legacy
    /// batch holds, an empty run of the workflow `TaxTriage Serial Batch`, where the serial runner wrote both. No route
    /// wrote that record after 2.12 K1, but the batches of older projects keep it. A root record of `taxtriage run`
    /// takes the command's 2.10 X7 path instead, which keeps `top/` and that record's lineage (parity case X7).
    func testTheFilesABatchNamesAreThoseTheCleanupThenRemoves() async throws {
        let batch = root.appendingPathComponent("taxtriage-batch", isDirectory: true)
        let mini = fixture("taxtriage-mini")
        let odr = fixture("taxtriage-odr-3.3.8").appendingPathComponent("SRR12486983", isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        var named = Set<String>()
        for id in ["A", "B"] {
            let folder = batch.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.copyItem(at: id == "A" ? mini : odr, to: folder)
            if id == "A" { try FileManager.default.removeItem(at: folder.appendingPathComponent("minimap2", isDirectory: true)) }
            try Self.writeSeed(in: folder)
            let files = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            named.formUnion(TaxTriageOutputArtifactPolicy.filterRetainedOutputFiles(files, outputDirectory: folder).map { relative($0.path, to: batch) })
        }
        let runID = await ProvenanceRecorder.shared.beginRun(name: "TaxTriage Serial Batch")
        await ProvenanceRecorder.shared.completeRun(runID, status: .completed)
        try await ProvenanceRecorder.shared.save(runID: runID, to: batch)
        let recordURL = batch.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let recordBefore = try Data(contentsOf: recordURL)
        XCTAssertTrue(named.isSuperset(of: ["A/count/SRR35517702.fastq.gz", "A/top/SRR35517702.top_report.tsv", "B/mergedkrakenreport/SRR35517702.merged.report.txt"]))
        XCTAssertTrue(named.allSatisfy { exists($0, in: batch) }, "every name exists before build-db runs")

        try await buildDb(batch, ["--force"])

        XCTAssertEqual(try Data(contentsOf: recordURL), recordBefore, "build-db leaves a record of another workflow alone")
        let dangling = Set(named.filter { !exists($0, in: batch) })
        let expected = Set(["A", "B"].flatMap { id in Self.removedSeed.map { "\(id)/\($0)" } } + ["A/top/SRR35517702.top_report.tsv"])
        XCTAssertEqual(dangling, expected, "the record names these and they are gone")
        for kept in ["A/report/multiqc_data/multiqc_confidences.txt", "A/combine/SRR35517702.combined.gcfmap.tsv", "A/fastp/SRR35517702.fastp.html", "B/report/SRR12486983.odr.txt"] {
            XCTAssertTrue(named.contains(kept) && exists(kept, in: batch), kept)
        }
        let database = try TaxTriageDatabase(at: batch.appendingPathComponent("taxtriage.sqlite"))
        XCTAssertEqual(try database.fetchSamples().map(\.sample), ["SRR12486983", "SRR35517702", "SRR35517703", "SRR35517705"])
        XCTAssertTrue(exists("taxtriage.sqlite.lungfish-provenance.json", in: batch), "its own record is beside the database")

        let sidecar = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(
            fromSidecar: batch.appendingPathComponent("taxtriage.sqlite.lungfish-provenance.json")))
        let build = try XCTUnwrap(sidecar.steps.last)
        XCTAssertEqual(Array(build.argv.dropFirst()), ["build-db", "taxtriage", batch.path, "--force"], "the app's invocation")
        let sources = build.inputs.map { relative($0.path, to: batch) }
        XCTAssertEqual(
            sources.filter { !exists($0, in: batch) }, ["A/top/SRR35517702.top_report.tsv"],
            "the database record of the app's batch names the top report its own cleanup deleted, top/ stays under T5 in 2.9"
        )
    }
}
