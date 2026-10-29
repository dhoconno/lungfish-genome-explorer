// AssembleCommand+CommandLine.swift - The command line an assemble run records as its own
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

extension AssembleCommand {
    /// The argv the record names, the one this process was started with when it ran this command,
    /// else ``canonicalArguments()`` (a test runs the command inside another process, where the
    /// argv names the test runner).
    static func recordedCommandLine(_ arguments: [String], fallback: @autoclosure () -> [String]) -> [String] {
        arguments.dropFirst().contains("assemble") ? arguments : fallback()
    }

    /// The `assemble` command that runs these options again, every option it was given spelled out
    /// in the order the app records (`FASTQOperationCLIInvocationBuilder`).
    func canonicalArguments() -> [String] {
        var arguments = [CLICommandIdentity.executableName, "assemble"] + fastqFiles
        if pairedEnd { arguments.append("--paired") }
        if readLayout != .auto { arguments += ["--read-layout", readLayout.rawValue] }
        if jsonEvents { arguments.append("--json-events") }
        if let assembler { arguments += ["--assembler", assembler] }
        if let readType { arguments += ["--read-type", readType] }
        if let projectName { arguments += ["--project-name", projectName] }
        if let threads = globalOptions.threads { arguments += ["--threads", String(threads)] }
        if let outputDir { arguments += ["--output", outputDir] }
        if let memoryGB { arguments += ["--memory-gb", String(memoryGB)] }
        if let minContigLength { arguments += ["--min-contig-length", String(minContigLength)] }
        if let profile { arguments += ["--profile", profile] }
        if let profileBasis { arguments += ["--profile-basis", profileBasis] }
        if !extraArgs.isEmpty { arguments += ["--extra-args", extraArgs] }
        for argument in extraArg { arguments += ["--extra-arg", argument] }
        if !advancedOptions.isEmpty { arguments += ["--advanced-options", advancedOptions] }
        if referenceBundle { arguments.append("--reference-bundle") }
        arguments += timeLimit.argumentWords
        if globalOptions.outputFormat == .json { arguments += ["--format", "json"] }
        return arguments
    }
}
