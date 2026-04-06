// FastqScrubHumanSubcommand.swift - CLI subcommand to remove human reads from FASTQ
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

struct FastqScrubHumanSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scrub-human",
        abstract: "Remove human reads from FASTQ"
    )

    @Argument(help: "Input FASTQ file path")
    var input: String

    @OptionGroup var output: OutputOptions

    @Option(name: .customLong("database-id"), help: "SRA human scrubber database identifier")
    var databaseID: String

    @Flag(name: .customLong("remove-reads"), help: "Remove matched reads instead of masking with N")
    var removeReads: Bool = false

    func run() async throws {
        let inputURL = try validateInput(input)
        try output.validateOutput()

        let runner = NativeToolRunner.shared
        let scrubSh = try await runner.findTool(.scrubSh)
        let threads = ProcessInfo.processInfo.activeProcessorCount
        let scriptsDir = scrubSh.deletingLastPathComponent()

        guard let dbPath = await DatabaseRegistry.shared.effectiveDatabasePath(for: databaseID) else {
            throw CLIError.conversionFailed(
                reason: "Human read scrub database '\(databaseID)' not found. " +
                "Place the database file in ~/Library/Application Support/Lungfish/databases/\(databaseID)/"
            )
        }

        let outputURL = URL(fileURLWithPath: output.output)

        var scriptArgs: [String] = [
            scrubSh.path,
            "-i", inputURL.path,
            "-o", outputURL.path,
            "-d", dbPath.path,
            "-p", "\(threads)",
        ]
        if removeReads { scriptArgs.append("-x") }

        var env = await bbToolsEnvironment(runner: runner)
        if env["PATH"] == nil {
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        }

        let result = try await runner.runProcess(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: scriptArgs,
            workingDirectory: scriptsDir,
            environment: env,
            timeout: 3600,
            toolName: "scrub.sh"
        )

        if !result.isSuccess {
            throw CLIError.conversionFailed(reason: result.stderr)
        }
    }
}
