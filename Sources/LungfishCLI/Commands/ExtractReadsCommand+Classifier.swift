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

    /// Runs the extraction into `outputURL`, and returns it with the read
    /// roles a bundle of it records. The result carries the pairing the
    /// app's bundle records for the same extraction: interleaved for pairs
    /// only, and single-end with roles for pairs mixed with single reads
    /// (D7d).
    func runByClassifier(
        formatter: TerminalFormatter,
        outputURL: URL
    ) async throws -> (result: ReadExtractionResult, roles: ReadClassification?) {
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
            throw ExtractReadsRefusal("Classifier result not found: \(resultPathStr)")
        }

        // In DEBUG builds, allow tests to inject the simulated argv via the
        // testingRawArgs hook so per-sample grouping reflects the test args
        // rather than xctest's CommandLine.arguments. In RELEASE builds, the
        // helper falls back to CommandLine.arguments.
        let selectors = buildClassifierSelectors(rawArgs: effectiveClassifierRawArguments())
        let options = makeExtractionOptions()

        say(formatter.header("Classifier Extraction (\(tool.displayName))"))
        say("")
        say(formatter.keyValueTable([
            ("Tool", tool.displayName),
            ("Result path", resultPath.lastPathComponent),
            ("Samples", selectors.compactMap { $0.sampleId }.joined(separator: ", ")),
            ("Accessions", selectors.flatMap { $0.accessions }.joined(separator: ", ")),
            ("Taxons", selectors.flatMap { $0.taxIds.map(String.init) }.joined(separator: ", ")),
            ("Format", options.format.rawValue),
            ("Include unmapped mates", options.includeUnmappedMates ? "yes" : "no"),
        ]))
        say("")

        let resolver = ClassifierReadResolver()
        let quiet = globalOptions.quiet
        let (outcome, layout) = try await resolver.resolveAndExtractWithLayout(
            tool: tool,
            resultPath: resultPath,
            selections: selectors,
            options: options,
            destination: .file(outputURL),
            progress: { _, message in
                if !quiet {
                    progressLine(formatter.info(message))
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
            say("")
            throw ExtractReadsRefusal("Clipboard / share destinations are not supported from the CLI")
        }
        return (
            ReadExtractionResult(
                fastqURLs: [fastqURL],
                readCount: outcome.readCount,
                pairedEnd: false,
                pairingMode: layout.pairingMode
            ),
            layout.roles(namedFor: fastqURL)
        )
    }

    // MARK: - Classifier option construction

    /// Builds the `ExtractionOptions` that `runByClassifier` passes to
    /// `ClassifierReadResolver`. Exposed (non-private) so tests can assert that
    /// CLI flags like `--read-format` and `--include-unmapped-mates` flow
    /// through to the resolver-facing struct, without having to actually
    /// execute the extraction pipeline.
    func makeExtractionOptions() -> ExtractionOptions {
        let format: CopyFormat = (classifierFormat == "fasta") ? .fasta : .fastq
        return ExtractionOptions(
            format: format,
            includeUnmappedMates: includeUnmappedMates
        )
    }

    // MARK: - Classifier selection reconstruction

    /// Reconstructs per-sample `ClassifierRowSelector` groups from the parsed
    /// flags, using the raw argument order to bind `--accession` and `--taxon`
    /// flags to their preceding `--sample` scope.
    ///
    /// Handles both ArgumentParser-accepted forms for each flag:
    /// - space-separated (`--sample A`), which consumes two argv tokens
    /// - equals-joined (`--sample=A`), which is a single argv token
    ///
    /// Both forms may appear in the same argv.
    ///
    /// - Parameter rawArgs: The full argument list as it was passed to
    ///   `ExtractReadsSubcommand.parse(...)`. Defaults to `CommandLine.arguments`
    ///   minus the executable name. Tests supply the list explicitly.
    func buildClassifierSelectors(rawArgs: [String]? = nil) -> [ClassifierRowSelector] {
        // The argument list we walk. In tests this is supplied; in production
        // it is the current process's arguments.
        let argv: [String] = rawArgs ?? Array(CommandLine.arguments.dropFirst())

        var selectors: [ClassifierRowSelector] = []
        var current: ClassifierRowSelector?

        var i = 0
        while i < argv.count {
            let (key, inlineValue) = splitClassifierArgumentToken(argv[i])

            // Resolve the flag's value: inline (`--sample=A`) takes precedence,
            // otherwise read the next argv token (`--sample A`). If neither is
            // present we let the outer `i += 1` skip the dangling flag —
            // ArgumentParser rejects dangling-option invocations at parse time
            // anyway, so this path is defensive.
            let value: String?
            let consumed: Int
            if let inlineValue {
                value = inlineValue
                consumed = 1
            } else if i + 1 < argv.count {
                value = argv[i + 1]
                consumed = 2
            } else {
                value = nil
                consumed = 1
            }

            switch key {
            case "--sample":
                if let value {
                    if let c = current { selectors.append(c) }
                    current = ClassifierRowSelector(sampleId: value, accessions: [], taxIds: [])
                    i += consumed
                    continue
                }
            case "--accession":
                if let value {
                    if current == nil {
                        current = ClassifierRowSelector(sampleId: nil, accessions: [], taxIds: [])
                    }
                    current?.accessions.append(value)
                    i += consumed
                    continue
                }
            case "--taxon":
                if let value {
                    if current == nil {
                        current = ClassifierRowSelector(sampleId: nil, accessions: [], taxIds: [])
                    }
                    if let n = Int(value) {
                        current?.taxIds.append(n)
                    }
                    i += consumed
                    continue
                }
            default:
                break
            }
            i += 1
        }
        if let c = current { selectors.append(c) }
        return selectors
    }

    /// Returns the classifier selection flags in their raw grouping order so
    /// provenance replay preserves the same sample/accession/taxon scopes that
    /// execution used.
    func classifierSelectionReplayArguments(rawArgs: [String]? = nil) -> [String] {
        let argv: [String] = rawArgs ?? Array(CommandLine.arguments.dropFirst())
        var replay: [String] = []

        var i = 0
        while i < argv.count {
            let token = argv[i]
            let (key, inlineValue) = splitClassifierArgumentToken(token)

            switch key {
            case "--sample", "--accession", "--taxon":
                if inlineValue != nil {
                    replay.append(token)
                    i += 1
                    continue
                }
                if i + 1 < argv.count {
                    replay += [key, argv[i + 1]]
                    i += 2
                    continue
                }
            default:
                break
            }

            i += 1
        }

        return replay
    }

    private func splitClassifierArgumentToken(_ token: String) -> (key: String, inlineValue: String?) {
        if let eq = token.firstIndex(of: "=") {
            return (String(token[..<eq]), String(token[token.index(after: eq)...]))
        }
        return (token, nil)
    }

    func effectiveClassifierRawArguments() -> [String]? {
        #if DEBUG
        return testingRawArgs
        #else
        return nil
        #endif
    }
}
