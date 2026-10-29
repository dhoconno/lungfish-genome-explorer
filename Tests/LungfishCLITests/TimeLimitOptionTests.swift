// TimeLimitOptionTests.swift - The --time-limit option of the analysis commands
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

/// `docs/contracts/SCOPE-AND-DELIVERY.md`, Tool run time. A run has no wall-clock limit unless the person gives
/// `--time-limit <minutes>`, and the command line a run records spells the option it was given.
final class TimeLimitOptionTests: XCTestCase {

    func testKraken2ClassifyTakesATimeLimitAndRecordsItInItsCommandLine() throws {
        let limited = try XCTUnwrap(
            try ClassifyCommand.parseAsRoot(["reads.fastq.gz", "--db", "Viral", "--time-limit", "90"]) as? ClassifyCommand)
        let plain = try XCTUnwrap(try ClassifyCommand.parseAsRoot(["reads.fastq.gz", "--db", "Viral"]) as? ClassifyCommand)

        XCTAssertEqual(limited.timeLimit.limit?.minutes, 90)
        let words = limited.canonicalArguments()
        XCTAssertEqual(words.firstIndex(of: "--time-limit").map { words[$0 + 1] }, "90",
                       "the recorded command line gives the limit the run was started with")
        XCTAssertNil(plain.timeLimit.limit, "without the option there is no limit")
        XCTAssertFalse(plain.canonicalArguments().contains("--time-limit"))
    }

    func testMapTakesATimeLimit() throws {
        let limited = try MapCommand.parse(["reads.fastq.gz", "--reference", "ref.fa", "--time-limit", "45"])
        let plain = try MapCommand.parse(["reads.fastq.gz", "--reference", "ref.fa"])

        XCTAssertEqual(limited.timeLimit.limit?.minutes, 45)
        XCTAssertNil(plain.timeLimit.limit)
    }

    func testATimeLimitThatIsNotAWholeNumberOfMinutesIsRefusedWithWords() {
        for value in [["--time-limit", "0"], ["--time-limit", "525601"], ["--time-limit=-3"]] {
            XCTAssertThrowsError(
                try ClassifyCommand.parseAsRoot(["reads.fastq.gz", "--db", "Viral"] + value),
                "\(value)"
            ) { error in
                let words = ClassifyCommand.message(for: error)
                XCTAssertTrue(words.contains("whole number of minutes"), words)
                XCTAssertTrue(words.contains("Leave the option out to run with no time limit"), words)
            }
        }
    }

    // MARK: The commands that gained the option with TTL2

    func testAssembleTakesATimeLimitAndSpellsItInItsRecordedCommand() throws {
        let limited = try AssembleCommand.parse(["reads.fastq", "--time-limit", "120"])
        let plain = try AssembleCommand.parse(["reads.fastq"])

        XCTAssertEqual(limited.timeLimit.limit?.minutes, 120)
        XCTAssertNil(plain.timeLimit.limit)
        XCTAssertEqual(Self.value(after: "--time-limit", in: limited.canonicalArguments()), "120")
        XCTAssertNil(Self.value(after: "--time-limit", in: plain.canonicalArguments()))
    }

    func testAlignMafftTakesATimeLimitAndSpellsItInItsRecordedCommand() throws {
        let arguments = ["mafft", "/workspace/Project.lungfish/input.fasta", "--project", "/workspace/Project.lungfish"]
        let limited = try AlignCommand.MAFFTSubcommand.parse(arguments + ["--time-limit", "60"])
        let plain = try AlignCommand.MAFFTSubcommand.parse(arguments)

        XCTAssertEqual(limited.timeLimit.limit?.minutes, 60)
        XCTAssertNil(plain.timeLimit.limit)
        XCTAssertEqual(Self.value(after: "--time-limit", in: try limited.makeRequestForTesting().wrapperArgv), "60")
        XCTAssertNil(Self.value(after: "--time-limit", in: try plain.makeRequestForTesting().wrapperArgv))
    }

    func testExtractReadsTakesATimeLimitAndSpellsItInItsRecordedCommand() throws {
        let arguments = ["--by-id", "--ids", "ids.txt", "--source", "reads.fastq", "-o", "out.fastq"]
        let output = URL(fileURLWithPath: "out.fastq")
        let limited = try ExtractReadsSubcommand.parse(arguments + ["--time-limit", "20"])
        let plain = try ExtractReadsSubcommand.parse(arguments)

        XCTAssertEqual(limited.timeLimit.limit?.minutes, 20)
        XCTAssertNil(plain.timeLimit.limit)
        XCTAssertEqual(Self.value(after: "--time-limit", in: limited.provenanceCommand(outputURL: output)), "20")
        XCTAssertNil(Self.value(after: "--time-limit", in: plain.provenanceCommand(outputURL: output)))
    }

    func testFastqScrubHumanTakesATimeLimitAndRecordsItInBothOptionMaps() throws {
        let limited = try FastqScrubHumanSubcommand.parse(["in.fastq.gz", "--database-id", "human-scrubber", "--output", "out.fastq.gz", "--time-limit", "15"])
        XCTAssertEqual(limited.timeLimit.limit?.minutes, 15)
        XCTAssertNil(try FastqScrubHumanSubcommand.parse(["in.fastq.gz", "--database-id", "human-scrubber", "--output", "out.fastq.gz"]).timeLimit.limit)

        let maps = { (minutes: Int?) in
            FastqScrubHumanSubcommand.provenanceOptionMaps(
                inputURL: URL(fileURLWithPath: "/data/in.fastq.gz"),
                outputURL: URL(fileURLWithPath: "/data/out.fastq.gz"),
                databaseID: "human-scrubber",
                resolvedDatabaseID: "human-scrubber",
                databasePath: URL(fileURLWithPath: "/db/human"),
                removeReadsCompatibilityFlag: false,
                force: false,
                compress: false,
                resolvedCompressOutput: false,
                threads: 4,
                timeLimitMinutes: minutes
            )
        }
        XCTAssertEqual(maps(15).explicit[AnalysisTimeLimit.recordKey], .integer(15))
        XCTAssertEqual(maps(15).resolved[AnalysisTimeLimit.recordKey], .integer(15))
        XCTAssertNil(maps(nil).explicit[AnalysisTimeLimit.recordKey], "a run with no limit records none")
        XCTAssertNil(maps(nil).resolved[AnalysisTimeLimit.recordKey])
    }

    func testVariantsCallAndPhaseTakeATimeLimit() throws {
        let call = ["--bundle", "/tmp/Sample.lungfishref", "--alignment-track", "aln-1", "--caller", "gatk"]
        let limitedCall = try VariantsCommand.CallSubcommand.parse(call + ["--time-limit", "180"])
        let plainCall = try VariantsCommand.CallSubcommand.parse(call)
        XCTAssertEqual(limitedCall.callOptions.timeLimit.limit?.minutes, 180)
        XCTAssertNil(plainCall.callOptions.timeLimit.limit)
        XCTAssertEqual(Self.value(after: "--time-limit", in: limitedCall.recordedCommandLine(arguments: [])), "180")
        XCTAssertNil(Self.value(after: "--time-limit", in: plainCall.recordedCommandLine(arguments: [])))

        let phase = ["phase", "--reference", "/tmp/ref.fa", "--bam", "/tmp/in.bam", "--output-vcf", "/tmp/out.vcf", "--output-dir", "/tmp/out"]
        XCTAssertEqual(try VariantsCommand.PhaseSubcommand.parse(phase + ["--time-limit", "90"]).timeLimit.limit?.minutes, 90)
        XCTAssertNil(try VariantsCommand.PhaseSubcommand.parse(phase).timeLimit.limit)
    }

    /// TTL2-BIO B1. `variants call --caller gatk` records the limit of its run, so the runners of that call carry it.
    func testTheGATKRunnersOfARunCarryItsTimeLimit() async {
        let timeouts = {
            [
                GATKPipelineExecutor<ProcessGATKCommandRunner>().runner.timeout,
                GATKPipelineExecutor<ManagedGATKCommandRunner>().runner.timeout,
                VariantsCommand.CallSubcommand.liveRunner().timeout,
            ]
        }
        let limited = await AnalysisTimeLimit.withLimit(AnalysisTimeLimit(minutes: 7)) { timeouts() }
        XCTAssertEqual(limited, [420, 420, 420],
                       "the local and the managed runner of the executor and the live runner of a call read the limit of the run")
        XCTAssertEqual(timeouts(), [.infinity, .infinity, .infinity], "a run no command scoped has no limit")
    }

    func testTheRunRecordHoldsTheLimitOnlyInsideARunThatSetOne() async {
        let parameters: [String: ParameterValue] = ["threads": .integer(4)]
        XCTAssertEqual(AnalysisTimeLimit.recording(parameters), parameters, "no run scoped a limit")
        let recorded = await AnalysisTimeLimit.withLimit(AnalysisTimeLimit(minutes: 30)) { AnalysisTimeLimit.recording(parameters) }
        XCTAssertEqual(recorded[AnalysisTimeLimit.recordKey], .integer(30))
        XCTAssertEqual(recorded["threads"], .integer(4), "the entries of the run stay")
        let unlimited = await AnalysisTimeLimit.withLimit(nil) { AnalysisTimeLimit.recording(parameters) }
        XCTAssertNil(unlimited[AnalysisTimeLimit.recordKey])
    }

    private static func value(after option: String, in words: [String]) -> String? {
        words.firstIndex(of: option).flatMap { words.indices.contains($0 + 1) ? words[$0 + 1] : nil }
    }
}
