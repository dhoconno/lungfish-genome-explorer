// ImportCommand+FASTA.swift - The import fasta leaf, over ReferenceBundleImportService
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os

// MARK: - FASTA Import

/// A refusal of `import fasta` before it writes anything, with the exit code it ends with.
struct ImportFASTARefusal: Error, LocalizedError {
    let message: String
    let exitCode: CLIExitCode
    var errorDescription: String? { message }
}

extension ImportCommand {

    /// Import a standalone reference sequence file into a Lungfish project.
    ///
    /// Accepts FASTA/GenBank/EMBL (plain or compressed), then builds a canonical `.lungfishref` bundle in
    /// the project's "Reference Sequences" folder, or in the folder `--bundle-dir` names as given, through
    /// `ReferenceBundleImportService`, the one path the
    /// app's reference imports take too (ruling A48 F2). With `--annotations` it then attaches the BED as a
    /// track and writes the extraction record, and with `--rehydrate-source-provenance` it merges the
    /// source's own record, so the app writes nothing after the command exits (plan decision C5).
    struct FASTASubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "fasta",
            abstract: "Import a standalone reference sequence file as a .lungfishref bundle",
            discussion: """
            With --format json, standard output holds event lines: one start line, a progress line \
            for each step and one complete or failed line. The text goes to standard error. SIGTERM \
            stops the import, removes what it built and exits 125.
            """
        )
        static let cancelledMessage = "Import cancelled. Nothing was published."
        private static let preparingMessage = "Preparing reference input..."

        @Argument(help: "Path to the input reference (.fa/.fasta/.gb/.embl, optionally .gz/.bgz/.bz2/.xz/.zst)")
        var inputFile: String

        @Option(
            name: [.customLong("output-dir"), .customShort("o")],
            help: "Output project directory (default: current directory)"
        )
        var outputDir: String?

        @Option(
            name: .customLong("bundle-dir"),
            help: ArgumentHelp(
                "The folder to build the bundle in, as given, in place of the Reference Sequences folder of the project. Not with --output-dir",
                valueName: "folder"
            )
        )
        var bundleDir: String?

        @Option(
            name: .customLong("name"),
            help: "Display name for the reference (default: filename)"
        )
        var name: String?

        @Option(
            name: .customLong("provenance-input"),
            help: ArgumentHelp(
                "A file the record names as the import's input in place of the input file. Give it once for each file, in order",
                valueName: "file"
            )
        )
        var provenanceInputs: [String] = []

        @Option(
            name: .customLong("annotations"),
            help: ArgumentHelp("A BED file of annotations to attach to the new bundle as a track", valueName: "bed")
        )
        var annotations: String?

        @Option(
            name: .customLong("annotation-selection"),
            help: ArgumentHelp(
                "With --annotations, the JSON selection the BED came from, which the extraction record keeps",
                valueName: "json"
            )
        )
        var annotationSelection: String?

        @Option(
            name: .customLong("source-alignment-bundle"),
            help: ArgumentHelp(
                "With --annotations, the alignment bundle the selection came from, which the extraction record names",
                valueName: "path"
            )
        )
        var sourceAlignmentBundle: String?

        @Flag(
            name: .customLong("rehydrate-source-provenance"),
            help: "Merge the input file's own record into the new bundle's record"
        )
        var rehydrateSourceProvenance = false

        @OptionGroup var globalOptions: GlobalOptions

        func validate() throws {
            if outputDir != nil, bundleDir != nil {
                throw ValidationError("Give --output-dir or --bundle-dir, not both.")
            }
        }

        func run() async throws {
            let eventsOn = globalOptions.outputFormat == .json
            let events = CLIEventEmitter(enabled: eventsOn, emit: printEventLine)
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let pendingCancel = PendingTaskCancel<Result<ReferenceBundleImportResult, any Error>>()
            let termination = SIGTERMCancellation(cancelling: pendingCancel, secondSignalEndsProcess: true)
            let command = self
            let task = Task { () -> Result<ReferenceBundleImportResult, any Error> in
                do {
                    return .success(try await command.importReference(events: events, formatter: formatter))
                } catch {
                    // A builder stopped by the cancel fails with its own error, which is the cancel.
                    return .failure(Task.isCancelled ? CancellationError() : error)
                }
            }
            pendingCancel.attach(task)
            let outcome = await task.value
            termination.end()
            switch outcome {
            case .success(let result):
                events.emitComplete(output: result.bundleURL.path, message: "Reference import complete")
                try printSummary(result, formatter: formatter, eventsOn: eventsOn)
            case .failure(let error) where error is CancellationError:
                events.emitFailed(Self.cancelledMessage)
                printHumanLine(Self.cancelledMessage, eventsOn: eventsOn)
                throw CLIExitCode.cancelled.exitCode
            case .failure(let refusal as ImportFASTARefusal):
                events.emitFailed(refusal.message)
                printHumanLine(formatter.error(refusal.message), eventsOn: eventsOn)
                throw refusal.exitCode.exitCode
            case .failure(let error):
                events.emitFailed(CLIFailureWords.describe(error))
                throw error
            }
        }

        /// The import, which returns the published bundle once every step after the build has written.
        private func importReference(events: CLIEventEmitter, formatter: TerminalFormatter) async throws -> ReferenceBundleImportResult {
            let runClock = ProvenanceRunClock()
            let eventsOn = globalOptions.outputFormat == .json
            let inputURL = URL(fileURLWithPath: inputFile)
            events.emitStart("Importing \(inputURL.lastPathComponent)")
            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                throw ImportFASTARefusal(message: "Input file not found: \(inputFile)", exitCode: .inputError)
            }
            guard ReferenceBundleImportService.isStandaloneReferenceSource(inputURL) else {
                let ext = ReferenceBundleImportService.normalizedExtension(for: inputURL)
                throw ImportFASTARefusal(message: "Unsupported reference format: .\(ext)", exitCode: .formatError)
            }
            let annotationsURL = annotations.map { URL(fileURLWithPath: $0) }
            if annotationsURL == nil, annotationSelection != nil || sourceAlignmentBundle != nil {
                throw ImportFASTARefusal(
                    message: "--annotation-selection and --source-alignment-bundle describe --annotations. Add --annotations <bed>.",
                    exitCode: .inputError
                )
            }
            if let annotationsURL, !FileManager.default.fileExists(atPath: annotationsURL.path) {
                throw ImportFASTARefusal(message: "Annotation file not found: \(annotationsURL.path)", exitCode: .inputError)
            }
            // The selected record IDs come from reading the input as text after the build, which a
            // compressed input cannot give, so refuse before anything is written (A48 M3 review, Fix 2).
            if annotationsURL != nil,
               ReferenceBundleImportService.compressionExtensions.contains(inputURL.pathExtension.lowercased()) {
                throw ImportFASTARefusal(
                    message: "--annotations needs an uncompressed input. Decompress \(inputURL.lastPathComponent) first.",
                    exitCode: .inputError
                )
            }
            let selection = try annotationSelectionValue()

            let outputDirectory = resolveOutputDirectory(outputDir)
            // `--bundle-dir` names the folder as given, so no Reference Sequences folder is made (A48 M4).
            let refsDirectory = try bundleFolderURL ?? ReferenceSequenceFolder.ensureFolder(in: outputDirectory)
            try FileManager.default.createDirectory(at: refsDirectory, withIntermediateDirectories: true)

            printHumanLine(formatter.header("Reference Import"), eventsOn: eventsOn)
            printHumanLine("", eventsOn: eventsOn)
            if !globalOptions.quiet {
                printHumanLine(formatter.info(Self.preparingMessage), eventsOn: eventsOn)
            }

            // The service reports its preparation first and then the builder's steps, so the first
            // other message is where the text says the build began.
            let buildingLine = globalOptions.quiet ? nil : formatter.info("Building .lungfishref bundle...")
            let buildingAnnounced = OSAllocatedUnfairLock(initialState: false)
            let scale = annotationsURL == nil ? 1.0 : 0.82
            let inputs = provenanceInputURLs
            let result: ReferenceBundleImportResult
            do {
                result = try await ReferenceBundleImportService.shared.importAsReferenceBundle(
                    sourceURL: inputURL,
                    outputDirectory: refsDirectory,
                    preferredBundleName: name,
                    provenanceWorkflowName: "lungfish import fasta",
                    provenanceCommand: recordedCommand(outputDirectory: outputDirectory),
                    provenanceInputFiles: inputs.isEmpty ? nil : inputs,
                    progressHandler: { fraction, message in
                        events.emitProgress(min(scale, fraction * scale), message: message)
                        guard let buildingLine, message != Self.preparingMessage,
                              buildingAnnounced.withLock({ announced in defer { announced = true }; return !announced })
                        else { return }
                        printHumanLine(buildingLine, eventsOn: eventsOn)
                    }
                )
            } catch ReferenceBundleImportError.noSequencesFound(let url) {
                // An empty FASTA ended with the input error code before the service took over (A48 M3 review, Fix 3).
                throw ImportFASTARefusal(
                    message: ReferenceBundleImportError.noSequencesFound(url).localizedDescription,
                    exitCode: .inputError
                )
            }

            // Every write after the build happens here, and a failure or a cancel before the last one
            // returns removes the bundle, as the app's imports did (ruling A48 F2, L5).
            do {
                if let annotationsURL {
                    try Task.checkCancellation()
                    events.emitProgress(0.88, message: "Attaching projected annotations...")
                    let annotationResult = try await ReferenceBundleAnnotationImportService(toolName: CLICommandIdentity.executableName, toolKind: CLICommandIdentity.recordedToolKind)
                        .attachAnnotationTrack(sourceURL: annotationsURL, bundleURL: result.bundleURL)
                    try Task.checkCancellation()
                    try MSAExtractionAnnotationProvenance.write(
                        bundleURL: result.bundleURL,
                        sourceAlignmentBundleURL: sourceAlignmentBundle.map { URL(fileURLWithPath: $0) },
                        sourceFASTAURL: inputURL,
                        sourceAnnotationURL: annotationsURL,
                        durableSourceURLs: inputs,
                        selectedSequenceIDs: MSAExtractionAnnotationProvenance.selectedSequenceIDs(
                            inFASTA: try String(contentsOf: inputURL, encoding: .utf8)
                        ),
                        annotationSelection: selection,
                        annotationResult: annotationResult,
                        startedAt: runClock.startedAt,
                        completedAt: runClock.now
                    )
                }
                if rehydrateSourceProvenance {
                    try Task.checkCancellation()
                    try FASTQOperationProvenanceRehydrator().rehydrateReferenceBundleProvenance(
                        sourceURL: inputURL,
                        referenceBundleURL: result.bundleURL
                    )
                }
                if annotationsURL != nil || rehydrateSourceProvenance {
                    try Task.checkCancellation()
                }
            } catch {
                try? FileManager.default.removeItem(at: result.bundleURL)
                throw error
            }
            return result
        }

        /// The name, counts and first ten sequence names, read from the published manifest.
        private func printSummary(
            _ result: ReferenceBundleImportResult,
            formatter: TerminalFormatter,
            eventsOn: Bool
        ) throws {
            let manifest = try BundleManifest.load(from: result.bundleURL)
            for warning in manifest.warnings {
                printHumanLine(formatter.warning(warning.message), eventsOn: eventsOn)
            }
            let names = manifest.genome?.chromosomes.map(\.name) ?? []
            let totalLength = Int64(manifest.genome?.totalLength ?? 0)
            printHumanLine("", eventsOn: eventsOn)
            printHumanLine(formatter.header("Summary"), eventsOn: eventsOn)
            printHumanLine("", eventsOn: eventsOn)
            printHumanLine(formatter.keyValueTable([
                ("Name", result.bundleName),
                ("Sequences", String(names.count)),
                ("Total length", formatBases(totalLength)),
                ("Bundle", result.bundleURL.lastPathComponent),
            ]), eventsOn: eventsOn)
            if !names.isEmpty {
                let suffix = names.count > 10 ? " (+\(names.count - 10) more)" : ""
                printHumanLine("", eventsOn: eventsOn)
                printHumanLine("  Sequences: \(names.prefix(10).joined(separator: ", "))\(suffix)", eventsOn: eventsOn)
            }
            printHumanLine("", eventsOn: eventsOn)
            printHumanLine(formatter.success(
                "Reference import complete: \(result.bundleName) (\(names.count) sequences, \(formatBases(totalLength)))"
            ), eventsOn: eventsOn)
        }

        /// The folder `--bundle-dir` names, or nil for the Reference Sequences folder of the project.
        private var bundleFolderURL: URL? {
            bundleDir.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }

        /// The files `--provenance-input` names, in their order. The builder keeps only those that exist.
        private var provenanceInputURLs: [URL] {
            provenanceInputs.map { URL(fileURLWithPath: $0) }
        }

        /// The selection `--annotation-selection` holds, or an empty one.
        private func annotationSelectionValue() throws -> ParameterValue {
            guard let annotationSelection else { return .dictionary([:]) }
            do {
                return try JSONDecoder().decode(ParameterValue.self, from: Data(contentsOf: URL(fileURLWithPath: annotationSelection)))
            } catch {
                throw ImportFASTARefusal(
                    message: "--annotation-selection \(annotationSelection) holds no selection: \(error.localizedDescription)",
                    exitCode: .inputError
                )
            }
        }

        /// The argv the record names. That is the words the process was started with when it runs
        /// `import fasta`, else the words the app would run, with `--name` as typed (ruling A48 F2, L2).
        private func recordedCommand(outputDirectory: URL) -> [String] {
            if let observed = Self.observedArguments() { return observed }
            var command = [CLICommandIdentity.executableName] + ReferenceBundleImportService.importFASTAArguments(
                sourceURL: URL(fileURLWithPath: inputFile),
                projectURL: bundleFolderURL == nil ? outputDirectory : nil,
                bundleFolderURL: bundleFolderURL,
                preferredBundleName: name,
                provenanceInputFiles: provenanceInputURLs,
                annotationsURL: annotations.map { URL(fileURLWithPath: $0) },
                annotationSelectionURL: annotationSelection.map { URL(fileURLWithPath: $0) },
                sourceAlignmentBundleURL: sourceAlignmentBundle.map { URL(fileURLWithPath: $0) },
                rehydrateSourceProvenance: rehydrateSourceProvenance
            )
            if globalOptions.quiet {
                command.append("--quiet")
            }
            return command
        }

        /// The words the process was started with when it runs `import fasta`.
        private static func observedArguments() -> [String]? {
            let raw = CommandLine.arguments
            guard let executable = raw.first else { return nil }
            let arguments = Array(raw.dropFirst())
            guard LungfishCLI.normalizedArgumentsForParsing(arguments).starts(with: ["import", "fasta"]) else { return nil }
            return [executable] + arguments
        }
    }
}
