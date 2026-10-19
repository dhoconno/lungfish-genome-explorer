// Kraken2ClassifyCommandTests.swift - kraken2 classify and conda classify are one command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishWorkflow

/// Plan decision S19 and vote V14. `lungfish-cli kraken2 classify` is the
/// spelling the root help shows beside `esviritu detect` and `taxtriage run`.
/// `conda classify` stays registered, because the Operations panel, recorded
/// commands and the goldens name it until 2.7. Both spellings register the one
/// `ClassifyCommand` type, so a parsed root still casts to it and no wrapper
/// stands between the parser and the command.
final class Kraken2ClassifyCommandTests: XCTestCase {

    private static let abstract = "Run Kraken2 taxonomic classification, with optional Bracken abundance profiling"

    /// Argument lines that between them set every option `ClassifyCommand` and
    /// `GlobalOptions` declare, so an option one spelling dropped could not hide.
    private static let argumentLines: [(name: String, arguments: [String], database: String)] = [
        ("one file", ["reads.fastq.gz", "--db", "Viral"], "Viral"),
        (
            "a pair with merged reads",
            [
                "R1.fastq.gz", "R2.fastq.gz", "--paired", "--unpaired", "merged.fastq.gz",
                "--db", "Standard-8", "--preset", "sensitive", "--output-dir", "out",
            ],
            "Standard-8"
        ),
        (
            "every option",
            [
                "reads_R1.fastq.gz", "reads_R2.fastq.gz",
                "--db", "PlusPF", "--preset", "precise", "-o", "results/kraken2",
                "--paired", "--read-format", "paired",
                "--unpaired", "merged.fastq.gz", "--unpaired", "single.fastq.gz",
                "--recursive", "--profile", "--confidence", "0.2", "--min-hit-groups", "4",
                "--memory-mapping", "--quick", "--bracken-read-length", "100",
                "--bracken-level", "G", "--bracken-threshold", "5",
                "--extra-args", "--report-minimizer-data",
                "--batch", "--db-digest", "sha256:0123",
                "--format", "json", "-vv", "--quiet", "--progress", "--no-progress", "--debug",
                "--log-file", "classify.log", "--no-color", "--threads", "4",
            ],
            "PlusPF"
        ),
        ("a batch in a project", ["reads/", "--db", "Viral", "--batch", "--project", "My.lungfish"], "Viral"),
    ]

    // MARK: - Helpers

    /// Every option of a parsed command as text, so two parses compare in one assertion.
    private func options(of command: ClassifyCommand) -> [String: String] {
        let global = command.globalOptions
        return [
            "fastqFiles": "\(command.fastqFiles)",
            "databaseName": command.databaseName,
            "databaseDigest": "\(String(describing: command.databaseDigest))",
            "project": "\(String(describing: command.project))",
            "batch": "\(command.batch)",
            "preset": command.preset.rawValue,
            "outputDir": "\(String(describing: command.outputDir))",
            "pairedEnd": "\(command.pairedEnd)",
            "readFormat": command.readFormat.rawValue,
            "unpaired": "\(command.unpaired)",
            "recursive": "\(command.recursive)",
            "profile": "\(command.profile)",
            "confidence": "\(String(describing: command.confidence))",
            "minHitGroups": "\(String(describing: command.minHitGroups))",
            "memoryMapping": "\(command.memoryMapping)",
            "quickMode": "\(command.quickMode)",
            "brackenReadLength": "\(command.brackenReadLength)",
            "brackenLevel": "\(String(describing: command.brackenLevel))",
            "brackenThreshold": "\(command.brackenThreshold)",
            "extraArgs": command.extraArgs,
            "format": "\(global.outputFormat)",
            "verbosity": "\(global.verbosity)",
            "quiet": "\(global.quiet)",
            "showProgress": "\(global.showProgress)",
            "noProgress": "\(global.noProgress)",
            "debug": "\(global.debug)",
            "logFile": "\(String(describing: global.logFile))",
            "noColor": "\(global.noColor)",
            "threads": "\(String(describing: global.threads))",
        ]
    }

    private func classifyCommand(
        _ path: [String],
        _ arguments: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ClassifyCommand {
        let parsed = try LungfishCLI.parseAsRoot(path + arguments)
        return try XCTUnwrap(
            parsed as? ClassifyCommand,
            "\(path.joined(separator: " ")) parsed to \(type(of: parsed)), not ClassifyCommand",
            file: file,
            line: line
        )
    }

    /// The help the shipped binary prints for `path`, with every run of
    /// whitespace folded to one space so the screen width cannot split a phrase.
    /// ArgumentParser parses `--help` to its `HelpCommand`, whose `run` throws
    /// the request that `fullMessage(for:)` renders for the command stack the
    /// parser found, so a path the root does not know prints the root's help.
    private func help(for path: [String]) throws -> String {
        let label = path.joined(separator: " ")
        var parsed = try LungfishCLI.parseAsRoot(path + ["--help"])
        guard String(describing: type(of: parsed)) == "HelpCommand" else {
            XCTFail("\(label) --help parsed to \(type(of: parsed))")
            return ""
        }
        do {
            try parsed.run()
        } catch {
            return Self.collapsed(LungfishCLI.fullMessage(for: error))
        }
        XCTFail("\(label) --help did not request help")
        return ""
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - One command, two spellings

    func testBothSpellingsParseToClassifyCommandWithEqualOptions() throws {
        for line in Self.argumentLines {
            let underConda = try classifyCommand(["conda", "classify"], line.arguments)
            let underKraken2 = try classifyCommand(["kraken2", "classify"], line.arguments)

            XCTAssertEqual(underKraken2.databaseName, line.database, line.name)
            XCTAssertEqual(options(of: underKraken2), options(of: underConda), line.name)
            // A catch-all for an option added later that `options(of:)` does not list.
            XCTAssertEqual(String(reflecting: underKraken2), String(reflecting: underConda), line.name)
        }
    }

    /// The fixture itself, read through the spelling that already exists, so a
    /// typo in it cannot pass for equal options. `--progress` and `--no-progress`
    /// both parse, because the command validates neither against the other.
    func testTheEveryOptionLineSetsEachOptionItNames() throws {
        let command = try classifyCommand(["conda", "classify"], Self.argumentLines[2].arguments)
        XCTAssertEqual(command.fastqFiles, ["reads_R1.fastq.gz", "reads_R2.fastq.gz"])
        XCTAssertEqual(command.preset, .precise)
        XCTAssertEqual(command.outputDir, "results/kraken2")
        XCTAssertTrue(command.pairedEnd)
        XCTAssertEqual(command.unpaired, ["merged.fastq.gz", "single.fastq.gz"])
        XCTAssertTrue(command.recursive)
        XCTAssertTrue(command.profile)
        XCTAssertEqual(command.confidence, 0.2)
        XCTAssertEqual(command.minHitGroups, 4)
        XCTAssertTrue(command.memoryMapping)
        XCTAssertTrue(command.quickMode)
        XCTAssertEqual(command.brackenReadLength, 100)
        XCTAssertEqual(command.brackenLevel, "G")
        XCTAssertEqual(command.brackenThreshold, 5)
        XCTAssertEqual(command.extraArgs, "--report-minimizer-data")
        XCTAssertTrue(command.batch)
        XCTAssertEqual(command.databaseDigest, "sha256:0123")
        let global = command.globalOptions
        XCTAssertEqual(global.outputFormat, .json)
        XCTAssertEqual(global.verbosity, 2)
        XCTAssertTrue(global.quiet)
        XCTAssertTrue(global.showProgress)
        XCTAssertTrue(global.noProgress)
        XCTAssertTrue(global.debug)
        XCTAssertEqual(global.logFile, "classify.log")
        XCTAssertTrue(global.noColor)
        XCTAssertEqual(global.threads, 4)
    }

    /// Lane A8. `--project` makes a new folder and `--output-dir` claims a named one, so one run
    /// takes one of them.
    func testProjectAndOutputDirAreRefusedTogether() throws {
        XCTAssertThrowsError(try LungfishCLI.parseAsRoot(
            ["kraken2", "classify", "reads.fastq", "--db", "Viral", "--project", "My.lungfish", "--output-dir", "out"]
        ))
        let project = try classifyCommand(["kraken2", "classify"], ["reads.fastq", "--db", "Viral", "--project", "My.lungfish"])
        XCTAssertEqual(project.project, "My.lungfish")
        XCTAssertFalse(project.batch)
    }

    /// The analysis run's exit codes are `CLIExitCode`'s numbers, which LungfishWorkflow copies.
    func testAnalysisRunExitCodesEqualTheCLIExitCodes() {
        XCTAssertEqual(AnalysisRunExitCode.completed, CLIExitCode.success.rawValue)
        XCTAssertEqual(AnalysisRunExitCode.workflowError, CLIExitCode.workflowError.rawValue)
        XCTAssertEqual(AnalysisRunExitCode.cancelled, CLIExitCode.cancelled.rawValue)
        XCTAssertEqual(Kraken2RunRefusal.inputErrorCode, CLIExitCode.inputError.rawValue)
        XCTAssertEqual(Kraken2RunRefusal.dependencyCode, CLIExitCode.dependency.rawValue)
        XCTAssertEqual(CLIError.validationFailed(errors: []).analysisRunExitCode, CLIExitCode.inputError.rawValue)
    }

    func testTheKraken2GroupHoldsClassifyCommandAndNoWrapper() throws {
        let group = try XCTUnwrap(
            LungfishCLI.configuration.subcommands.first { $0.configuration.commandName == "kraken2" },
            "the root command registers no kraken2 group"
        )
        XCTAssertEqual(group.configuration.abstract, Self.abstract)
        // 2.12 added `kraken2 export` (73e58c3fc) beside `classify`.
        XCTAssertEqual(group.configuration.subcommands.count, 2)
        XCTAssertTrue(
            group.configuration.subcommands.first == ClassifyCommand.self,
            "kraken2 classify must be ClassifyCommand itself, not \(String(describing: group.configuration.subcommands.first))"
        )
        XCTAssertEqual(
            group.configuration.subcommands.map { $0.configuration.commandName },
            ["classify", "export"]
        )
    }

    func testCondaStillRegistersClassifyCommand() {
        XCTAssertTrue(CondaCommand.configuration.subcommands.contains { $0 == ClassifyCommand.self })
    }

    /// One command writes one thing for a machine reader whatever it is called,
    /// so both leaves carry the same row of the contract table. The `kraken2`
    /// group is not a leaf and has no row of its own.
    func testBothSpellingsShareOneContractRow() throws {
        let underKraken2 = try XCTUnwrap(
            CLIEventContractTable.entries["kraken2 classify"],
            "the contract table has no row for kraken2 classify"
        )
        let underConda = try XCTUnwrap(
            CLIEventContractTable.entries["conda classify"],
            "the contract table has no row for conda classify"
        )
        XCTAssertEqual(underKraken2, underConda)
    }

    // MARK: - Recorded commands

    /// The argv the Operations panel records and a copied command replays.
    private var recordedClassifyArguments: [String] {
        let config = ClassificationConfig(
            goal: .profile,
            inputFiles: [
                URL(fileURLWithPath: "/tmp/reads_R1.fastq.gz"),
                URL(fileURLWithPath: "/tmp/reads_R2.fastq.gz"),
            ],
            isPairedEnd: true,
            databaseName: "Viral",
            databasePath: URL(fileURLWithPath: "/opt/lungfish/db/Viral"),
            confidence: 0.35,
            minimumHitGroups: 3,
            threads: 6,
            outputDirectory: URL(fileURLWithPath: "/tmp/out")
        )
        return ClassificationCLIInvocationBuilder.build(for: config).arguments
    }

    /// Recorded commands name `kraken2 classify` since 2.7 (E11), and one
    /// recorded before as `conda classify` still parses from the root as
    /// `ClassifyCommand`.
    func testTheRecordedKraken2ClassifyCommandReplaysThroughTheRoot() throws {
        let recorded = recordedClassifyArguments
        XCTAssertEqual(Array(recorded.prefix(2)), ["kraken2", "classify"], "recorded commands name kraken2 classify (E11)")
        XCTAssertTrue(
            try LungfishCLI.parseAsRoot(["conda", "classify"] + recorded.dropFirst(2)) is ClassifyCommand,
            "a command recorded before 2.7 still replays"
        )

        let parsed = try LungfishCLI.parseAsRoot(recorded)
        let replayed = try XCTUnwrap(parsed as? ClassifyCommand, "the recorded command parsed to \(type(of: parsed))")
        XCTAssertEqual(replayed.databaseName, "Viral")
        XCTAssertEqual(replayed.fastqFiles, ["/tmp/reads_R1.fastq.gz", "/tmp/reads_R2.fastq.gz"])
        XCTAssertTrue(replayed.pairedEnd)
        XCTAssertTrue(replayed.profile)
        XCTAssertEqual(replayed.confidence, 0.35)
        XCTAssertEqual(replayed.minHitGroups, 3)
        XCTAssertEqual(replayed.globalOptions.threads, 6)
    }

    /// A recorded command means the same under the new spelling, so a user who
    /// retypes it as `kraken2 classify` runs the same analysis.
    func testTheRecordedArgumentsMeanTheSameUnderKraken2Classify() throws {
        let tail = Array(recordedClassifyArguments.dropFirst(2))
        let underConda = try classifyCommand(["conda", "classify"], tail)
        let underKraken2 = try classifyCommand(["kraken2", "classify"], tail)
        XCTAssertEqual(options(of: underKraken2), options(of: underConda))
        XCTAssertEqual(underKraken2.databaseName, "Viral")
        XCTAssertTrue(underKraken2.profile)
    }

    // MARK: - Help

    func testTheRootHelpListsTheKraken2Group() throws {
        let rootHelp = Self.collapsed(LungfishCLI.helpMessage(columns: 400))
        XCTAssertTrue(rootHelp.contains("kraken2 \(Self.abstract)"), rootHelp)
        XCTAssertTrue(rootHelp.contains("esviritu "), "the group sits beside esviritu")
        XCTAssertTrue(rootHelp.contains("taxtriage "), "the group sits beside taxtriage")
    }

    func testKraken2HelpListsClassifyUnderItsAbstract() throws {
        let groupHelp = try help(for: ["kraken2"])
        XCTAssertTrue(groupHelp.contains(Self.abstract), groupHelp)
        XCTAssertTrue(groupHelp.contains("USAGE: lungfish-cli kraken2 <subcommand>"), groupHelp)
        XCTAssertTrue(
            groupHelp.contains("classify Run Kraken2 taxonomic classification on FASTQ or FASTA inputs"),
            groupHelp
        )
    }

    func testEachSpellingsHelpNamesItsOwnPath() throws {
        for group in ["kraken2", "conda"] {
            let leafHelp = try help(for: [group, "classify"])
            XCTAssertTrue(
                leafHelp.contains("USAGE: \(CLICommandIdentity.executableName) \(group) classify [<options>] <fastq-files> ... --db <db>"),
                leafHelp
            )
            XCTAssertTrue(leafHelp.contains("--db <db> Database name"), "\(group) classify lists --db")
        }
    }

    /// `--preset` takes a `CaseIterable` value, so ArgumentParser already
    /// appends `(values: ...; default: balanced)`. Its own help text must not
    /// state the default a second time.
    func testPresetHelpStatesItsDefaultOnce() throws {
        let help = ClassifyCommand.helpMessage(columns: 400)
        let line = try XCTUnwrap(
            help.split(separator: "\n").first { $0.contains("--preset <preset>") },
            "the classify help lists --preset"
        )
        let statements = line.components(separatedBy: "default: balanced").count - 1
        XCTAssertEqual(statements, 1, "--preset states its default \(statements) times: \(line)")
    }

    /// `--bracken-read-length` and `--bracken-threshold` take an `Int` with a
    /// default, so ArgumentParser appends `(default: ...)` to each. Their own help
    /// text must not state the default a second time.
    func testBrackenHelpStatesEachDefaultOnce() {
        let help = ClassifyCommand.helpMessage(columns: 400)
        for statement in ["(default: 150)", "(default: 10)"] {
            let count = help.components(separatedBy: statement).count - 1
            XCTAssertEqual(count, 1, "the classify help states \(statement) \(count) times")
        }
    }
}
