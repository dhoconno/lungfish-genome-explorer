// EsVirituDetectExecutorTests.swift - lungfish-cli esviritu detect runs through the analysis run executor
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

/// `esviritu detect` on the analysis run executor (2.7 A9). A stand-in EsViritu writes the tables
/// of one `esviritu-mini` sample under the `-s` name it is given, or an empty detection table, so
/// no real tool runs. The fixture's detection table holds two detections and no BAM, so
/// `build-db esviritu` runs no samtools.
final class EsVirituDetectExecutorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "esviritu-detect-executor")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// The fixture sample's tables, without their suffix.
    private static var fixtureTables: URL {
        BuildDbStreamCapture.fixturesFolder.appendingPathComponent("esviritu-mini/SRR35517705/SRR35517705")
    }

    // MARK: - Layouts

    /// E2. A plain `--output` keeps the one folder the command has always written, with no
    /// database, summary or manifest, and its record is the root record of the command that ran,
    /// holding the pipeline's steps and the database identity of E9.
    func testAPlainOutputKeepsOneFolderAndRecordsTheCommandThatRan() async throws {
        let esviritu = try StandInEsViritu(root: root.appendingPathComponent("tool"), tables: Self.fixtureTables)
        let output = root.appendingPathComponent("out", isDirectory: true)
        let code = try await detect(["--input", try reads("S1").path, "--sample", "S1", "--output", output.path], esviritu)

        XCTAssertEqual(code, 0)
        let fileManager = FileManager.default
        XCTAssertTrue(fileManager.fileExists(atPath: output.appendingPathComponent("S1.detected_virus.info.tsv").path))
        XCTAssertTrue(fileManager.fileExists(atPath: output.appendingPathComponent("esviritu-result.json").path))
        XCTAssertFalse(fileManager.fileExists(atPath: output.appendingPathComponent("esviritu.sqlite").path))
        XCTAssertFalse(fileManager.fileExists(atPath: output.appendingPathComponent(EsVirituAnalysisRunTool.summaryFilename).path))

        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: output))
        XCTAssertEqual(record.workflowName, EsVirituAnalysisRunTool.workflowName)
        XCTAssertEqual(Array(record.argv.prefix(3)), [CLICommandIdentity.executableName, "esviritu", "detect"])
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.steps.map(\.toolName), ["EsViritu", "Lungfish EsViritu Result Sidecar"])
        XCTAssertEqual(record.options.explicit["sample"], .string("S1"), "the pipeline's run parameters")
        XCTAssertEqual(record.options.resolvedDefaults["databaseIdentityStatus"], .string("unpinned"))
        XCTAssertEqual(record.options.resolvedDefaults["databaseOrigin"], .string("installed"), "--db names the installed database")
        XCTAssertEqual(record.options.resolvedDefaults["databaseCatalogID"], .string("esviritu-viral-v3"))
        XCTAssertEqual(record.options.resolvedDefaults["databaseCoreFileSizes"], .dictionary([:]), "the stand-in database holds no core file")
        XCTAssertEqual(record.outputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }.sorted(), [
            "S1.detected_virus.assembly_summary.tsv", "S1.detected_virus.info.tsv",
            "S1.virus_coverage_windows.tsv", "esviritu-result.json",
        ])
        for output in record.outputs {
            XCTAssertTrue(fileManager.fileExists(atPath: output.path), "the record names \(output.path)")
        }
    }

    /// 2.13 lane 13.15, SW26 note 4 and BIO-13.15-SW26 item 2. The read format and `--paired` the user typed are
    /// explicit options of the root record, also of a run that fails before EsViritu starts. A bundle of single reads
    /// fails in its unit, once the bundle gives one file where paired reads need two.
    func testTheTypedReadFormatAndPairedAreExplicitInTheRootRecordOfAFailedRun() async throws {
        let esviritu = try StandInEsViritu(root: root.appendingPathComponent("tool"), tables: Self.fixtureTables)
        let shapes = try BundleShapeFixtures(in: root.appendingPathComponent("Imports", isDirectory: true))
        let output = root.appendingPathComponent("out", isDirectory: true)
        let code = try await detect(
            ["--input", shapes.single.path, "--sample", "S1", "--read-format", "paired", "--paired", "--output", output.path],
            esviritu
        )

        XCTAssertNotEqual(code, 0, "paired reads need two files")
        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: output))
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.options.explicit["readFormat"], .string("paired"))
        XCTAssertEqual(record.options.explicit["pairedEnd"], .boolean(true))
    }

    /// E1, R4 and BIO O5. A `--project` run of one sample makes the app's batch root, names the
    /// sample folder through the one sanitizer and gives EsViritu that name, so `build-db` keeps
    /// every detection of a dotted sample id. The root gets the summary, the manifest and the index,
    /// and the source bundle gets the entry the app writes for one sample.
    func testAProjectRunOfADottedSampleKeepsItsDetections() async throws {
        let project = try makeProject()
        let shapes = try BundleShapeFixtures(in: project.appendingPathComponent("Imports", isDirectory: true))
        let esviritu = try StandInEsViritu(root: root.appendingPathComponent("tool"), tables: Self.fixtureTables)
        let code = try await detect(
            ["--input", shapes.single.path, "--sample", "Patient.07", "--read-format", "unpaired", "--project", project.path],
            esviritu
        )

        XCTAssertEqual(code, 0)
        XCTAssertEqual(esviritu.samplesSeen, ["Patient_07"], "EsViritu's -s is the folder's name")
        let batch = try onlyAnalysis(in: project, prefix: "esviritu-batch-")
        let sample = batch.appendingPathComponent("Patient_07", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sample.appendingPathComponent("Patient_07.detected_virus.info.tsv").path))
        XCTAssertEqual(AnalysesFolder.readAnalysisMetadata(from: batch)?.tool, "esviritu")
        XCTAssertEqual(AnalysesFolder.readAnalysisMetadata(from: batch)?.isBatch, true)

        let database = try EsVirituDatabase(at: batch.appendingPathComponent("esviritu.sqlite"))
        XCTAssertEqual(try database.fetchSamples().map(\.sample), ["Patient_07"])
        XCTAssertEqual(try database.fetchRows(samples: ["Patient_07"]).count, 2, "R4: no detection is dropped")

        let summary = try String(contentsOf: batch.appendingPathComponent(EsVirituAnalysisRunTool.summaryFilename), encoding: .utf8)
        XCTAssertTrue(summary.hasPrefix("sample_id\tstatus\tvirus_count\tfamilies\tspecies\terror\nPatient_07\tok\t2\t"), summary)
        let manifest = try XCTUnwrap(MetagenomicsBatchResultStore.loadEsViritu(from: batch))
        XCTAssertEqual(manifest.samples.map(\.sampleId), ["Patient_07"])
        XCTAssertEqual(manifest.header.sampleCount, 1)

        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: batch))
        XCTAssertEqual(record.workflowName, EsVirituAnalysisRunTool.workflowName)
        XCTAssertTrue(record.steps.contains { $0.toolName == "EsViritu" })
        XCTAssertEqual(record.steps.last?.toolName, "lungfish build-db esviritu", "the index build is a step of the root record")
        XCTAssertTrue(record.outputs.contains { $0.path.hasSuffix("/esviritu.sqlite") })
        XCTAssertEqual(ProvenanceRecorder.loadEnvelope(from: sample)?.workflowName, "Viral Metagenomics Detection", "the sample keeps its own record")

        let entries = AnalysisManifestStore.load(bundleURL: shapes.single, projectURL: project).analyses
        XCTAssertEqual(entries.map(\.displayName), ["EsViritu Detection"])
        XCTAssertEqual(entries.first?.analysisDirectoryName, "\(batch.lastPathComponent)/Patient_07")
        XCTAssertTrue(entries.first?.summary.hasPrefix("2 viruses detected in ") == true)
    }

    /// E8. `--batch` groups the inputs into samples as the app's dialog does. A failed sample is a
    /// warning while another completes, and the summary lists it as failed, as in the app.
    func testABatchCompletesWhileOneSampleCompletesAndListsTheFailedOne() async throws {
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        let first = try reads("Alpha", in: inputs)
        let second = try reads("Beta", in: inputs)
        let esviritu = try StandInEsViritu(root: root.appendingPathComponent("tool"), tables: Self.fixtureTables, failSample: "Beta")
        let output = root.appendingPathComponent("batch", isDirectory: true)
        let code = try await detect(["--input", first.path, second.path, "--batch", "--output", output.path], esviritu)

        XCTAssertEqual(code, 0, "one sample completed")
        XCTAssertEqual(esviritu.samplesSeen, ["Alpha", "Beta"])
        let summary = try String(contentsOf: output.appendingPathComponent(EsVirituAnalysisRunTool.summaryFilename), encoding: .utf8)
        let summaryLines = summary.components(separatedBy: "\n")
        XCTAssertTrue(summaryLines[1].hasPrefix("Alpha\tok\t2\t2\t"), summary)
        // The error keeps EsViritu's stderr, quoted by the app's rule because it holds a line break.
        XCTAssertTrue(summaryLines[2].hasPrefix("Beta\tfailed\t\t\t\t\"EsViritu failed with exit code 1: stand-in failure for Beta"), summary)
        XCTAssertEqual(MetagenomicsBatchResultStore.loadEsViritu(from: output)?.samples.map(\.sampleId), ["Alpha"])
        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: output))
        XCTAssertEqual(record.status, .completed)
        XCTAssertTrue(record.stderr?.contains("Beta failed") == true, record.stderr ?? "")
        XCTAssertEqual(record.options.explicit["batch"], .boolean(true))
        XCTAssertNil(record.options.explicit["sample"], "a batch root keeps each sample's facts in the sample's record")
    }

    /// E9. Only the database the app installed records the catalog entry it came from, also when
    /// `--db` reaches it through a link. A folder the app did not install, such as an older
    /// release or a custom build, records its origin, its core file sizes and the unpinned status,
    /// and no catalog entry, which would not describe it.
    func testOnlyTheInstalledDatabaseRecordsItsCatalogEntry() async throws {
        let esviritu = try StandInEsViritu(root: root.appendingPathComponent("tool"), tables: Self.fixtureTables)
        try "ACGT\n".write(to: esviritu.databaseURL.appendingPathComponent("viral_refs.fna"), atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("installed-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: esviritu.databaseURL)
        let elsewhere = root.appendingPathComponent("installed-elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let catalogKeys = ["databaseCatalogID", "databaseCatalogVersion", "databaseSourceURL", "databaseSourcePolicy"]

        let linked = root.appendingPathComponent("linked", isDirectory: true)
        let linkedCode = try await detect(
            ["--input", try reads("S1").path, "--sample", "S1", "--output", linked.path], esviritu, installed: { _ in link }
        )
        XCTAssertEqual(linkedCode, 0)
        let installed = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: linked)).options.resolvedDefaults
        XCTAssertEqual(installed["databaseOrigin"], .string("installed"))
        for key in catalogKeys {
            XCTAssertNotNil(installed[key], key)
        }

        let given = root.appendingPathComponent("given", isDirectory: true)
        let givenCode = try await detect(
            ["--input", try reads("S1").path, "--sample", "S1", "--output", given.path], esviritu, installed: { _ in elsewhere }
        )
        XCTAssertEqual(givenCode, 0)
        let options = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: given)).options.resolvedDefaults
        XCTAssertEqual(options["databaseOrigin"], .string("given"))
        XCTAssertEqual(options["databaseIdentityStatus"], .string("unpinned"))
        XCTAssertEqual(options["databaseCoreFileSizes"], .dictionary(["viral_refs.fna": .integer(5)]))
        for key in catalogKeys {
            XCTAssertNil(options[key], "\(key) would name the catalog entry of another database")
        }
    }

    // MARK: - Refusals, failures and cancels

    /// Every refusal sits in the plan, so no folder is made, and each keeps its exit code.
    func testRefusalsLeaveNoFolderAndKeepTheirExitCodes() async throws {
        let esviritu = try StandInEsViritu(root: root.appendingPathComponent("tool"))
        let input = try reads("S1").path
        let output = root.appendingPathComponent("refused", isDirectory: true)
        let cases: [(arguments: [String], code: Int32)] = [
            (["--input", input, "--batch", "--sample", "S1", "--output", output.path], 3),
            (["--input", input, "--sample", "S1", "--read-format", "interleaved", "--paired", "--output", output.path], 3),
            (["--input", input, "--sample", "S1", "--project", try makeProject().path, "--output", output.path], 3),
            (["--input", input, "--batch"], 3),
            (["--sample", "S1", "--output", output.path], 3),
        ]
        for testCase in cases {
            let code = try await detect(testCase.arguments, esviritu)
            XCTAssertEqual(code, testCase.code, testCase.arguments.joined(separator: " "))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), testCase.arguments.joined(separator: " "))
        }
        let missingDatabase = try await detect(
            ["--input", input, "--sample", "S1", "--output", output.path],
            esviritu,
            database: false,
            installed: { _ in nil }
        )
        XCTAssertEqual(missingDatabase, 126)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    /// D10. A detection table whose columns changed fails the sample instead of reading as a run
    /// with nothing detected, and the failed run keeps its folder and its record (E5).
    func testADetectionTableWithAChangedColumnFailsTheRun() async throws {
        let tables = root.appendingPathComponent("changed/sample", isDirectory: false)
        try FileManager.default.createDirectory(at: tables.deletingLastPathComponent(), withIntermediateDirectories: true)
        let header = EsVirituDetectionParser.requiredColumns.filter { $0 != "read_count" }.joined(separator: "\t")
        try (header + "\n").write(to: URL(fileURLWithPath: tables.path + ".detected_virus.info.tsv"), atomically: true, encoding: .utf8)
        for suffix in ["virus_coverage_windows.tsv", "detected_virus.assembly_summary.tsv"] {
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: Self.fixtureTables.path + "." + suffix),
                to: URL(fileURLWithPath: tables.path + "." + suffix)
            )
        }
        let esviritu = try StandInEsViritu(root: root.appendingPathComponent("tool"), tables: tables)
        let output = root.appendingPathComponent("out", isDirectory: true)
        let code = try await detect(["--input", try reads("S1").path, "--sample", "S1", "--output", output.path], esviritu)

        XCTAssertEqual(code, AnalysisRunExitCode.workflowError)
        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: output))
        XCTAssertEqual(record.status, .failed)
        XCTAssertTrue(record.stderr?.contains("read_count") == true, record.stderr ?? "")
    }

    /// E5 and SWIFT X2. A cancel during EsViritu ends the run as cancelled with exit 125, from the
    /// cancel request and not from how the tool ended, and the claimed folder keeps its record.
    func testACancelDuringEsVirituRecordsCancelled() async throws {
        let project = try makeProject()
        let esviritu = try StandInEsViritu(root: root.appendingPathComponent("tool"), holdSample: "S1")
        let output = project.appendingPathComponent("Analyses/esviritu-cancel", isDirectory: true)
        let command = try parse(["--input", try reads("S1").path, "--sample", "S1", "--output", output.path], esviritu)
        let cancel = CancelFlag()
        let task = Task {
            await command.detect(
                pipeline: EsVirituPipeline(condaManager: esviritu.condaManager),
                materializer: FASTQCLIMaterializer(runner: .shared),
                installedDatabase: { [databaseURL = esviritu.databaseURL] in databaseURL },
                cancelRequested: { cancel.isSet }
            )
        }
        let deadline = Date().addingTimeInterval(30)
        while !esviritu.holdStarted, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(esviritu.holdStarted, "the stand-in started")
        cancel.set()
        task.cancel()
        let code = await task.value

        XCTAssertEqual(code, AnalysisRunExitCode.cancelled)
        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: output))
        XCTAssertEqual(record.status, .cancelled)
        XCTAssertTrue(record.files.contains { $0.path.hasSuffix("/S1.fastq") && $0.checksumSHA256 != nil }, "the inputs taken before EsViritu ran are named")
    }

    // MARK: - Events

    /// The executor's stream for one sample: `start`, the early `output` that names the folder,
    /// progress from 0 to 1, and one `complete` that types the detection table, the sidecar and the
    /// record.
    func testTheEventStreamNamesTheFolderEarlyAndTypesTheResult() async throws {
        let esviritu = try StandInEsViritu(root: root.appendingPathComponent("tool"), tables: Self.fixtureTables)
        let output = root.appendingPathComponent("out", isDirectory: true)
        let lines = LineSink()
        let tool = EsVirituAnalysisRunTool(
            options: EsVirituAnalysisRunOptions(sampleName: "S1", databasePath: esviritu.databaseURL, threads: 2),
            groupsSamples: false,
            pipeline: EsVirituPipeline(condaManager: esviritu.condaManager),
            materializer: FASTQCLIMaterializer(runner: .shared),
            installedDatabase: { [databaseURL = esviritu.databaseURL] in databaseURL }
        )
        let report = await AnalysisRunExecutor(services: AnalysisRunServices(indexing: EsVirituResultIndexing())).execute(
            tool,
            AnalysisRunRequest(
                inputs: [try reads("S1")],
                destination: .directory(output),
                commandLine: ["lungfish-cli", "esviritu", "detect"]
            ),
            events: AnalysisRunEvents { lines.append($0) }
        )

        XCTAssertEqual(report.exitCode, 0)
        XCTAssertEqual(report.message, "2 viruses detected in 2 families")
        let events = lines.all.compactMap(\.event)
        guard case .start? = events.first else { return XCTFail("no start: \(events)") }
        XCTAssertEqual(events.dropFirst().first, .output(path: output.path, role: CLIEventArtifact.Role.analysisDirectory))
        for case .progress(let fraction, _) in events {
            XCTAssertTrue((0...1).contains(fraction))
        }
        XCTAssertFalse(events.contains { if case .log(.warning, _) = $0 { return true }; return false })
        XCTAssertEqual(events.last, .complete(outputs: [output.path], message: "2 viruses detected in 2 families"))
        XCTAssertEqual(lines.all.last?.artifacts.map(\.role), [
            EsVirituAnalysisRunTool.ArtifactRole.detections,
            EsVirituAnalysisRunTool.ArtifactRole.resultSidecar,
            CLIEventArtifact.Role.provenance,
        ])
    }

    /// A8d review fix 1 (UX D11). A run of one sample whose EsViritu wrote no detection table ends
    /// in `failed` with the last lines of EsViritu's output as the line's `detail`, which the
    /// executor bounds, and the tail is no `error` log line headed `EsViritu log (last lines):`. A
    /// batch logs it instead (X1 review fix 2, the next test). The stand-in's tables do not exist,
    /// so it exits 0 after its copies fail on standard error.
    func testAFailedSampleSendsItsLogTailAsTheFailedLinesDetail() async throws {
        let esviritu = try StandInEsViritu(
            root: root.appendingPathComponent("tool"),
            tables: root.appendingPathComponent("no-tables/sample")
        )
        let output = root.appendingPathComponent("out", isDirectory: true)
        let lines = LineSink()
        let tool = EsVirituAnalysisRunTool(
            options: EsVirituAnalysisRunOptions(sampleName: "S1", databasePath: esviritu.databaseURL, threads: 2),
            groupsSamples: false,
            pipeline: EsVirituPipeline(condaManager: esviritu.condaManager),
            materializer: FASTQCLIMaterializer(runner: .shared),
            installedDatabase: { [databaseURL = esviritu.databaseURL] in databaseURL }
        )
        let report = await AnalysisRunExecutor(services: AnalysisRunServices(indexing: EsVirituResultIndexing())).execute(
            tool,
            AnalysisRunRequest(
                inputs: [try reads("S1")],
                destination: .directory(output),
                commandLine: ["lungfish-cli", "esviritu", "detect"]
            ),
            events: AnalysisRunEvents { lines.append($0) }
        )

        XCTAssertEqual(report.exitCode, AnalysisRunExitCode.workflowError)
        let events = lines.all.compactMap(\.event)
        guard case .failed(let message, let detail)? = events.last else { return XCTFail("no failed line: \(events)") }
        XCTAssertEqual(message, report.message)
        XCTAssertTrue(message.hasPrefix("EsViritu did not produce a detection output at "), message)
        let tail = try XCTUnwrap(detail, "the failed line carries EsViritu's tail")
        XCTAssertTrue(tail.hasSuffix("EsViritu stand-in finished"), tail)
        XCTAssertTrue(tail.contains("No such file or directory"), tail)
        XCTAssertFalse(events.contains { event in
            if case .log(_, let text) = event { return text.hasPrefix("EsViritu log (last lines):") }
            return false
        }, "the tail is not logged")
    }

    /// X1 review fix 2 (UX D6, E15). A sample of a batch that fails while another completes sends
    /// its log tail as one `error` log line headed as the app's batch row has always written it,
    /// since no `failed` line carries it. The tail line comes before the sample's warning, the run
    /// completes, and no file of the result holds the tail, since the journal keeps warnings only.
    func testAFailedSampleOfABatchLogsItsLogTailAsOneErrorLine() async throws {
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        let first = try reads("Alpha", in: inputs)
        let second = try reads("Beta", in: inputs)
        let esviritu = try StandInEsViritu(
            root: root.appendingPathComponent("tool"),
            tables: Self.fixtureTables,
            missSample: "Alpha"
        )
        let output = root.appendingPathComponent("batch", isDirectory: true)
        let lines = LineSink()
        let command = try parse(["--input", first.path, second.path, "--batch", "--output", output.path], esviritu)
        let code = await command.detect(
            pipeline: EsVirituPipeline(condaManager: esviritu.condaManager),
            materializer: FASTQCLIMaterializer(runner: .shared),
            installedDatabase: { [databaseURL = esviritu.databaseURL] in databaseURL },
            cancelRequested: { false },
            events: AnalysisRunEvents { lines.append($0) }
        )

        XCTAssertEqual(code, 0, "one sample completed")
        XCTAssertEqual(esviritu.samplesSeen, ["Alpha", "Beta"])
        let events = lines.all.compactMap(\.event)
        let tailIndexes = events.indices.filter { index in
            if case .log(.error, let text) = events[index] { return text.hasPrefix("EsViritu log (last lines):") }
            return false
        }
        XCTAssertEqual(tailIndexes.count, 1, "one tail line, for the sample that failed")
        guard let tailIndex = tailIndexes.first, case .log(_, let tail) = events[tailIndex] else {
            return XCTFail("no tail line: \(events)")
        }
        XCTAssertTrue(tail.hasPrefix(EsVirituAnalysisRunTool.logTailHeading), tail)
        XCTAssertTrue(tail.hasSuffix("stand-in finished without a detection table for Alpha"), tail)
        let warningIndex = events.firstIndex { event in
            if case .log(.warning, let text) = event { return text.hasPrefix("Alpha failed: ") }
            return false
        }
        XCTAssertLessThan(tailIndex, warningIndex ?? .min, "the unit logs the tail before the executor reports the failure")
        guard case .complete? = events.last else { return XCTFail("no complete line: \(events)") }
        XCTAssertFalse(events.contains { if case .failed = $0 { return true }; return false }, "no failed line carries a tail")
        XCTAssertEqual(try filesHolding("EsViritu log (last lines)", under: output), [], "no record holds the tail")
    }

    /// The paths under `folder` of the files whose bytes hold `text`.
    private func filesHolding(_ text: String, under folder: URL) throws -> [String] {
        let needle = Data(text.utf8)
        var found: [String] = []
        var scanned = 0
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            scanned += 1
            if try Data(contentsOf: url).range(of: needle) != nil {
                found.append(String(url.path.dropFirst(folder.path.count)))
            }
        }
        XCTAssertGreaterThan(scanned, 0, "the result folder holds files")
        return found
    }

    /// A10 review fix 5 (UX D5, D14). The lines a virtual bundle's materialization reports are
    /// progress at the start of its sample, so the app's row shows each as its detail and in the
    /// viewer's overlay, and none is a log line. Text mode prints them through the reporter.
    func testMaterializationLinesAreProgressAtTheStartOfTheSample() async throws {
        let shapes = try BundleShapeFixtures(in: root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true))
        let esviritu = try StandInEsViritu(root: root.appendingPathComponent("tool"))
        let output = root.appendingPathComponent("out", isDirectory: true)
        let lines = LineSink()
        let materializing = ["Materializing oriented.lungfishfastq", "Wrote the oriented reads"]
        let tool = EsVirituAnalysisRunTool(
            options: EsVirituAnalysisRunOptions(
                sampleName: "sample", readFormat: .unpaired, databasePath: esviritu.databaseURL, threads: 2
            ),
            groupsSamples: false,
            pipeline: EsVirituPipeline(condaManager: esviritu.condaManager),
            materializer: ReportingMaterializer(lines: materializing),
            installedDatabase: { [databaseURL = esviritu.databaseURL] in databaseURL }
        )
        let report = await AnalysisRunExecutor(services: AnalysisRunServices(indexing: EsVirituResultIndexing())).execute(
            tool,
            AnalysisRunRequest(
                inputs: [shapes.oriented],
                destination: .directory(output),
                commandLine: ["lungfish-cli", "esviritu", "detect"]
            ),
            events: AnalysisRunEvents { lines.append($0) }
        )

        XCTAssertEqual(report.exitCode, 0, report.message)
        let events = lines.all.compactMap(\.event)
        XCTAssertEqual(
            events.filter { event in
                if case .progress(_, let message) = event { return materializing.contains(message) }
                return false
            },
            materializing.map { CLIEvent.progress(fraction: 0, message: $0) }
        )
        XCTAssertFalse(events.contains { event in
            if case .log(_, let message) = event { return materializing.contains(message) }
            return false
        }, "no materialization line is a log line")
    }

    /// W4 of Phase 2.10 (U34). A pointer dataset reports `Writing the reads to a FASTQ file…` while the
    /// materializer copies its reads, where it read `Materializing pointer dataset...`. The same line
    /// heads the golden `classifiers/esviritu/materialize.txt` and the two stdout goldens beside it.
    func testAPointerDatasetReportsItsMaterializationInPlainWords() async throws {
        let shapes = try BundleShapeFixtures(in: root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true))
        let work = root.appendingPathComponent("materialized", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let reported = ProgressLines()

        _ = try await FASTQCLIMaterializer(runner: .shared).materialize(
            bundleURL: shapes.full, tempDirectory: work, progress: { reported.append($0) }
        )

        XCTAssertEqual(reported.all, ["Writing the reads to a FASTQ file\u{2026}"])
    }

    /// W4 (U34). An index that cannot be built is the one sentence the app's row logs, where the batch root wrote
    /// `Database build failed: <error>`, a dash and `batch will rebuild lazily on open`. The run completes with
    /// that warning.
    func testAnIndexThatCannotBeBuiltIsOneSentence() async throws {
        let run = try await executeInProject(groupsSamples: false, indexing: FailingIndexer())

        XCTAssertEqual(run.report.status, .completed, run.report.message)
        XCTAssertEqual(
            run.report.warnings,
            ["The viewer index could not be built (disk full). LGE builds it when the result opens."]
        )
    }

    /// W4 (U34). A run of one sample into a project writes the summary of that one sample and says so, where
    /// it said `Writing the EsViritu batch summary…`. A `--batch` run groups samples and keeps the batch words.
    func testASummaryIsCalledABatchSummaryOnlyWhenTheRunGroupsSamples() async throws {
        let single = try await executeInProject(groupsSamples: false, indexing: EsVirituResultIndexing())
        let grouped = try await executeInProject(groupsSamples: true, indexing: EsVirituResultIndexing())

        XCTAssertEqual(single.report.status, .completed, single.report.message)
        XCTAssertEqual(grouped.report.status, .completed, grouped.report.message)
        XCTAssertEqual(Self.summaryProgress(of: single.events), ["Writing the EsViritu summary\u{2026}"])
        XCTAssertEqual(Self.summaryProgress(of: grouped.events), ["Writing the EsViritu batch summary\u{2026}"])
    }

    /// W4 (U34). In text mode a single run prints the tail of EsViritu's log under the heading the app puts over
    /// it, after the failure line, where the tail's lines followed the failure line bare. The `failed` event
    /// still carries the tail without a heading, since the app adds its own.
    func testTheTextModeTailOfASingleRunHasItsHeading() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let events = EsVirituTextReporter.events(useColors: false, quiet: false, namesResultFolder: false)

        let output = try await ImportStreamCapture.capture(in: scratch) {
            events.emit(.failed(message: "EsViritu failed", detail: "line 1\nline 2"))
        }

        XCTAssertNil(output.thrown)
        XCTAssertEqual(output.standardOutput, [])
        XCTAssertEqual(output.standardError, [
            TerminalFormatter(useColors: false).error("EsViritu failed"),
            "EsViritu log (last lines):",
            "line 1",
            "line 2",
        ])
    }

    // MARK: - Helpers

    /// The progress messages that name the summary the finalize writes.
    private static func summaryProgress(of events: [CLIEvent]) -> [String] {
        events.compactMap { event in
            if case .progress(_, let message) = event, message.hasPrefix("Writing the EsViritu") { return message }
            return nil
        }
    }

    /// An index builder that cannot build, as a full disk stops the `build-db esviritu` core.
    private struct FailingIndexer: AnalysisResultIndexing {
        struct Failure: LocalizedError {
            var errorDescription: String? { "disk full" }
        }

        func buildIndex(_ request: AnalysisResultIndexRequest) async throws -> AnalysisResultIndex {
            throw Failure()
        }
    }

    /// Runs the tool on the one sample of `shapes.single` into a project, as `esviritu detect --project` does,
    /// or as `--batch` does when `groupsSamples`, with `indexing` as the executor's index builder.
    private func executeInProject(
        groupsSamples: Bool,
        indexing: any AnalysisResultIndexing
    ) async throws -> (report: AnalysisRunReport, events: [CLIEvent]) {
        let project = try makeProject()
        let shapes = try BundleShapeFixtures(in: project.appendingPathComponent("Imports", isDirectory: true))
        let esviritu = try StandInEsViritu(
            root: root.appendingPathComponent("tool-\(UUID().uuidString)"), tables: Self.fixtureTables
        )
        let lines = LineSink()
        // A `--batch` run names each sample after its files and plans its layout, so it takes no `--sample`.
        let tool = EsVirituAnalysisRunTool(
            options: EsVirituAnalysisRunOptions(
                sampleName: groupsSamples ? nil : "S1",
                readFormat: groupsSamples ? .auto : .unpaired,
                databasePath: esviritu.databaseURL,
                threads: 2
            ),
            groupsSamples: groupsSamples,
            pipeline: EsVirituPipeline(condaManager: esviritu.condaManager),
            materializer: FASTQCLIMaterializer(runner: .shared),
            installedDatabase: { [databaseURL = esviritu.databaseURL] in databaseURL }
        )
        let report = await AnalysisRunExecutor(services: AnalysisRunServices(indexing: indexing)).execute(
            tool,
            AnalysisRunRequest(
                inputs: [shapes.single],
                destination: .project(project),
                groupsSamples: groupsSamples,
                commandLine: ["lungfish-cli", "esviritu", "detect", "--project", project.path]
            ),
            events: AnalysisRunEvents { lines.append($0) }
        )
        return (report, lines.all.compactMap(\.event))
    }

    /// The progress lines a materializer reported, in order.
    private final class ProgressLines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func append(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            lines.append(line)
        }

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }
    }

    /// `FASTQCLIMaterializer`, reporting `lines` as its own progress first.
    private struct ReportingMaterializer: CLISequenceInputMaterializing, Sendable {
        let lines: [String]

        func materialize(
            bundleURL: URL,
            tempDirectory: URL,
            progress: (@Sendable (String) -> Void)?
        ) async throws -> URL {
            lines.forEach { progress?($0) }
            return try await FASTQCLIMaterializer(runner: .shared).materialize(
                bundleURL: bundleURL,
                tempDirectory: tempDirectory,
                progress: nil
            )
        }
    }

    private final class LineSink: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [CLIEventLine] = []
        func append(_ line: CLIEventLine) { lock.withLock { lines.append(line) } }
        var all: [CLIEventLine] { lock.withLock { lines } }
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    private func reads(_ name: String, in folder: URL? = nil) throws -> URL {
        let folder = folder ?? root.appendingPathComponent("reads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(name).fastq")
        try "@\(name)-1\nACGTACGT\n+\nIIIIIIII\n@\(name)-2\nACGTACGT\n+\nIIIIIIII\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeProject() throws -> URL {
        let project = root.appendingPathComponent("Project-\(UUID().uuidString.prefix(6)).lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }

    private func onlyAnalysis(in project: URL, prefix: String) throws -> URL {
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        let folders = try FileManager.default.contentsOfDirectory(at: analyses, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
        XCTAssertEqual(folders.count, 1, "\(folders)")
        return try XCTUnwrap(folders.first)
    }

    private func parse(_ arguments: [String], _ esviritu: StandInEsViritu, database: Bool = true) throws -> EsVirituCommand.DetectSubcommand {
        let parsed = try LungfishCLI.parseAsRoot(
            ["esviritu", "detect"] + arguments + (database ? ["--db", esviritu.databaseURL.path] : []) + ["--threads", "2", "--quiet"]
        )
        return try XCTUnwrap(parsed as? EsVirituCommand.DetectSubcommand)
    }

    /// Runs the command with the stand-in and returns its exit code. `installed` names the database
    /// the app installed, by default the stand-in's, so the record holds its catalog entry (E9).
    private func detect(
        _ arguments: [String],
        _ esviritu: StandInEsViritu,
        database: Bool = true,
        installed: (StandInEsViritu) -> URL? = { $0.databaseURL }
    ) async throws -> Int32 {
        let command = try parse(arguments, esviritu, database: database)
        let installedURL = installed(esviritu)
        do {
            try await command.execute(
                pipeline: EsVirituPipeline(condaManager: esviritu.condaManager),
                materializer: FASTQCLIMaterializer(runner: .shared),
                installedDatabase: { installedURL }
            )
            return 0
        } catch let exit as ExitCode {
            return exit.rawValue
        }
    }
}
