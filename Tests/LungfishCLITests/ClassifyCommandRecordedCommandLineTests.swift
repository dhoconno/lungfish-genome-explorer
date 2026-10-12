// ClassifyCommandRecordedCommandLineTests.swift - kraken2 classify records its own command when a test runs it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCLI
import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

/// Row 424 of Phase 2.7, closed in Phase 2.8. `kraken2 classify` hands the executor the command
/// line its root record names. A test runs the command inside another process, where
/// `CommandLine.arguments` is the test runner's, so the record must name the command that ran, as
/// the one `esviritu detect` records does. A stand-in kraken2 lets the whole command run.
final class ClassifyCommandRecordedCommandLineTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "classify-recorded-command")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testARunInThisProcessRecordsKraken2ClassifyAndNotTheTestRunner() async throws {
        let kraken2 = try ReadSetStandInKraken2(root: root.appendingPathComponent("tool", isDirectory: true))
        let reads = root.appendingPathComponent("sample.fastq")
        try "@r1\nACGTACGT\n+\nIIIIIIII\n@r2\nACGTACGT\n+\nIIIIIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("out", isDirectory: true)
        let command = try ClassifyCommand.parse([
            reads.path, "--db", "FixtureDB", "--confidence", "0.4", "--output-dir", output.path, "--threads", "1", "--quiet",
        ])
        let database = MetagenomicsDatabaseInfo(
            name: "FixtureDB", tool: "kraken2", version: "1", sizeBytes: 1, catalogID: "kraken2-viral",
            description: "", path: kraken2.databaseURL, status: .ready, recommendedRAM: 1
        )
        let pipeline = ClassificationPipeline(condaManager: kraken2.condaManager)

        try await command.execute { services in
            services.database = { _ in database }
            services.availableDatabases = { [database] }
            services.runPipeline = { config, progress in try await pipeline.classify(config: config, progress: progress) }
        }

        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: output))
        XCTAssertEqual(record.argv, [
            CLICommandIdentity.executableName, "kraken2", "classify", "--db", "FixtureDB", "--output-dir", output.path,
            "--confidence", "0.4", "--threads", "1", "--read-format", "auto", reads.path,
        ])
    }

    /// The command line the process was started with names the command in either spelling, so a
    /// run of the shipped binary records it as typed. Any other argv, such as the runner's, does not.
    func testACommandLineThatNamesTheCommandIsRecordedAsTypedInEitherSpelling() {
        for group in ["kraken2", "conda"] {
            let typed = ["/usr/local/bin/lungfish-cli", group, "classify", "--db", "Viral", "reads.fastq"]
            XCTAssertEqual(ClassifyCommand.recordedCommandLine(typed, fallback: ["unused"]), typed, group)
        }
        let runner = ["/usr/bin/xctest", "-XCTest", "classify", "bundle.xctest"]
        XCTAssertEqual(ClassifyCommand.recordedCommandLine(runner, fallback: ["lungfish-cli"]), ["lungfish-cli"])
    }

    /// The fallback spells out every option it was given, and a replay of it gives the same command.
    func testTheCanonicalCommandSpellsOutEveryOptionAndParsesBackToTheSame() throws {
        let digest = String(repeating: "ab", count: 32)
        let cases: [(arguments: [String], canonical: [String])] = [
            (
                ["a_R1.fastq", "a_R2.fastq", "--db", "Viral", "--db-digest", digest, "--preset", "precise",
                 "--output-dir", "/tmp/out", "--confidence", "0.35", "--min-hit-groups", "3", "--threads", "6",
                 "--paired", "--unpaired", "/tmp/m.fastq", "--recursive", "--memory-mapping", "--quick",
                 "--extra-args", "--report-zero-counts", "--profile", "--bracken-read-length", "100",
                 "--bracken-level", "G", "--bracken-threshold", "5", "--format", "json"],
                [CLICommandIdentity.executableName, "kraken2", "classify", "--db", "Viral", "--db-digest", digest,
                 "--preset", "precise", "--output-dir", "/tmp/out", "--confidence", "0.35", "--min-hit-groups", "3",
                 "--threads", "6", "--read-format", "auto", "--paired", "--unpaired", "/tmp/m.fastq", "--recursive",
                 "--memory-mapping", "--quick", "--extra-args", "--report-zero-counts", "--profile",
                 "--bracken-read-length", "100", "--bracken-threshold", "5", "--bracken-level", "G",
                 "--format", "json", "a_R1.fastq", "a_R2.fastq"]
            ),
            (
                ["/tmp/reads", "--db", "Viral", "--project", "/tmp/P.lungfish", "--batch", "--read-format", "unpaired"],
                [CLICommandIdentity.executableName, "kraken2", "classify", "--db", "Viral", "--project", "/tmp/P.lungfish",
                 "--batch", "--read-format", "unpaired", "/tmp/reads"]
            ),
            (
                ["a.fastq", "--db", "Viral"],
                [CLICommandIdentity.executableName, "kraken2", "classify", "--db", "Viral", "--read-format", "auto", "a.fastq"]
            ),
        ]
        for testCase in cases {
            let canonical = try ClassifyCommand.parse(testCase.arguments).canonicalArguments()
            XCTAssertEqual(canonical, testCase.canonical)
            XCTAssertEqual(try ClassifyCommand.parse(Array(canonical.dropFirst(3))).canonicalArguments(), canonical)
        }
    }
}
