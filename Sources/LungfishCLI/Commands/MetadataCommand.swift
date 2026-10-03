// MetadataCommand.swift - CLI commands for FASTQ sample metadata management
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Manage FASTQ sample metadata
struct MetadataCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "metadata",
        abstract: "Manage FASTQ sample metadata",
        discussion: """
            View, edit, import, and export PHA4GE-aligned metadata for FASTQ
            dataset bundles (.lungfishfastq) and folders containing them.

            Per-bundle metadata is stored in `metadata.csv` inside each bundle.
            Folder-level metadata is stored in `samples.csv` at the folder root.

            Examples:
              lungfish-cli metadata get SampleA.lungfishfastq
              lungfish-cli metadata set SampleA.lungfishfastq --field sample_type --value "Nasopharyngeal swab"
              lungfish-cli metadata import ./RunFolder samples.csv
              lungfish-cli metadata export ./RunFolder
            """,
        subcommands: [
            MetadataGetSubcommand.self,
            MetadataSetSubcommand.self,
            MetadataImportSubcommand.self,
            MetadataExportSubcommand.self,
            MetadataExportBioSampleSubcommand.self,
        ],
        defaultSubcommand: MetadataGetSubcommand.self
    )
}

// MARK: - Set Subcommand

/// Set a metadata field on a FASTQ bundle
struct MetadataSetSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set a metadata field on a FASTQ bundle",
        discussion: """
            Sets or updates a single metadata field in a .lungfishfastq bundle's
            metadata.csv file. Creates the file if it doesn't exist.

            Field names use PHA4GE/NCBI BioSample conventions (snake_case).
            Common fields: sample_name, sample_type, collection_date, geo_loc_name,
            host, sample_role, patient_id, run_id, batch_id.

            Examples:
              lungfish-cli metadata set Sample.lungfishfastq --field sample_type --value "Blood"
              lungfish-cli metadata set Sample.lungfishfastq --field sample_role --value negative_control
              lungfish-cli metadata set Sample.lungfishfastq --field custom_notes --value "Re-extracted"
            """
    )

    @Argument(help: "Path to the .lungfishfastq bundle")
    var bundlePath: String

    @Option(name: .long, help: "Metadata field name (e.g., sample_type, collection_date)")
    var field: String

    @Option(name: .long, help: "Value to set for the field")
    var value: String

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let startedAt = Date()
        let bundleURL = URL(fileURLWithPath: bundlePath)
        guard FileManager.default.fileExists(atPath: bundlePath) else {
            throw CLIError.inputFileNotFound(path: bundlePath)
        }
        let metadataURL = FASTQBundleCSVMetadata.metadataURL(in: bundleURL)
        let inputRecords = MetadataProvenanceSupport.preMutationRecords(for: metadataURL)

        // Load existing metadata or create new
        let sampleName = bundleURL.deletingPathExtension().lastPathComponent
        var meta: FASTQSampleMetadata
        if let existing = FASTQBundleCSVMetadata.load(from: bundleURL) {
            meta = FASTQSampleMetadata(from: existing, fallbackName: sampleName)
        } else {
            meta = FASTQSampleMetadata(sampleName: sampleName)
        }

        // Set the field
        meta.setValue(value, forCSVHeader: field)

        let snapshot = try ProvenancePublicationSnapshot(
            urls: MetadataProvenanceSupport.metadataSetPublicationArtifacts(
                bundleURL: bundleURL,
                metadataURL: metadataURL
            ),
            backupNamePrefix: "lungfish-metadata-set"
        )
        defer { snapshot.discard() }
        do {
            // Save back
            let legacyCSV = meta.toLegacyCSV()
            try FASTQBundleCSVMetadata.save(legacyCSV, to: bundleURL)

            try await MetadataProvenanceSupport.recordMetadataSet(
                bundleURL: bundleURL,
                field: field,
                value: value,
                globalOptions: globalOptions,
                inputs: inputRecords,
                outputURL: metadataURL,
                startedAt: startedAt
            )
        } catch {
            try snapshot.restore()
            throw error
        }

        if globalOptions.outputFormat == .text && !globalOptions.quiet {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            print(formatter.success("Set \(field) = \(value) on \(bundleURL.lastPathComponent)"))
        } else if globalOptions.outputFormat == .json {
            let handler = JSONOutputHandler()
            handler.writeData([
                "bundle": bundlePath,
                "field": field,
                "value": value,
                "status": "ok",
            ], label: nil)
        }
    }
}

// MARK: - Import Subcommand

/// Import folder-level metadata from a CSV file
struct MetadataImportSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import folder-level metadata from a CSV file",
        discussion: """
            Reads a CSV file and writes it as samples.csv into the specified folder.
            Also syncs metadata to per-bundle metadata.csv files for bundles whose
            sample_name matches a bundle directory name.

            The CSV must have a header row. The `sample_name` column is used to
            match rows to .lungfishfastq bundles in the folder.

            Examples:
              lungfish-cli metadata import ./RunFolder samplesheet.csv
              lungfish-cli metadata import ./RunFolder samplesheet.csv --sync-bundles
            """
    )

    @Argument(help: "Path to the folder containing .lungfishfastq bundles")
    var folderPath: String

    @Argument(help: "Path to the CSV file to import")
    var csvPath: String

    @Flag(name: .customLong("sync-bundles"), help: "Also write per-bundle metadata.csv files")
    var syncBundles: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let startedAt = Date()
        let folderURL = URL(fileURLWithPath: folderPath)
        let csvURL = URL(fileURLWithPath: csvPath)

        guard FileManager.default.fileExists(atPath: folderPath) else {
            throw CLIError.inputFileNotFound(path: folderPath)
        }
        guard FileManager.default.fileExists(atPath: csvPath) else {
            throw CLIError.inputFileNotFound(path: csvPath)
        }

        // Parse the CSV
        let csvContent = try String(contentsOf: csvURL, encoding: .utf8)
        guard let folderMeta = FASTQFolderMetadata.parse(csv: csvContent) else {
            throw CLIError.conversionFailed(reason: "Failed to parse CSV file: \(csvPath)")
        }

        let snapshot = try ProvenancePublicationSnapshot(
            urls: MetadataProvenanceSupport.metadataImportPublicationArtifacts(
                folderURL: folderURL,
                folderMeta: folderMeta,
                syncBundles: syncBundles
            ),
            backupNamePrefix: "lungfish-metadata-import"
        )
        defer { snapshot.discard() }
        do {
            // Save
            if syncBundles {
                try FASTQFolderMetadata.saveWithPerBundleSync(folderMeta, to: folderURL)
            } else {
                try FASTQFolderMetadata.save(folderMeta, to: folderURL)
            }

            try await MetadataProvenanceSupport.recordMetadataImport(
                folderURL: folderURL,
                csvURL: csvURL,
                folderMeta: folderMeta,
                syncBundles: syncBundles,
                globalOptions: globalOptions,
                startedAt: startedAt
            )
        } catch {
            try snapshot.restore()
            throw error
        }

        if globalOptions.outputFormat == .text && !globalOptions.quiet {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            print(formatter.success("Imported metadata for \(folderMeta.samples.count) samples to \(folderURL.lastPathComponent)/samples.csv"))
            if syncBundles {
                print(formatter.info("Per-bundle metadata.csv files synced."))
            }
        } else if globalOptions.outputFormat == .json {
            let handler = JSONOutputHandler()
            handler.writeData([
                "folder": folderPath,
                "samplesImported": "\(folderMeta.samples.count)",
                "syncedBundles": "\(syncBundles)",
                "status": "ok",
            ], label: nil)
        }
    }
}

// MARK: - Metadata Provenance

private enum MetadataProvenanceSupport {
    static func preMutationRecords(for url: URL) -> [FileRecord] {
        if FileManager.default.fileExists(atPath: url.path) {
            return [ProvenanceRecorder.fileRecord(url: url, format: .text, role: .input)]
        }
        return []
    }

    static func metadataSetPublicationArtifacts(bundleURL: URL, metadataURL: URL) -> [URL] {
        [metadataURL]
            + ProvenancePublicationArtifacts.bundleRootArtifacts(for: bundleURL)
            + ProvenancePublicationArtifacts.fileSidecarArtifacts(for: metadataURL)
    }

    static func metadataImportPublicationArtifacts(
        folderURL: URL,
        folderMeta: FASTQFolderMetadata,
        syncBundles: Bool
    ) -> [URL] {
        let outputURLs = metadataImportOutputURLs(
            folderURL: folderURL,
            folderMeta: folderMeta,
            syncBundles: syncBundles,
            requireExistingPayload: false
        )
        var artifacts = outputURLs
            + ProvenancePublicationArtifacts.bundleRootArtifacts(for: folderURL)
        for outputURL in outputURLs {
            artifacts += ProvenancePublicationArtifacts.fileSidecarArtifacts(for: outputURL)
        }
        if syncBundles {
            for bundleURL in syncedBundleURLs(folderURL: folderURL, folderMeta: folderMeta) {
                artifacts += ProvenancePublicationArtifacts.bundleRootArtifacts(for: bundleURL)
            }
        }
        return artifacts
    }

    static func recordMetadataSet(
        bundleURL: URL,
        field: String,
        value: String,
        globalOptions: GlobalOptions,
        inputs: [FileRecord],
        outputURL: URL,
        startedAt: Date
    ) async throws {
        let command = [
            CLICommandIdentity.executableName, "metadata", "set",
            bundleURL.path,
            "--field", field,
            "--value", value
        ] + globalOptionArguments(globalOptions)
        let explicit: [String: ParameterValue] = [
            "bundlePath": .file(bundleURL),
            "field": .string(field),
            "value": .string(value)
        ].merging(globalExplicitOptions(globalOptions)) { current, _ in current }

        try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish metadata set",
            parameters: explicit,
            defaults: globalDefaultOptions(),
            resolved: resolvedOptions(explicit: explicit, globalOptions: globalOptions),
            toolName: "lungfish metadata set",
            toolVersion: WorkflowRun.currentAppVersion,
            command: command,
            inputs: inputs,
            outputs: [
                ProvenanceRecorder.fileRecord(url: outputURL, format: .text, role: .output)
            ],
            exitCode: 0,
            wallTime: Date().timeIntervalSince(startedAt),
            stderr: nil,
            status: .completed,
            outputDirectory: bundleURL
        )
    }

    static func recordMetadataImport(
        folderURL: URL,
        csvURL: URL,
        folderMeta: FASTQFolderMetadata,
        syncBundles: Bool,
        globalOptions: GlobalOptions,
        startedAt: Date
    ) async throws {
        let command = [
            CLICommandIdentity.executableName, "metadata", "import",
            folderURL.path,
            csvURL.path
        ] + (syncBundles ? ["--sync-bundles"] : []) + globalOptionArguments(globalOptions)
        let explicit: [String: ParameterValue] = [
            "folderPath": .file(folderURL),
            "csvPath": .file(csvURL),
            "syncBundles": .boolean(syncBundles)
        ].merging(globalExplicitOptions(globalOptions)) { current, _ in current }
        var defaults = globalDefaultOptions()
        defaults["syncBundles"] = .boolean(false)
        let outputs = metadataImportOutputRecords(
            folderURL: folderURL,
            folderMeta: folderMeta,
            syncBundles: syncBundles
        )

        let envelope = try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish metadata import",
            parameters: explicit,
            defaults: defaults,
            resolved: resolvedOptions(explicit: explicit, defaults: defaults, globalOptions: globalOptions),
            toolName: "lungfish metadata import",
            toolVersion: WorkflowRun.currentAppVersion,
            command: command,
            inputs: [
                ProvenanceRecorder.fileRecord(url: csvURL, format: .text, role: .input)
            ],
            outputs: outputs,
            exitCode: 0,
            wallTime: Date().timeIntervalSince(startedAt),
            stderr: nil,
            status: .completed,
            outputDirectory: folderURL
        )
        if syncBundles {
            try writeSyncedBundleRootProvenance(
                envelope: envelope,
                folderURL: folderURL,
                folderMeta: folderMeta
            )
        }
    }

    private static func metadataImportOutputRecords(
        folderURL: URL,
        folderMeta: FASTQFolderMetadata,
        syncBundles: Bool
    ) -> [FileRecord] {
        let outputURLs = metadataImportOutputURLs(
            folderURL: folderURL,
            folderMeta: folderMeta,
            syncBundles: syncBundles,
            requireExistingPayload: true
        )
        return outputURLs.map {
            ProvenanceRecorder.fileRecord(url: $0, format: .text, role: .output)
        }
    }

    private static func metadataImportOutputURLs(
        folderURL: URL,
        folderMeta: FASTQFolderMetadata,
        syncBundles: Bool,
        requireExistingPayload: Bool
    ) -> [URL] {
        var outputURLs = [FASTQFolderMetadata.metadataURL(in: folderURL)]
        guard syncBundles else { return outputURLs }
        outputURLs += syncedBundleURLs(folderURL: folderURL, folderMeta: folderMeta).compactMap { bundleURL in
            let metadataURL = FASTQBundleCSVMetadata.metadataURL(in: bundleURL)
            guard !requireExistingPayload || FileManager.default.fileExists(atPath: metadataURL.path) else {
                return nil
            }
            return metadataURL
        }
        return outputURLs
    }

    private static func syncedBundleURLs(folderURL: URL, folderMeta: FASTQFolderMetadata) -> [URL] {
        folderMeta.sampleOrder.compactMap { sampleName in
            let bundleName = sampleName.hasSuffix(".lungfishfastq")
                ? sampleName
                : "\(sampleName).lungfishfastq"
            let bundleURL = folderURL.appendingPathComponent(bundleName)
            guard FileManager.default.fileExists(atPath: bundleURL.path) else {
                return nil
            }
            return bundleURL
        }
    }

    private static func writeSyncedBundleRootProvenance(
        envelope: ProvenanceEnvelope,
        folderURL: URL,
        folderMeta: FASTQFolderMetadata
    ) throws {
        let writer = ProvenanceWriter()
        for sampleName in folderMeta.sampleOrder {
            let bundleName = sampleName.hasSuffix(".lungfishfastq")
                ? sampleName
                : "\(sampleName).lungfishfastq"
            let bundleURL = folderURL.appendingPathComponent(bundleName)
            let metadataURL = FASTQBundleCSVMetadata.metadataURL(in: bundleURL)
            guard FileManager.default.fileExists(atPath: metadataURL.path) else {
                continue
            }

            let payload = ProvenanceFileDescriptor(
                fileRecord: ProvenanceRecorder.fileRecord(url: metadataURL, format: .text, role: .output)
            )
            try writer.write(envelope.focusedOnOutput(payload), to: bundleURL)
        }
    }

    private static func globalOptionArguments(_ options: GlobalOptions) -> [String] {
        var arguments: [String] = []
        if options.outputFormat != .text {
            arguments += ["--format", options.outputFormat.rawValue]
        }
        if options.quiet {
            arguments.append("--quiet")
        }
        if options.verbosity > 0 {
            arguments += Array(repeating: "--verbose", count: options.verbosity)
        }
        if options.showProgress {
            arguments.append("--progress")
        }
        if options.noProgress {
            arguments.append("--no-progress")
        }
        if options.debug {
            arguments.append("--debug")
        }
        if let logFile = options.logFile {
            arguments += ["--log-file", logFile]
        }
        if options.noColor {
            arguments.append("--no-color")
        }
        if let threads = options.threads {
            arguments += ["--threads", String(threads)]
        }
        return arguments
    }

    private static func globalExplicitOptions(_ options: GlobalOptions) -> [String: ParameterValue] {
        var explicit: [String: ParameterValue] = [:]
        if options.outputFormat != .text {
            explicit["format"] = .string(options.outputFormat.rawValue)
        }
        if options.quiet {
            explicit["quiet"] = .boolean(true)
        }
        if options.verbosity > 0 {
            explicit["verbosity"] = .integer(options.verbosity)
        }
        if options.showProgress {
            explicit["progress"] = .boolean(true)
        }
        if options.noProgress {
            explicit["noProgress"] = .boolean(true)
        }
        if options.debug {
            explicit["debug"] = .boolean(true)
        }
        if let logFile = options.logFile {
            explicit["logFile"] = .file(URL(fileURLWithPath: logFile))
        }
        if options.noColor {
            explicit["noColor"] = .boolean(true)
        }
        if let threads = options.threads {
            explicit["threads"] = .integer(threads)
        }
        return explicit
    }

    private static func globalDefaultOptions() -> [String: ParameterValue] {
        [
            "format": .string(OutputFormat.text.rawValue),
            "quiet": .boolean(false),
            "verbosity": .integer(0),
            "progress": .boolean(false),
            "noProgress": .boolean(false),
            "debug": .boolean(false),
            "logFile": .null,
            "noColor": .boolean(false),
            "threads": .null
        ]
    }

    private static func resolvedOptions(
        explicit: [String: ParameterValue],
        defaults: [String: ParameterValue] = globalDefaultOptions(),
        globalOptions: GlobalOptions
    ) -> [String: ParameterValue] {
        var resolved = defaults
        resolved.merge(explicit) { _, explicit in explicit }
        resolved["format"] = .string(globalOptions.outputFormat.rawValue)
        resolved["quiet"] = .boolean(globalOptions.quiet)
        resolved["verbosity"] = .integer(globalOptions.verbosity)
        resolved["progress"] = .boolean(globalOptions.showProgress)
        resolved["noProgress"] = .boolean(globalOptions.noProgress)
        resolved["debug"] = .boolean(globalOptions.debug)
        resolved["logFile"] = globalOptions.logFile.map { .file(URL(fileURLWithPath: $0)) } ?? .null
        resolved["noColor"] = .boolean(globalOptions.noColor)
        resolved["threads"] = globalOptions.threads.map(ParameterValue.integer) ?? .integer(globalOptions.effectiveThreads)
        resolved["useColors"] = .boolean(globalOptions.useColors)
        resolved["shouldShowProgress"] = .boolean(globalOptions.shouldShowProgress)
        return resolved
    }
}
