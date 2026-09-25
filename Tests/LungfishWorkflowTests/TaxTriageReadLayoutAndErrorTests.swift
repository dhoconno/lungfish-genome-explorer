// TaxTriageReadLayoutAndErrorTests.swift - Interleaved pairs, errored tasks, and host taxa removal
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class TaxTriageReadLayoutAndErrorTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageReadLayoutAndErrorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - Fixtures

    private func record(_ name: String, _ sequence: String = "ACGTACGTAC") -> String {
        "@\(name)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
    }

    private func writeFASTQ(_ name: String, _ records: [String]) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try records.joined().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func interleavedFASTQ() throws -> URL {
        try writeFASTQ("patient.fastq", (1...4).flatMap { index in
            [record("read\(index)/1", "AAAAAAAAAA"), record("read\(index)/2", "CCCCCCCCCC")]
        })
    }

    private func config(samples: [TaxTriageSample]) -> TaxTriageConfig {
        TaxTriageConfig(
            samples: samples,
            outputDirectory: tempDirectory.appendingPathComponent("out", isDirectory: true)
        )
    }

    /// Trimmed from the failed corneal run (taxtriage-batch-2026-09-24T23-43-06/SRR12486983).
    private let failedRunTrace = """
        task_id\thash\tnative_id\tname\tstatus\texit\tsubmit\tduration\trealtime\t%cpu\tpeak_rss\tpeak_vmem\trchar\twchar
        6\t5d/df24ae\t27773\tNFCORE_TAXTRIAGE:TAXTRIAGE:CLASSIFIER:KRAKEN2_KRAKEN2 (SRR12486983)\tCOMPLETED\t0\t2026-09-24 23:45:21.524\t23.9s\t24s\t275.5%\t15.3 GB\t17.9 GB\t16.1 GB\t275 MB
        17\te9/5fa36b\t31544\tNFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:MINIMAP2_ALIGN (SRR12486983.SRR12486983.dwnld.references)\tFAILED\t137\t2026-09-24 23:50:39.126\t39.1s\t39s\t-\t-\t-\t-\t-
        18\t9c/c0405a\t31967\tNFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:MINIMAP2_ALIGN (SRR12486983.SRR12486983.dwnld.references)\tFAILED\t137\t2026-09-24 23:51:18.237\t37.4s\t37.3s\t-\t-\t-\t-\t-
        19\t22/099e0f\t32362\tNFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:MINIMAP2_ALIGN (SRR12486983.SRR12486983.dwnld.references)\tFAILED\t137\t2026-09-24 23:51:55.663\t37.4s\t37.4s\t-\t-\t-\t-\t-
        20\td1/e348f0\t32979\tNFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:MINIMAP2_ALIGN (SRR12486983.SRR12486983.dwnld.references)\tFAILED\t137\t2026-09-24 23:52:33.316\t37.9s\t37.8s\t-\t-\t-\t-\t-
        22\t29/fb5caa\t33694\tNFCORE_TAXTRIAGE:TAXTRIAGE:MULTIQC\tCOMPLETED\t0\t2026-09-24 23:53:11.276\t5.7s\t4.9s\t219.5%\t137.1 MB\t5.2 GB\t72.8 MB\t18.6 MB

        """

    private let failedRunLog = """
        [PROCESS d1/e348f0] NFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:MINIMAP2_ALIGN (SRR12486983.SRR12486983.dwnld.references)
        [ERROR] NFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:MINIMAP2_ALIGN (SRR12486983.SRR12486983.dwnld.references)
        exit: 137
        cmd: # Abort on any command failure (and on a failure anywhere in a pipe) so a failed ...
        stderr: WARNING: The requested image's platform (linux/amd64) does not match the detected host platform (linux/arm64/v8) and no specific platform was requested | /var/folders/x/work/d1/e348f0/.command.sh: line 23:    45 Killed                  minimap2 -ax sr -t 14 --split-prefix SRR12486983.prefix SRR12486983.dwnld.references.fasta SRR12486983.fastp.fastq.gz -f 0.0009 -L -a -o SRR12486983.unsorted.sam
        workdir: /var/folders/x/work/d1/e348f0
        [PROCESS 29/fb5caa] NFCORE_TAXTRIAGE:TAXTRIAGE:MULTIQC
        -[nf-core/taxtriage] Pipeline completed successfully, but with errored process(es) -
        [FAILED] completed=22 failed=4 cached=0
        """

    // MARK: - Interleaved pairs (Task A)

    func testStrictlyInterleavedSampleIsSplitAndWrittenAsFastq1AndFastq2() async throws {
        let interleaved = try interleavedFASTQ()
        let original = config(samples: [TaxTriageSample(sampleId: "patient", fastq1: interleaved)])
        let splitRoot = tempDirectory.appendingPathComponent(TaxTriagePipeline.interleavedSplitDirectoryName)

        let prepared = try await TaxTriagePipeline.splitStrictlyInterleavedSamples(in: original, splitRoot: splitRoot)

        XCTAssertEqual(prepared.splits.map(\.sampleId), ["patient"])
        XCTAssertEqual(prepared.splits.first?.pairCount, 4)
        let sample = try XCTUnwrap(prepared.config.samples.first)
        let r2 = try XCTUnwrap(sample.fastq2)
        XCTAssertTrue(sample.fastq1.path.hasPrefix(splitRoot.path))
        XCTAssertEqual(sample.readLayout, .pairedFiles)

        let r1Text = try String(contentsOf: sample.fastq1, encoding: .utf8)
        let r2Text = try String(contentsOf: r2, encoding: .utf8)
        XCTAssertTrue(r1Text.contains("@read1/1") && !r1Text.contains("/2\n"))
        XCTAssertTrue(r2Text.contains("@read4/2") && !r2Text.contains("/1\n"))

        let csv = TaxTriageSamplesheet.generate(from: TaxTriagePipeline.samplesheetEntries(for: prepared.config))
        let row = try XCTUnwrap(csv.split(separator: "\n").dropFirst().first).split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(row[0], "patient")
        XCTAssertEqual(String(row[1]), sample.fastq1.path)
        XCTAssertEqual(String(row[2]), r2.path, "fastq_2 must carry the R2 half, not be empty")
        XCTAssertEqual(row[3], "ILLUMINA")

        // The durable config the result records still names the interleaved file.
        XCTAssertEqual(original.samples[0].fastq1, interleaved)
        XCTAssertNil(original.samples[0].fastq2)
    }

    func testSingleEndMixedLongReadAndPairedSamplesAreNotSplit() async throws {
        let singleEnd = try writeFASTQ("single.fastq", (1...6).map { record("solo\($0)") })
        let mixed = try writeFASTQ("mixed.fastq", [
            record("pairA/1"), record("pairA/2"), record("merged1"), record("pairB/1"), record("pairB/2"), record("merged2"),
        ])
        let interleaved = try interleavedFASTQ()
        let r1 = try writeFASTQ("x_R1.fastq", [record("a/1")])
        let r2 = try writeFASTQ("x_R2.fastq", [record("a/2")])
        let samples = [
            TaxTriageSample(sampleId: "single", fastq1: singleEnd),
            TaxTriageSample(sampleId: "mixed", fastq1: mixed),
            TaxTriageSample(sampleId: "ont", fastq1: interleaved, platform: .oxford),
            TaxTriageSample(sampleId: "hinted-mixed", fastq1: interleaved, readLayout: .mixedMergedAndPairs),
            TaxTriageSample(sampleId: "pairs", fastq1: r1, fastq2: r2),
        ]
        let original = config(samples: samples)

        let prepared = try await TaxTriagePipeline.splitStrictlyInterleavedSamples(
            in: original,
            splitRoot: tempDirectory.appendingPathComponent("split")
        )

        XCTAssertTrue(prepared.splits.isEmpty)
        XCTAssertEqual(prepared.config.samples, original.samples)
        let entries = TaxTriagePipeline.samplesheetEntries(for: prepared.config)
        XCTAssertEqual(entries.map(\.isPairedEnd), [false, false, false, false, true])
    }

    // MARK: - Errored processes (Task B1)

    func testTraceFailuresWithExhaustedRetriesAreDetected() {
        let failures = TaxTriageResult.parseExhaustedTraceFailures(fromTraceText: failedRunTrace)

        XCTAssertEqual(failures.count, 1)
        let failure = try? XCTUnwrap(failures.first)
        XCTAssertEqual(failure?.processName, "MINIMAP2_ALIGN")
        XCTAssertEqual(failure?.processPath, "NFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:MINIMAP2_ALIGN")
        XCTAssertEqual(failure?.taskLabel, "SRR12486983.SRR12486983.dwnld.references")
        XCTAssertEqual(failure?.sampleID, "SRR12486983")
        XCTAssertEqual(failure?.exitCode, 137)
        XCTAssertEqual(failure?.attempts, 4)
        XCTAssertEqual(failure?.isOutOfMemory, true)
    }

    func testTaskThatSucceededOnRetryIsNotAnErroredTask() {
        let trace = """
            task_id\tname\tstatus\texit
            1\tP:ALIGN (S1)\tFAILED\t137
            2\tP:ALIGN (S1)\tCOMPLETED\t0
            3\tP:REPORT (S1)\tCACHED\t0
            4\tP:ALIGN (S2)\tFAILED\t1
            """
        let failures = TaxTriageResult.parseExhaustedTraceFailures(fromTraceText: trace)
        XCTAssertEqual(failures.map(\.taskLabel), ["S2"])
        XCTAssertEqual(failures.first?.exitCode, 1)
        XCTAssertEqual(failures.first?.attempts, 1)
    }

    func testLogErrorBlockSuppliesKillAsKeyStderrLine() {
        let diagnostics = TaxTriageResult.parseErroredTaskDiagnostics(fromNextflowLogText: failedRunLog)
        let key = "NFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:MINIMAP2_ALIGN\u{1}SRR12486983.SRR12486983.dwnld.references"
        let diagnostic = try? XCTUnwrap(diagnostics[key])
        XCTAssertEqual(diagnostic?.hasPrefix("Killed: minimap2 -ax sr -t 14"), true, diagnostic ?? "nil")
        XCTAssertEqual(diagnostic?.contains("requested image's platform"), false)
        XCTAssertEqual(TaxTriageResult.parseFailedTaskCount(fromNextflowLogText: failedRunLog), 4)
    }

    func testDetectErroredProcessesMergesTraceAndLogAndNamesOutOfMemory() {
        let failures = TaxTriageResult.detectErroredProcesses(
            nextflowLogText: failedRunLog,
            traceText: failedRunTrace,
            outputDirectory: tempDirectory
        )
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.attempts, 4)
        XCTAssertEqual(failures.first?.diagnostic?.hasPrefix("Killed:"), true)

        let message = TaxTriageResult.erroredProcessesMessage(for: failures, hostTaxaExcluded: false)
        XCTAssertEqual(
            TaxTriageResult.erroredProcessesHeadline(for: failures),
            "TaxTriage completed with errors: MINIMAP2_ALIGN failed for SRR12486983 after 4 attempts (Killed: out of memory)"
        )
        XCTAssertEqual(message?.contains("TASS scores"), true)
        XCTAssertEqual(message?.contains("Exclude host taxa (9606 for human)"), true)
        XCTAssertEqual(
            TaxTriageResult.erroredProcessesMessage(for: failures, hostTaxaExcluded: true)?.contains("Exclude host taxa"),
            false
        )
    }

    func testCompletionBannerAloneStillMarksTheRun() {
        let failures = TaxTriageResult.detectErroredProcesses(
            nextflowLogText: failedRunLog,
            traceText: nil,
            outputDirectory: tempDirectory
        )
        // The [ERROR] block names no trace rows, so the NOTE/trace sources are
        // empty; the banner makes one unnamed failure carrying failed=4.
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.processName, "")
        XCTAssertEqual(failures.first?.attempts, 4)
        XCTAssertEqual(
            TaxTriageResult.erroredProcessesHeadline(for: failures),
            "TaxTriage completed with errors: Nextflow reported 4 failed task attempts without naming the process (see nextflow.log)"
        )
    }

    func testCleanRunHasNoErroredProcesses() {
        let failures = TaxTriageResult.detectErroredProcesses(
            nextflowLogText: "[SUCCESS] completed=22 failed=0 cached=0\n",
            traceText: "task_id\tname\tstatus\texit\n1\tP:A (S1)\tCOMPLETED\t0\n",
            outputDirectory: tempDirectory
        )
        XCTAssertTrue(failures.isEmpty)
        XCTAssertNil(TaxTriageResult.erroredProcessesMessage(for: failures, hostTaxaExcluded: false))
    }

    func testResultRecordsErroredProcessesAndCompletedWithErrorsInJSON() throws {
        let failures = TaxTriageResult.detectErroredProcesses(
            nextflowLogText: failedRunLog,
            traceText: failedRunTrace,
            outputDirectory: tempDirectory
        )
        let result = TaxTriageResult(
            config: config(samples: [TaxTriageSample(sampleId: "SRR12486983", fastq1: URL(fileURLWithPath: "/data/a.fastq"))]),
            runtime: 1,
            exitCode: 0,
            outputDirectory: tempDirectory,
            ignoredFailures: failures
        )
        XCTAssertTrue(result.completedWithErrors)
        try result.save()

        let json = try String(contentsOf: tempDirectory.appendingPathComponent("taxtriage-result.json"), encoding: .utf8)
        XCTAssertTrue(json.contains("\"ignoredFailures\""))
        XCTAssertTrue(json.contains("\"attempts\" : 4"))
        XCTAssertTrue(json.contains("\"diagnostic\" : \"Killed:"))

        let reloaded = try TaxTriageResult.load(from: tempDirectory)
        XCTAssertEqual(reloaded.ignoredFailures, failures)
        XCTAssertTrue(reloaded.completedWithErrors)
    }

    func testLegacyIgnoredFailureWithoutNewFieldsStillDecodes() throws {
        let legacy = #"{"processPath":"P:ALIGNMENT_PER_SAMPLE","processName":"ALIGNMENT_PER_SAMPLE","taskLabel":"S1","sampleID":"S1","exitCode":1}"#
        let failure = try JSONDecoder().decode(TaxTriageIgnoredFailure.self, from: Data(legacy.utf8))
        XCTAssertNil(failure.attempts)
        XCTAssertNil(failure.diagnostic)
        XCTAssertFalse(failure.isOutOfMemory)
    }

    // MARK: - Host taxa removal (Task B2)

    func testDefaultRemoveTaxidsIsHumanWhenAnySampleIsClinical() {
        XCTAssertEqual(TaxTriageConfig.defaultRemoveTaxids(sampleRoles: [.testSample]), "9606")
        XCTAssertEqual(TaxTriageConfig.defaultRemoveTaxids(sampleRoles: [.negativeControl, .testSample]), "9606")
        XCTAssertEqual(TaxTriageConfig.defaultRemoveTaxids(sampleRoles: [.negativeControl, .extractionBlank]), "")
        XCTAssertEqual(TaxTriageConfig.defaultRemoveTaxids(sampleRoles: []), "")
    }

    func testTaxIDListNormalizationAndValidation() {
        XCTAssertEqual(TaxTriageConfig.normalizedTaxIDList(" 9606, 10090 9606 "), "9606 10090")
        XCTAssertEqual(TaxTriageConfig.normalizedTaxIDList("\"9606 2\""), "9606 2")
        XCTAssertNil(TaxTriageConfig.normalizedTaxIDList("  "))
        XCTAssertEqual(TaxTriageConfig.invalidTaxIDTokens(in: "9606 human -1 0"), ["human", "-1", "0"])
        XCTAssertEqual(TaxTriageConfig.invalidTaxIDTokens(in: "9606 10090"), [])
    }

    func testRemoveTaxidsReachesNextflowArgumentsAndProvenance() throws {
        var config = config(samples: [TaxTriageSample(sampleId: "S1", fastq1: URL(fileURLWithPath: "/data/a.fastq"))])
        config.removeTaxids = "9606 10090"
        let pipeline = TaxTriagePipeline()

        let args = pipeline.buildNextflowArguments(config: config)
        let index = try XCTUnwrap(args.firstIndex(of: "--remove_taxids"))
        XCTAssertEqual(args[index + 1], "9606 10090", "the list is one argument, as TaxTriage expects")
        XCTAssertTrue(config.nextflowArguments().contains("--remove_taxids"))
        XCTAssertEqual(pipeline.provenanceParameters(for: config)["remove_taxids"], .string("9606 10090"))
        XCTAssertEqual(config.summaryParameters()["removeTaxids"], .string("9606 10090"))

        let decoded = try JSONDecoder().decode(TaxTriageConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.removeTaxids, "9606 10090")
    }

    func testExtraArgumentsRemoveTaxidsWinsOverTheField() {
        for extra in [["--remove_taxids", "2"], ["--remove_taxids=2"]] {
            var config = config(samples: [TaxTriageSample(sampleId: "S1", fastq1: URL(fileURLWithPath: "/data/a.fastq"))])
            config.removeTaxids = "9606"
            config.extraArguments = extra
            XCTAssertNil(config.effectiveRemoveTaxids)
            let args = TaxTriagePipeline().buildNextflowArguments(config: config)
            XCTAssertEqual(args.filter { $0.hasPrefix("--remove_taxids") }.count, 1, "\(extra)")
            XCTAssertFalse(args.contains("9606"))
        }
    }

    func testNoRemoveTaxidsPassesNothing() {
        let config = config(samples: [TaxTriageSample(sampleId: "S1", fastq1: URL(fileURLWithPath: "/data/a.fastq"))])
        XCTAssertFalse(TaxTriagePipeline().buildNextflowArguments(config: config).contains("--remove_taxids"))
        XCTAssertEqual(TaxTriagePipeline().provenanceParameters(for: config)["remove_taxids"], .string(""))
    }

    func testInvalidRemoveTaxidsFailsValidation() throws {
        let fastq = try writeFASTQ("v.fastq", [record("r1")])
        var config = config(samples: [TaxTriageSample(sampleId: "S1", fastq1: fastq)])
        config.removeTaxids = "human"
        XCTAssertThrowsError(try config.validate()) { error in
            guard case TaxTriageConfigError.invalidRemoveTaxids(let tokens) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(tokens, ["human"])
        }
    }
}
