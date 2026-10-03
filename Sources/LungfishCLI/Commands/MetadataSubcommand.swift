// MetadataSubcommand.swift - Import sample metadata CSV/TSV into a result bundle
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

    // MARK: - Metadata Import

    /// Import sample metadata CSV/TSV into a result bundle.
    ///
    /// Reads a comma- or tab-delimited file, auto-detects the sample ID column,
    /// and stores the metadata inside the bundle's `metadata/` directory.
    ///
    /// ```
    /// # Import metadata CSV into an NAO-MGS result
    /// lungfish import metadata metadata.csv --bundle ./Analyses/naomgs-result/
    /// ```
    struct MetadataSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "metadata",
            abstract: "Import sample metadata CSV/TSV into a result bundle"
        )

        @Argument(help: "Path to the metadata CSV or TSV file")
        var inputPath: String

        @Option(
            name: [.customLong("bundle"), .customShort("b")],
            help: "Path to the result bundle directory (e.g., naomgs-*, kraken2-*)"
        )
        var bundlePath: String

        @OptionGroup var globalOptions: GlobalOptions

        func run() throws {
            let startedAt = Date()
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let fm = FileManager.default

            let inputURL = URL(fileURLWithPath: inputPath)
            guard fm.fileExists(atPath: inputURL.path) else {
                print(formatter.error("Metadata file not found: \(inputPath)"))
                throw CLIExitCode.inputError.exitCode
            }

            let bundleURL = URL(fileURLWithPath: bundlePath)
            guard fm.fileExists(atPath: bundleURL.path) else {
                print(formatter.error("Bundle directory not found: \(bundlePath)"))
                throw CLIExitCode.inputError.exitCode
            }

            let csvData = try Data(contentsOf: inputURL)

            let knownSampleIds = try ResultBundleSampleMetadataResolver.knownSampleIDs(in: bundleURL)

            if knownSampleIds.isEmpty {
                print(formatter.warning("No sample IDs found in bundle — metadata will be stored but may not match"))
            }

            // Scan for sample column
            let scanResult = try SampleMetadataStore.scanForSampleColumn(
                csvData: csvData,
                knownSampleIds: knownSampleIds
            )

            guard let bestColumn = scanResult.bestColumn else {
                print(formatter.error("Could not identify a sample ID column in the metadata file"))
                if !scanResult.candidates.isEmpty {
                    print("Candidate columns: \(scanResult.candidates.map(\.name).joined(separator: ", "))")
                }
                throw CLIExitCode.inputError.exitCode
            }

            let store = try SampleMetadataStore(
                scanResult: scanResult,
                sampleColumnIndex: bestColumn.index,
                knownSampleIds: knownSampleIds
            )

            let metadataURL = bundleURL.appendingPathComponent("metadata/sample_metadata.tsv")
            let snapshot = try ProvenancePublicationSnapshot(
                urls: sampleMetadataPublicationArtifacts(bundleURL: bundleURL, metadataURL: metadataURL),
                backupNamePrefix: "lungfish-import-metadata"
            )
            defer { snapshot.discard() }
            do {
                // Persist to bundle (pass original CSV data for storage)
                try store.persist(originalData: csvData, to: bundleURL)
                try writeProvenance(
                    store: store,
                    inputURL: inputURL,
                    bundleURL: bundleURL,
                    metadataURL: metadataURL,
                    sampleColumnIndex: bestColumn.index,
                    sampleColumnName: bestColumn.name,
                    knownSampleCount: knownSampleIds.count,
                    totalMetadataRows: scanResult.totalRows,
                    startedAt: startedAt
                )
            } catch {
                try snapshot.restore()
                throw error
            }

            print(formatter.header("Metadata Import"))
            print("")
            print(formatter.keyValueTable([
                ("Input", inputURL.lastPathComponent),
                ("Bundle", bundleURL.lastPathComponent),
                ("Columns", String(store.columnNames.count)),
                ("Matched samples", String(store.matchedSampleIds.count)),
                ("Unmatched records", String(store.unmatchedRecords.count)),
                ("Sample ID column", bestColumn.name),
            ]))
            print("")

            if !store.matchedSampleIds.isEmpty {
                print(formatter.success("Imported \(store.columnNames.count) metadata columns for \(store.matchedSampleIds.count) sample(s)"))
            } else {
                print(formatter.warning("No sample IDs matched — metadata stored but not linked"))
            }
        }

        private func sampleMetadataPublicationArtifacts(bundleURL: URL, metadataURL: URL) -> [URL] {
            let metadataDirectory = metadataURL.deletingLastPathComponent()
            return [metadataDirectory]
                + ProvenancePublicationArtifacts.bundleRootArtifacts(for: bundleURL)
        }

        private func writeProvenance(
            store: SampleMetadataStore,
            inputURL: URL,
            bundleURL: URL,
            metadataURL: URL,
            sampleColumnIndex: Int,
            sampleColumnName: String,
            knownSampleCount: Int,
            totalMetadataRows: Int,
            startedAt: Date
        ) throws {
            var builder = ProvenanceRunBuilder(
                workflowName: "Sample metadata import",
                workflowVersion: WorkflowRun.currentAppVersion,
                toolName: CLICommandIdentity.executableName,
                toolVersion: WorkflowRun.currentAppVersion
            )
            .argv([
                CLICommandIdentity.executableName,
                "import",
                "metadata",
            ] + replayableGlobalArguments() + [
                inputURL.path,
                "--bundle",
                bundleURL.path,
            ])
            .options(
                explicit: [
                    "metadata": .file(inputURL),
                    "bundle": .file(bundleURL),
                    "sampleColumnIndex": .integer(sampleColumnIndex),
                    "sampleColumnName": .string(sampleColumnName),
                ],
                defaults: [
                    "destination": .string("metadata/sample_metadata.tsv"),
                ],
                resolved: [
                    "knownSampleCount": .integer(knownSampleCount),
                    "matchedSampleCount": .integer(store.matchedSampleIds.count),
                    "unmatchedMetadataRowCount": .integer(store.unmatchedRecords.count),
                    "totalMetadataRows": .integer(totalMetadataRows),
                    "quiet": .boolean(globalOptions.quiet),
                    "verbosity": .integer(globalOptions.verbosity),
                    "outputFormat": .string(globalOptions.outputFormat.rawValue),
                    "noColor": .boolean(globalOptions.noColor),
                ]
            )
            .runtime(ProvenanceRuntimeIdentity())

            builder = try builder.input(inputURL, format: .text, role: .input)
            for contextURL in ResultBundleSampleMetadataResolver.sampleMetadataContextFiles(in: bundleURL) {
                builder = try builder.input(contextURL, format: format(for: contextURL), role: .input)
            }
            builder = try builder.output(metadataURL, format: .text, role: .output)

            let envelope = try builder.complete(exitStatus: 0, startedAt: startedAt, endedAt: Date())
            _ = try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundleURL)
        }

        private func format(for url: URL) -> FileFormat {
            switch url.pathExtension.lowercased() {
            case "json":
                return .json
            case "fa", "fasta", "fna":
                return .fasta
            default:
                return .text
            }
        }

        private func replayableGlobalArguments() -> [String] {
            var argv: [String] = []
            if globalOptions.outputFormat != .text {
                argv += ["--format", globalOptions.outputFormat.rawValue]
            }
            if globalOptions.verbosity > 0 {
                argv += Array(repeating: "--verbose", count: globalOptions.verbosity)
            }
            if globalOptions.quiet {
                argv.append("--quiet")
            }
            if globalOptions.showProgress {
                argv.append("--progress")
            }
            if globalOptions.noProgress {
                argv.append("--no-progress")
            }
            if globalOptions.debug {
                argv.append("--debug")
            }
            if let logFile = globalOptions.logFile {
                argv += ["--log-file", logFile]
            }
            if globalOptions.noColor {
                argv.append("--no-color")
            }
            if let threads = globalOptions.threads {
                argv += ["--threads", String(threads)]
            }
            return argv
        }
    }
