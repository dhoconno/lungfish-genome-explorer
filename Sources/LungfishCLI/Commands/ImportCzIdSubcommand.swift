// ImportCzIdSubcommand.swift - First-class CZ-ID project import command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension ImportCommand {
    /// Import a hosted CZ-ID taxon report into a project classification bundle.
    ///
    /// The Import Center's CZ-ID row runs this command with `--format json` and shows its events (Phase 2.12
    /// lane 12.06). SIGTERM, the row's Cancel, cancels the import (decision S7 of Phase 2.11). A report file is
    /// read on a thread of its own first, so a cancel while it is read ends the run at once and writes nothing.
    /// The conversion then writes the bundle on the run's own task, so a cancel during the write waits for it,
    /// and the run removes the bundle it made before it records the cancel and exits 125.
    struct CzIdSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "cz-id",
            abstract: "Import hosted CZ-ID classification results into a project"
        )

        @Argument(help: "Path to a CZ-ID taxon report TSV, ZIP archive, or extracted export folder")
        var inputPath: String

        @Option(name: .customLong("project"), help: "Lungfish project directory to import into")
        var projectPath: String

        @Option(name: .customLong("sample-name"), help: "Sample name for the imported .lungfishtax bundle")
        var sampleName: String

        @Option(name: .customLong("metadata"), help: "Optional CZ-ID metadata sidecar path to record in provenance")
        var metadataPath: String?

        @Option(name: .customLong("non-host-fastq"), help: "Optional non-host FASTQ path to record in provenance")
        var nonHostFastqPath: String?

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let fileManager = FileManager.default
            let inputURL = URL(fileURLWithPath: inputPath)
            let projectURL = URL(fileURLWithPath: projectPath).standardizedFileURL
            let eventsOn = globalOptions.outputFormat == .json
            let emitter = ImportCLIEventEmitter(enabled: eventsOn, quiet: globalOptions.quiet)
            emitter.emitStart(kind: BundleKindID.czIdResult.rawValue)

            guard fileManager.fileExists(atPath: inputURL.path) else {
                emitter.emitFailed("CZ-ID input not found: \(inputPath)")
                throw CLIExitCode.inputError.exitCode
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: projectURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                emitter.emitFailed("Project directory not found: \(projectURL.path)")
                throw CLIExitCode.inputError.exitCode
            }

            let trimmedSampleName = sampleName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSampleName.isEmpty else {
                emitter.emitFailed("--sample-name cannot be empty")
                throw CLIExitCode.inputError.exitCode
            }

            let metadataURL = metadataPath.map(URL.init(fileURLWithPath:))
            if let metadataURL, !fileManager.fileExists(atPath: metadataURL.path) {
                emitter.emitFailed("Metadata sidecar not found: \(metadataURL.path)")
                throw CLIExitCode.inputError.exitCode
            }

            let nonHostFastqURL = nonHostFastqPath.map(URL.init(fileURLWithPath:))
            if let nonHostFastqURL, !fileManager.fileExists(atPath: nonHostFastqURL.path) {
                emitter.emitFailed("Non-host FASTQ not found: \(nonHostFastqURL.path)")
                throw CLIExitCode.inputError.exitCode
            }

            let classificationsURL = projectURL.appendingPathComponent("Classifications", isDirectory: true)
            let bundleURL = classificationsURL.appendingPathComponent(
                "\(CzIdProjectImportWorkflow.bundleFileName(for: trimmedSampleName)).lungfishtax",
                isDirectory: true
            )
            guard !fileManager.fileExists(atPath: bundleURL.path) else {
                emitter.emitFailed("Classification bundle already exists: \(bundleURL.path)")
                throw CLIExitCode.outputError.exitCode
            }

            var command = [
                CLICommandIdentity.executableName,
                "import",
                "cz-id",
                inputURL.path,
                "--project",
                projectURL.path,
                "--sample-name",
                trimmedSampleName,
            ]
            if let metadataPath {
                command.append(contentsOf: ["--metadata", metadataPath])
            }
            if let nonHostFastqPath {
                command.append(contentsOf: ["--non-host-fastq", nonHostFastqPath])
            }

            let recordedCommand = command
            let readsReportFirst = Self.isReportFile(inputURL)
            let startedAt = Date()
            let destination = ImportDestination()
            let outcome = await ImportCancellation.run { () async throws -> CzIdConversion in
                try FileManager.default.createDirectory(at: classificationsURL, withIntermediateDirectories: true)
                destination.set(bundleURL)
                if readsReportFirst {
                    emitter.emitProgress(0.12, message: "Reading \(inputURL.lastPathComponent)...")
                    _ = try await ImportCancellation.blocking { try CzIdDataConverter.parseTaxonReport(at: inputURL) }
                }
                emitter.emitProgress(0.35, message: "Converting \(inputURL.lastPathComponent)...")
                let conversion = try await CzIdImportPreview.withResolvedReport(from: inputURL) { resolved in
                    try CzIdDataConverter.convertTaxonReport(
                        at: resolved.reportURL,
                        outputDirectory: bundleURL,
                        command: recordedCommand,
                        sourceInputURL: resolved.selectedSourceURL,
                        sampleNameOverride: trimmedSampleName,
                        additionalInputURLs: [metadataURL, nonHostFastqURL].compactMap { $0 },
                        provenanceToolName: "lungfish import cz-id",
                        provenanceParameters: [
                            "project": .file(projectURL),
                            "sampleName": .string(trimmedSampleName),
                            "czIdSchemaVersion": .string(CzIdDataConverter.schemaVersion),
                            "sourcePath": .file(inputURL),
                            "outputBundle": .file(bundleURL),
                            "metadataPath": metadataURL.map(ParameterValue.file) ?? .null,
                            "nonHostFastqPath": nonHostFastqURL.map(ParameterValue.file) ?? .null,
                        ]
                    )
                }
                // A cancel that came during the write is still a cancel. Nothing writes to the bundle any more,
                // so the cancel arm removes all of it.
                try Task.checkCancellation()
                return conversion
            }

            switch outcome {
            case .success(let conversion):
                emitter.emitComplete(bundle: bundleURL, kind: .czIdResult)
                if !globalOptions.quiet {
                    let formatter = TerminalFormatter(useColors: globalOptions.useColors)
                    printHumanLine(formatter.header("CZ-ID Import"), eventsOn: eventsOn)
                    printHumanLine("", eventsOn: eventsOn)
                    printHumanLine(formatter.keyValueTable([
                        ("Sample", conversion.manifest?.sampleName ?? trimmedSampleName),
                        ("Rows", String(conversion.parsed.rows.count)),
                        ("Pipeline", conversion.parsed.metadata.pipelineVersion ?? "unknown"),
                        ("NT database", conversion.parsed.metadata.ntDatabaseVersion ?? "unknown"),
                        ("NR database", conversion.parsed.metadata.nrDatabaseVersion ?? "unknown"),
                        ("Output", bundleURL.path),
                    ]), eventsOn: eventsOn)
                    printHumanLine("", eventsOn: eventsOn)
                    printHumanLine(formatter.success("Imported CZ-ID result into \(bundleURL.path)"), eventsOn: eventsOn)
                }
            case .failure(let error) where error is CancellationError:
                destination.removeIfCreatedByThisRun()
                throw await ImportCancellation.finish(
                    emitter: emitter,
                    command: "import cz-id",
                    parameters: ["input": .file(inputURL), "project": .file(projectURL)],
                    recordDirectory: projectURL,
                    startedAt: startedAt
                )
            case .failure(let exitCode as ExitCode):
                throw exitCode
            case .failure(let error):
                // The in-process import the app ran before removed a bundle it could not finish, and so does this.
                destination.removeIfCreatedByThisRun()
                emitter.emitFailed(CLIFailureWords.describe(error))
                throw CLIExitCode.formatError.exitCode
            }
        }

        /// Whether `url` is a taxon report file, which the command reads on its own before the conversion,
        /// rather than a ZIP archive or an extracted export folder.
        private static func isReportFile(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
            return !isDirectory.boolValue && url.pathExtension.lowercased() != "zip"
        }
    }
}
