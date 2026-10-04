// ExtractReadsCommand+Classifier.swift - The --by-classifier strategy of lungfish-cli extract reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension ExtractReadsSubcommand {
    // MARK: - Classifier strategy

    func runByClassifier(
        formatter: TerminalFormatter,
        outputURL: URL
    ) async throws -> ReadExtractionResult {
        let fm = FileManager.default

        guard let toolRaw = classifierTool, let tool = ClassifierTool(rawValue: toolRaw) else {
            throw CLIExitCode.inputError.exitCode
        }
        guard let resultPathStr = classifierResult else {
            throw CLIExitCode.inputError.exitCode
        }
        // Pre-flight existence check, matching the pattern in runByReadID /
        // runByBAMRegion / runByDatabase. The semantics are slightly relaxed
        // vs the other strategies because `ClassifierReadResolver.resolveBAMURL`
        // interprets the path in one of three ways depending on the tool:
        //
        //   1. A file that exists (e.g. esviritu's results.sqlite next to
        //      the sorted BAM) — check `fileExists(atPath:)`.
        //   2. A directory that exists (e.g. nvd's result dir containing
        //      {sample}.bam files) — same `fileExists(atPath:)` call
        //      returns true for directories too.
        //   3. A sentinel file path whose PARENT directory contains the BAMs
        //      (e.g. a fake `fake-nvd.sqlite` path used by the nvd scan-the-
        //      parent-dir flow). In this case the sentinel file itself does
        //      not need to exist; the resolver strips it to the parent dir.
        //
        // So we accept the path if EITHER the path itself exists OR its parent
        // directory does. If neither is true, the user almost certainly typo'd
        // the --result argument and we should bail with a readable message.
        let resultPath = URL(fileURLWithPath: resultPathStr)
        let parentExists = fm.fileExists(atPath: resultPath.deletingLastPathComponent().path)
        guard fm.fileExists(atPath: resultPathStr) || parentExists else {
            print(formatter.error("Classifier result not found: \(resultPathStr)"))
            throw CLIExitCode.inputError.exitCode
        }

        // In DEBUG builds, allow tests to inject the simulated argv via the
        // testingRawArgs hook so per-sample grouping reflects the test args
        // rather than xctest's CommandLine.arguments. In RELEASE builds, the
        // helper falls back to CommandLine.arguments.
        let selectors = buildClassifierSelectors(rawArgs: effectiveClassifierRawArguments())
        let options = makeExtractionOptions()

        print(formatter.header("Classifier Extraction (\(tool.displayName))"))
        print("")
        print(formatter.keyValueTable([
            ("Tool", tool.displayName),
            ("Result path", resultPath.lastPathComponent),
            ("Samples", selectors.compactMap { $0.sampleId }.joined(separator: ", ")),
            ("Accessions", selectors.flatMap { $0.accessions }.joined(separator: ", ")),
            ("Taxons", selectors.flatMap { $0.taxIds.map(String.init) }.joined(separator: ", ")),
            ("Format", options.format.rawValue),
            ("Include unmapped mates", options.includeUnmappedMates ? "yes" : "no"),
        ]))
        print("")

        let resolver = ClassifierReadResolver()
        let quiet = globalOptions.quiet
        let outcome = try await resolver.resolveAndExtract(
            tool: tool,
            resultPath: resultPath,
            selections: selectors,
            options: options,
            destination: .file(outputURL),
            progress: { _, message in
                if !quiet {
                    print("\r\(formatter.info(message))", terminator: "")
                }
            }
        )

        // Translate the outcome back into a ReadExtractionResult so the common
        // bundle-wrapping + summary print at the bottom of `run()` works
        // unmodified.
        let fastqURL: URL
        switch outcome {
        case .file(let u, _):
            fastqURL = u
        case .bundle(let u, _):
            fastqURL = u
        case .clipboard, .share:
            // The CLI currently requests only file output, but keep this as a
            // recoverable validation error so future destination refactors do
            // not turn unsupported modes into a user-facing crash.
            print("")
            print(formatter.error("Clipboard / share destinations are not supported from the CLI"))
            throw CLIExitCode.inputError.exitCode
        }
        return ReadExtractionResult(
            fastqURLs: [fastqURL],
            readCount: outcome.readCount,
            pairedEnd: false
        )
    }
}
