// FastqRepairSubcommand.swift - Repair desynchronized paired-end reads using repair.sh
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - PE Repair

struct FastqRepairSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repair",
        abstract: "Repair desynchronized paired-end reads using repair.sh"
    )

    @Argument(help: "Input interleaved FASTQ file or .lungfishfastq bundle")
    var input: String

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let resolvedInput = try await FASTQSubcommandInput.resolve(input, operationName: "repair", output: output)
        defer { resolvedInput.cleanup() }
        let inputURL = resolvedInput.executionURL
        let runner = NativeToolRunner.shared

        let tempDir = try ProjectTempDirectory.createFromContext(
            prefix: "bbrepair-",
            contextURL: URL(fileURLWithPath: output.output)
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let repairedURL = tempDir.appendingPathComponent("repaired.fastq")
        let singletonsURL = tempDir.appendingPathComponent("singletons.fastq")

        let args = [
            "in=\(inputURL.path)",
            "out=\(repairedURL.path)",
            "outs=\(singletonsURL.path)",
        ]

        let env = await bbToolsEnvironment(runner: runner)
        let startedAt = Date()
        let result = try await runner.run(.repair, arguments: args, environment: env, timeout: 1800)
        guard result.isSuccess else {
            throw CLIError.conversionFailed(reason: "repair.sh failed: \(result.stderr)")
        }

        // Concatenate repaired + singletons
        let outputURL = URL(fileURLWithPath: output.output)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }
        for url in [repairedURL, singletonsURL] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let inputHandle = try FileHandle(forReadingFrom: url)
            defer { try? inputHandle.close() }
            while true {
                let chunk = inputHandle.readData(ofLength: 1_048_576)
                if chunk.isEmpty { break }
                outputHandle.write(chunk)
            }
        }
        var cliArguments = ["repair", resolvedInput.originalURL.path, "--output", output.output]
        if output.force {
            cliArguments.append("--force")
        }
        if output.compress {
            cliArguments.append("--compress")
        }
        try await recordFASTQNativeToolProvenance(
            workflowName: "lungfish fastq repair",
            nativeTool: .repair,
            cliArguments: cliArguments,
            nativeArguments: args,
            result: result,
            inputURLs: [resolvedInput.originalURL],
            outputURLs: [outputURL],
            parameters: [
                "input": .file(resolvedInput.originalURL),
                "output": .file(outputURL),
                "force": .boolean(output.force),
                "compress": .boolean(output.compress)
            ],
            defaults: [
                "force": .boolean(false),
                "compress": .boolean(false)
            ],
            inputRecords: try resolvedInput.inputRecords(),
            extraSteps: try resolvedInput.materializationSteps(),
            startedAt: startedAt
        )

        FileHandle.standardError.write(Data("Repaired reads written to \(output.output)\n".utf8))
    }
}
