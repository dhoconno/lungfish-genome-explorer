// ClassifyCommand+CommandLine.swift - The command line a kraken2 classify run records as its own
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow

extension ClassifyCommand {
    /// The argv the root record names, the one this process was started with when it ran this
    /// leaf (`kraken2 classify` or `conda classify`, as typed), else ``canonicalArguments()`` (a
    /// test runs the command inside another process, where the argv names the test runner).
    static func recordedCommandLine(_ arguments: [String], fallback: @autoclosure () -> [String]) -> [String] {
        let namesThisCommand = arguments.indices.dropFirst().contains { index in
            arguments[index] == "classify" && ["conda", "kraken2"].contains(arguments[index - 1])
        }
        return namesThisCommand ? arguments : fallback()
    }

    /// The `kraken2 classify` command that runs these options again, in the order of
    /// ``ClassificationCLIInvocationBuilder``. The read format is always pinned, as that builder
    /// pins it, and any other option that has a default is spelled out only when it differs from
    /// it, because the root record takes the options it names from this command line.
    func canonicalArguments() -> [String] {
        let bracken = BrackenProfileRequest.automaticDefault
        var arguments = [CLICommandIdentity.executableName, "kraken2", "classify", "--db", databaseName]
        if let databaseDigest { arguments += ["--db-digest", databaseDigest] }
        if preset != .balanced { arguments += ["--preset", preset.rawValue] }
        if let outputDir { arguments += ["--output-dir", outputDir] }
        if let project { arguments += ["--project", project] }
        if batch { arguments.append("--batch") }
        if let confidence { arguments += ["--confidence", String(confidence)] }
        if let minHitGroups { arguments += ["--min-hit-groups", String(minHitGroups)] }
        if let threads = globalOptions.threads { arguments += ["--threads", String(threads)] }
        arguments += ["--read-format", readFormat.rawValue]
        if pairedEnd { arguments.append("--paired") }
        for file in unpaired { arguments += ["--unpaired", file] }
        if recursive { arguments.append("--recursive") }
        if memoryMapping { arguments.append("--memory-mapping") }
        if quickMode { arguments.append("--quick") }
        if !extraArgs.isEmpty { arguments += ["--extra-args", extraArgs] }
        if profile { arguments.append("--profile") }
        if profile || brackenReadLength != bracken.readLength { arguments += ["--bracken-read-length", String(brackenReadLength)] }
        if profile || brackenThreshold != bracken.threshold { arguments += ["--bracken-threshold", String(brackenThreshold)] }
        if let brackenLevel { arguments += ["--bracken-level", brackenLevel] }
        if globalOptions.outputFormat == .json { arguments += ["--format", "json"] }
        return arguments + fastqFiles
    }
}
