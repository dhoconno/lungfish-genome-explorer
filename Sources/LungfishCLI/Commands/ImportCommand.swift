// ImportCommand.swift - CLI commands for importing files into Lungfish projects
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Import files into a Lungfish project.
///
/// Provides subcommands for importing different file types (BAM, VCF, FASTA,
/// Kraken2 reports, EsViritu results, TaxTriage results, and NAO-MGS results)
/// into a Lungfish project directory. Each subcommand validates the input,
/// copies or transforms files into the project structure, and prints a summary.
///
/// ## Examples
///
/// ```
/// # Import a BAM file
/// lungfish import bam aligned.sorted.bam -o ./project/
///
/// # Import a VCF file
/// lungfish import vcf variants.vcf.gz -o ./project/
///
/// # Import a reference FASTA
/// lungfish import fasta reference.fasta -o ./project/ --name "SARS-CoV-2"
///
/// # Import Kraken2 results
/// lungfish import kraken2 results.kreport -o ./project/
///
/// # Import EsViritu results
/// lungfish import esviritu results_dir/ -o ./project/
///
/// # Import TaxTriage results
/// lungfish import taxtriage results_dir/ -o ./project/
///
/// # Import NAO-MGS results
/// lungfish import nao-mgs virus_hits_final.tsv.gz -o ./project/
/// ```
struct ImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import files into a Lungfish project",
        discussion: """
        Import various bioinformatics file types into a Lungfish project
        directory. Each subcommand handles format-specific validation,
        file organization, and summary output.
        """,
        subcommands: [
            BAMSubcommand.self,
            VCFSubcommand.self,
            FASTASubcommand.self,
            MSASubcommand.self,
            TreeSubcommand.self,
            FastqSubcommand.self,
            GeneiousSubcommand.self,
            ApplicationExportSubcommand.self,
            SampleMetadataSubcommand.self,
            Kraken2Subcommand.self,
            EsVirituSubcommand.self,
            TaxTriageSubcommand.self,
            NaoMgsSubcommand.self,
            NvdSubcommand.self,
            CzIdSubcommand.self,
            MetadataSubcommand.self,
        ]
    )
}

// MARK: - BAM Import

extension ImportCommand {

    /// Import sample metadata CSV/TSV into all variant tracks in a reference bundle.
    struct SampleMetadataSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sample-metadata",
            abstract: "Import sample metadata CSV/TSV into variant tracks in a reference bundle"
        )

        @Argument(help: "Path to the metadata CSV or TSV file")
        var inputPath: String

        @Option(
            name: [.customLong("bundle"), .customShort("b")],
            help: "Path to the reference bundle directory"
        )
        var bundlePath: String

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let startedAt = Date()
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let fileManager = FileManager.default
            let inputURL = URL(fileURLWithPath: inputPath)
            let bundleURL = URL(fileURLWithPath: bundlePath)
            let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)

            guard fileManager.fileExists(atPath: inputURL.path) else {
                print(formatter.error("Metadata file not found: \(inputPath)"))
                throw CLIExitCode.inputError.exitCode
            }

            guard fileManager.fileExists(atPath: bundleURL.path) else {
                print(formatter.error("Bundle directory not found: \(bundlePath)"))
                throw CLIExitCode.inputError.exitCode
            }

            let manifest = try BundleManifest.load(from: bundleURL)
            let databaseURLs = manifest.variants.compactMap { track -> URL? in
                guard let databasePath = track.databasePath else { return nil }
                return bundleURL.appendingPathComponent(databasePath)
            }
            guard !databaseURLs.isEmpty else {
                print(formatter.error("This bundle has no variant databases to apply metadata to."))
                throw CLIExitCode.inputError.exitCode
            }

            let format: MetadataFormat
            switch inputURL.pathExtension.lowercased() {
            case "csv":
                format = .csv
            case "tsv", "txt":
                format = .tsv
            default:
                print(formatter.error("Unsupported metadata format: .\(inputURL.pathExtension). Use .csv, .tsv, or .txt"))
                throw CLIExitCode.formatError.exitCode
            }

            let inputRecords = sampleMetadataInputRecords(
                inputURL: inputURL,
                metadataFormat: format,
                manifestURL: manifestURL,
                databaseURLs: databaseURLs
            )
            let rollbackSnapshot = try createSampleMetadataRollbackSnapshot(
                bundleURL: bundleURL,
                databaseURLs: databaseURLs
            )
            defer { removeRollbackBackup(rollbackSnapshot) }

            do {
                var totalUpdated = 0
                var updatedTracks = 0

                for databaseURL in databaseURLs {
                    let database = try VariantDatabase(url: databaseURL, readWrite: true)
                    totalUpdated += try database.importSampleMetadata(from: inputURL, format: format)
                    updatedTracks += 1
                }

                let outputRecords = sampleMetadataOutputRecords(databaseURLs: databaseURLs)
                try await CLIProvenanceSupport.recordSingleStepRun(
                    name: "lungfish import sample-metadata",
                    parameters: sampleMetadataProvenanceParameters(
                        inputURL: inputURL,
                        bundleURL: bundleURL,
                        metadataFormat: format
                    ),
                    defaults: sampleMetadataProvenanceDefaults(),
                    resolved: sampleMetadataProvenanceResolved(
                        inputURL: inputURL,
                        bundleURL: bundleURL,
                        metadataFormat: format,
                        updatedTracks: updatedTracks,
                        sampleRowsUpdated: totalUpdated,
                        databaseURLs: databaseURLs
                    ),
                    toolName: "lungfish import sample-metadata",
                    toolVersion: "lungfish-cli \(LungfishCLI.configuration.version)",
                    command: sampleMetadataProvenanceCommand(inputURL: inputURL, bundleURL: bundleURL),
                    inputs: inputRecords,
                    outputs: outputRecords,
                    exitCode: 0,
                    wallTime: Date().timeIntervalSince(startedAt),
                    stderr: nil,
                    status: .completed,
                    outputDirectory: bundleURL
                )

                if globalOptions.outputFormat == .json {
                    let handler = JSONOutputHandler()
                    handler.writeData([
                        "bundle": bundlePath,
                        "provenance": bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename).path,
                        "sampleRowsUpdated": "\(totalUpdated)",
                        "tracksUpdated": "\(updatedTracks)",
                        "status": "ok",
                    ], label: nil)
                    return
                }

                if !globalOptions.quiet {
                    print(formatter.success(
                        "Imported sample metadata into \(updatedTracks) variant track(s); updated \(totalUpdated) sample row(s)."
                    ))
                }
            } catch {
                do {
                    try restoreSampleMetadataRollbackSnapshot(rollbackSnapshot)
                } catch let rollbackError {
                    throw SampleMetadataRollbackFailure(
                        operationError: error,
                        rollbackError: rollbackError
                    )
                }
                throw error
            }
        }

        private func sampleMetadataInputRecords(
            inputURL: URL,
            metadataFormat: MetadataFormat,
            manifestURL: URL,
            databaseURLs: [URL]
        ) -> [FileRecord] {
            [
                ProvenanceRecorder.fileRecord(
                    url: inputURL,
                    format: fileFormat(forMetadataFormat: metadataFormat),
                    role: .input
                ),
                ProvenanceRecorder.fileRecord(url: manifestURL, format: .json, role: .input)
            ] + databaseURLs.map {
                ProvenanceRecorder.fileRecord(url: $0, format: .unknown, role: .input)
            }
        }

        private func sampleMetadataOutputRecords(databaseURLs: [URL]) -> [FileRecord] {
            databaseURLs.map {
                ProvenanceRecorder.fileRecord(url: $0, format: .unknown, role: .output)
            }
        }

        private func sampleMetadataProvenanceCommand(inputURL: URL, bundleURL: URL) -> [String] {
            [
                "lungfish",
                "import",
                "sample-metadata",
                inputURL.path,
                "--bundle",
                bundleURL.path
            ] + replayableGlobalArguments()
        }

        private func sampleMetadataProvenanceParameters(
            inputURL: URL,
            bundleURL: URL,
            metadataFormat: MetadataFormat
        ) -> [String: ParameterValue] {
            var parameters: [String: ParameterValue] = [
                "inputFile": .file(inputURL),
                "bundle": .file(bundleURL),
                "metadataFormat": .string(metadataFormat.rawValue)
            ]
            parameters.merge(globalExplicitOptions()) { _, explicit in explicit }
            return parameters
        }

        private func sampleMetadataProvenanceDefaults() -> [String: ParameterValue] {
            [
                "metadataFormat": .string("inferred-from-extension"),
                "outputFormat": .string(OutputFormat.text.rawValue),
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

        private func sampleMetadataProvenanceResolved(
            inputURL: URL,
            bundleURL: URL,
            metadataFormat: MetadataFormat,
            updatedTracks: Int,
            sampleRowsUpdated: Int,
            databaseURLs: [URL]
        ) -> [String: ParameterValue] {
            [
                "inputFile": .file(inputURL),
                "bundle": .file(bundleURL),
                "metadataFormat": .string(metadataFormat.rawValue),
                "outputFormat": .string(globalOptions.outputFormat.rawValue),
                "quiet": .boolean(globalOptions.quiet),
                "verbosity": .integer(globalOptions.verbosity),
                "progress": .boolean(globalOptions.showProgress),
                "noProgress": .boolean(globalOptions.noProgress),
                "debug": .boolean(globalOptions.debug),
                "logFile": globalOptions.logFile.map { .file(URL(fileURLWithPath: $0)) } ?? .null,
                "noColor": .boolean(globalOptions.noColor),
                "threads": globalOptions.threads.map(ParameterValue.integer) ?? .integer(globalOptions.effectiveThreads),
                "useColors": .boolean(globalOptions.useColors),
                "shouldShowProgress": .boolean(globalOptions.shouldShowProgress),
                "tracksUpdated": .integer(updatedTracks),
                "sampleRowsUpdated": .integer(sampleRowsUpdated),
                "variantDatabaseCount": .integer(databaseURLs.count),
                "variantDatabases": .array(databaseURLs.map { .file($0) })
            ]
        }

        private func fileFormat(forMetadataFormat format: MetadataFormat) -> FileFormat {
            switch format {
            case .csv, .tsv:
                return .text
            case .excel:
                return .unknown
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

        private func globalExplicitOptions() -> [String: ParameterValue] {
            var explicit: [String: ParameterValue] = [:]
            if globalOptions.outputFormat != .text {
                explicit["outputFormat"] = .string(globalOptions.outputFormat.rawValue)
            }
            if globalOptions.verbosity > 0 {
                explicit["verbosity"] = .integer(globalOptions.verbosity)
            }
            if globalOptions.quiet {
                explicit["quiet"] = .boolean(true)
            }
            if globalOptions.showProgress {
                explicit["progress"] = .boolean(true)
            }
            if globalOptions.noProgress {
                explicit["noProgress"] = .boolean(true)
            }
            if globalOptions.debug {
                explicit["debug"] = .boolean(true)
            }
            if let logFile = globalOptions.logFile {
                explicit["logFile"] = .file(URL(fileURLWithPath: logFile))
            }
            if globalOptions.noColor {
                explicit["noColor"] = .boolean(true)
            }
            if let threads = globalOptions.threads {
                explicit["threads"] = .integer(threads)
            }
            return explicit
        }

        private struct RollbackSnapshot {
            let backupDirectory: URL
            let artifacts: [ArtifactSnapshot]
        }

        private struct ArtifactSnapshot {
            let originalURL: URL
            let backupURL: URL?
        }

        private struct SampleMetadataRollbackFailure: LocalizedError {
            let operationError: Error
            let rollbackError: Error

            var errorDescription: String? {
                """
                Sample metadata import failed and rollback also failed. Original error: \(operationError.localizedDescription). Rollback error: \(rollbackError.localizedDescription)
                """
            }
        }

        private func createSampleMetadataRollbackSnapshot(
            bundleURL: URL,
            databaseURLs: [URL]
        ) throws -> RollbackSnapshot {
            let fileManager = FileManager.default
            let backupDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("lungfish-sample-metadata-rollback-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

            let artifacts = try rollbackArtifactURLs(bundleURL: bundleURL, databaseURLs: databaseURLs)
                .enumerated()
                .map { index, originalURL -> ArtifactSnapshot in
                    let standardizedURL = originalURL.standardizedFileURL
                    var isDirectory: ObjCBool = false
                    guard fileManager.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory) else {
                        return ArtifactSnapshot(originalURL: standardizedURL, backupURL: nil)
                    }

                    let backupURL = backupDirectory.appendingPathComponent("artifact-\(index)")
                    try fileManager.copyItem(at: standardizedURL, to: backupURL)
                    return ArtifactSnapshot(originalURL: standardizedURL, backupURL: backupURL)
                }

            return RollbackSnapshot(backupDirectory: backupDirectory, artifacts: artifacts)
        }

        private func restoreSampleMetadataRollbackSnapshot(_ snapshot: RollbackSnapshot) throws {
            let fileManager = FileManager.default
            for artifact in snapshot.artifacts.reversed() {
                if fileManager.fileExists(atPath: artifact.originalURL.path) {
                    try fileManager.removeItem(at: artifact.originalURL)
                }
                guard let backupURL = artifact.backupURL else { continue }
                try fileManager.createDirectory(
                    at: artifact.originalURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: backupURL, to: artifact.originalURL)
            }
        }

        private func removeRollbackBackup(_ snapshot: RollbackSnapshot) {
            try? FileManager.default.removeItem(at: snapshot.backupDirectory)
        }

        private func rollbackArtifactURLs(bundleURL: URL, databaseURLs: [URL]) -> [URL] {
            var urls: [URL] = []
            var seen = Set<String>()
            func append(_ url: URL) {
                let standardizedURL = url.standardizedFileURL
                guard seen.insert(standardizedURL.path).inserted else { return }
                urls.append(standardizedURL)
            }
            func appendProvenanceSidecar(_ sidecarURL: URL) {
                append(sidecarURL)
                append(ProvenanceSigningConfiguration.signatureURL(for: sidecarURL))
                append(ProvenanceSigningConfiguration.publicKeyURL(for: sidecarURL))
            }

            appendProvenanceSidecar(bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename))
            append(bundleURL.appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true))

            for databaseURL in databaseURLs {
                for sqliteArtifact in sqliteArtifactURLs(for: databaseURL) {
                    append(sqliteArtifact)
                }
                appendProvenanceSidecar(ProvenanceRecorder.fileSidecarURL(for: databaseURL))
            }
            return urls
        }

        private func sqliteArtifactURLs(for databaseURL: URL) -> [URL] {
            [
                databaseURL,
                URL(fileURLWithPath: databaseURL.path + "-wal"),
                URL(fileURLWithPath: databaseURL.path + "-shm"),
                URL(fileURLWithPath: databaseURL.path + "-journal")
            ]
        }
    }

    /// Import a BAM/CRAM alignment file into a Lungfish project.
    ///
    /// Validates that the alignment file exists, copies it to the output
    /// directory, creates an index if needed, and prints alignment statistics.
    struct BAMSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "bam",
            abstract: "Import a BAM or CRAM alignment file"
        )

        @Argument(help: "Path to the BAM or CRAM file")
        var inputFile: String

        @Option(
            name: [.customLong("output-dir"), .customShort("o")],
            help: "Output project directory (default: current directory)"
        )
        var outputDir: String?

        @Option(
            name: .customLong("name"),
            help: "Display name for the alignment track (default: filename)"
        )
        var name: String?

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let startedAt = Date()
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let inputURL = URL(fileURLWithPath: inputFile)

            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                print(formatter.error("Input file not found: \(inputFile)"))
                throw CLIExitCode.inputError.exitCode
            }

            // Validate format from extension.
            var formatURL = inputURL
            if formatURL.pathExtension.lowercased() == "gz" {
                formatURL = formatURL.deletingPathExtension()
            }
            let ext = formatURL.pathExtension.lowercased()
            guard ["bam", "cram", "sam"].contains(ext) else {
                print(formatter.error("Unsupported alignment format: .\(ext). Expected .bam, .cram, or .sam"))
                throw CLIExitCode.formatError.exitCode
            }

            let outputDirectory = resolveOutputDirectory(outputDir)

            print(formatter.header("BAM/CRAM Import"))
            print("")
            print(formatter.keyValueTable([
                ("Input", inputURL.lastPathComponent),
                ("Format", ext.uppercased()),
                ("Output", outputDirectory.path),
            ]))
            print("")

            // Create output directory.
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )

            let alignmentFormat = alignmentFileFormat(forExtension: ext)
            var createdArtifacts: [URL] = []
            do {
                // Copy alignment file.
                let destURL = outputDirectory.appendingPathComponent(inputURL.lastPathComponent)
                if try copyImportArtifactIfNeeded(from: inputURL, to: destURL) {
                    createdArtifacts.append(destURL)
                    if !globalOptions.quiet {
                        print(formatter.info("Copied alignment file"))
                    }
                }

                // Check for companion index file and copy if present.
                var indexArtifact = try copyCompanionIndex(
                    for: inputURL,
                    to: outputDirectory,
                    formatter: formatter,
                    createdArtifacts: &createdArtifacts
                )

                // Attempt to collect statistics via samtools.
                var totalReads: Int64 = 0
                var mappedReads: Int64 = 0
                var unmappedReads: Int64 = 0
                var refContigs = 0
                var statsCollected = false
                var provenanceMessages: [String] = []
                var provenanceSteps: [ProvenanceStep] = []
                let samtoolsVersion = await detectNativeToolVersion(.samtools)

                do {
                    let runner = NativeToolRunner.shared
                    let idxstatsStartedAt = Date()
                    let idxstatsResult = try await runner.run(
                        .samtools,
                        arguments: ["idxstats", destURL.path],
                        timeout: 120
                    )
                    let idxstatsCompletedAt = Date()
                    provenanceSteps.append(try nativeToolProvenanceStep(
                        toolName: "samtools",
                        toolVersion: samtoolsVersion,
                        result: idxstatsResult,
                        fallbackArgv: ["samtools", "idxstats", destURL.path],
                        inputs: [
                            ProvenanceFileDescriptor.file(url: destURL, format: alignmentFormat, role: .input)
                        ],
                        outputs: [],
                        startedAt: idxstatsStartedAt,
                        completedAt: idxstatsCompletedAt
                    ))
                    if idxstatsResult.isSuccess {
                        let lines = idxstatsResult.stdout.split(separator: "\n")
                        for line in lines {
                            let cols = line.split(separator: "\t")
                            guard cols.count >= 4 else { continue }
                            let refName = String(cols[0])
                            let mapped = Int64(cols[2]) ?? 0
                            let unmapped = Int64(cols[3]) ?? 0
                            mappedReads += mapped
                            unmappedReads += unmapped
                            if refName != "*" {
                                refContigs += 1
                            }
                        }
                        totalReads = mappedReads + unmappedReads
                        statsCollected = true
                    } else {
                        provenanceMessages.append(
                            "samtools idxstats exited \(idxstatsResult.exitCode): \(idxstatsResult.stderr)"
                        )
                    }
                    if !idxstatsResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        provenanceMessages.append("samtools idxstats stderr: \(idxstatsResult.stderr)")
                    }
                } catch {
                    // samtools not available - skip stats.
                    provenanceMessages.append("samtools idxstats unavailable: \(error.localizedDescription)")
                    if !globalOptions.quiet {
                        print(formatter.warning("samtools not available; skipping statistics collection"))
                    }
                }

                // If no source index was copied and a destination index is already present,
                // do not claim that stale index as an output of this import.
                if indexArtifact == nil, let existingIndexURL = existingAlignmentIndex(for: destURL) {
                    throw ImportArtifactConflictError(sourceURL: inputURL, destinationURL: existingIndexURL)
                }

                // If no index was copied and samtools is available, try creating one.
                if indexArtifact == nil {
                    do {
                        let runner = NativeToolRunner.shared
                        if !globalOptions.quiet {
                            print(formatter.info("Creating index..."))
                        }
                        let indexStartedAt = Date()
                        let indexResult = try await runner.run(
                            .samtools,
                            arguments: ["index", destURL.path],
                            timeout: 3600
                        )
                        let indexCompletedAt = Date()
                        var indexStepOutputs: [ProvenanceFileDescriptor] = []
                        if indexResult.isSuccess {
                            if let generatedIndexURL = existingAlignmentIndex(for: destURL) {
                                indexArtifact = (sourceURL: nil, destinationURL: generatedIndexURL)
                                createdArtifacts.append(generatedIndexURL)
                                indexStepOutputs = [
                                    try ProvenanceFileDescriptor.file(
                                        url: generatedIndexURL,
                                        format: .unknown,
                                        role: .index
                                    )
                                ]
                            }
                            if !globalOptions.quiet {
                                print(formatter.success("Index created"))
                            }
                        } else {
                            provenanceMessages.append(
                                "samtools index exited \(indexResult.exitCode): \(indexResult.stderr)"
                            )
                            print(formatter.warning(
                                "Failed to create index. The file may need sorting first."
                            ))
                        }
                        provenanceSteps.append(try nativeToolProvenanceStep(
                            toolName: "samtools",
                            toolVersion: samtoolsVersion,
                            result: indexResult,
                            fallbackArgv: ["samtools", "index", destURL.path],
                            inputs: [
                                ProvenanceFileDescriptor.file(url: destURL, format: alignmentFormat, role: .input)
                            ],
                            outputs: indexStepOutputs,
                            startedAt: indexStartedAt,
                            completedAt: indexCompletedAt
                        ))
                        if !indexResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            provenanceMessages.append("samtools index stderr: \(indexResult.stderr)")
                        }
                    } catch {
                        provenanceMessages.append("samtools index unavailable: \(error.localizedDescription)")
                        print(formatter.warning("samtools not available; could not create index"))
                    }
                }

                let inputRecords = bamInputRecords(inputURL: inputURL, format: alignmentFormat, indexArtifact: indexArtifact)
                let outputRecords = bamOutputRecords(destURL: destURL, format: alignmentFormat, indexArtifact: indexArtifact)
                try await CLIProvenanceSupport.recordSingleStepRun(
                    name: "lungfish import bam",
                    parameters: bamProvenanceParameters(inputURL: inputURL),
                    defaults: bamProvenanceDefaults(),
                    resolved: bamProvenanceResolved(
                        outputURL: destURL,
                        format: ext,
                        indexArtifact: indexArtifact,
                        statsCollected: statsCollected,
                        totalReads: totalReads,
                        mappedReads: mappedReads,
                        unmappedReads: unmappedReads,
                        refContigs: refContigs
                    ),
                    toolName: "lungfish import bam",
                    toolVersion: "lungfish-cli \(LungfishCLI.configuration.version)",
                    command: bamProvenanceCommand(inputURL: inputURL, outputDirectory: outputDirectory),
                    extraSteps: provenanceSteps,
                    inputs: inputRecords,
                    outputs: outputRecords,
                    exitCode: 0,
                    wallTime: Date().timeIntervalSince(startedAt),
                    stderr: provenanceMessages.isEmpty ? nil : provenanceMessages.joined(separator: "\n"),
                    status: .completed,
                    outputDirectory: outputDirectory
                )

                print("")
                print(formatter.header("Summary"))
                print("")

                if statsCollected {
                    let mappedPct = totalReads > 0
                        ? String(format: "%.2f%%", Double(mappedReads) / Double(totalReads) * 100)
                        : "N/A"
                    print(formatter.keyValueTable([
                        ("Total reads", formatNumber(totalReads)),
                        ("Mapped reads", "\(formatNumber(mappedReads)) (\(mappedPct))"),
                        ("Unmapped reads", formatNumber(unmappedReads)),
                        ("Reference contigs", String(refContigs)),
                    ]))
                } else {
                    print(formatter.keyValueTable([
                        ("File", destURL.lastPathComponent),
                        ("Index", indexArtifact == nil ? "not found" : "found"),
                    ]))
                }

                print("")
                print(formatter.success("BAM import complete: \(destURL.lastPathComponent)"))
            } catch {
                removeCreatedImportArtifacts(createdArtifacts)
                throw error
            }
        }

        /// Copies a companion index file (.bai, .csi, .crai) if one exists next to the input.
        private func copyCompanionIndex(
            for inputURL: URL,
            to outputDirectory: URL,
            formatter: TerminalFormatter,
            createdArtifacts: inout [URL]
        ) throws -> (sourceURL: URL?, destinationURL: URL)? {
            let fm = FileManager.default
            let basePath = inputURL.path

            // Common index file patterns.
            let candidates = [
                basePath + ".bai",
                basePath + ".csi",
                basePath + ".crai",
                inputURL.deletingPathExtension().path + ".bai",
            ]

            for candidatePath in candidates {
                if fm.fileExists(atPath: candidatePath) {
                    let indexURL = URL(fileURLWithPath: candidatePath)
                    let destIndex = outputDirectory.appendingPathComponent(indexURL.lastPathComponent)
                    if try copyImportArtifactIfNeeded(from: indexURL, to: destIndex) {
                        createdArtifacts.append(destIndex)
                        if !globalOptions.quiet {
                            print(formatter.info("Copied index: \(indexURL.lastPathComponent)"))
                        }
                    }
                    return (sourceURL: indexURL, destinationURL: destIndex)
                }
            }
            return nil
        }

        private func existingAlignmentIndex(for alignmentURL: URL) -> URL? {
            let candidates = [
                alignmentURL.path + ".bai",
                alignmentURL.path + ".csi",
                alignmentURL.path + ".crai",
                alignmentURL.deletingPathExtension().path + ".bai",
            ]
            return candidates
                .map(URL.init(fileURLWithPath:))
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }

        private func bamInputRecords(
            inputURL: URL,
            format: FileFormat,
            indexArtifact: (sourceURL: URL?, destinationURL: URL)?
        ) -> [FileRecord] {
            var records = [
                ProvenanceRecorder.fileRecord(url: inputURL, format: format, role: .input)
            ]
            if let sourceURL = indexArtifact?.sourceURL {
                records.append(ProvenanceRecorder.fileRecord(url: sourceURL, format: .unknown, role: .index))
            }
            return records
        }

        private func bamOutputRecords(
            destURL: URL,
            format: FileFormat,
            indexArtifact: (sourceURL: URL?, destinationURL: URL)?
        ) -> [FileRecord] {
            var records = [
                ProvenanceRecorder.fileRecord(url: destURL, format: format, role: .output)
            ]
            if let indexURL = indexArtifact?.destinationURL {
                records.append(ProvenanceRecorder.fileRecord(url: indexURL, format: .unknown, role: .index))
            }
            return records
        }

        private func bamProvenanceCommand(inputURL: URL, outputDirectory: URL) -> [String] {
            var command = ["lungfish", "import", "bam", inputURL.path, "--output-dir", outputDirectory.path]
            if let name {
                command += ["--name", name]
            }
            if globalOptions.quiet {
                command.append("--quiet")
            }
            if globalOptions.noColor {
                command.append("--no-color")
            }
            return command
        }

        private func bamProvenanceParameters(
            inputURL: URL
        ) -> [String: ParameterValue] {
            [
                "inputFile": .string(inputURL.path),
                "outputDir": outputDir.map(ParameterValue.string) ?? .null,
                "name": name.map(ParameterValue.string) ?? .null,
                "quiet": .boolean(globalOptions.quiet),
                "noColor": .boolean(globalOptions.noColor)
            ]
        }

        private func bamProvenanceDefaults() -> [String: ParameterValue] {
            [
                "outputDir": .string(FileManager.default.currentDirectoryPath),
                "name": .null,
                "quiet": .boolean(false),
                "noColor": .boolean(false)
            ]
        }

        private func bamProvenanceResolved(
            outputURL: URL,
            format: String,
            indexArtifact: (sourceURL: URL?, destinationURL: URL)?,
            statsCollected: Bool,
            totalReads: Int64,
            mappedReads: Int64,
            unmappedReads: Int64,
            refContigs: Int
        ) -> [String: ParameterValue] {
            [
                "outputFile": .string(outputURL.path),
                "outputDirectory": .string(outputURL.deletingLastPathComponent().path),
                "format": .string(format),
                "indexFile": indexArtifact.map { .string($0.destinationURL.path) } ?? .null,
                "indexSource": indexArtifact?.sourceURL.map { .string($0.path) } ?? .null,
                "statsCollected": .boolean(statsCollected),
                "totalReads": .integer(Int(totalReads)),
                "mappedReads": .integer(Int(mappedReads)),
                "unmappedReads": .integer(Int(unmappedReads)),
                "referenceContigs": .integer(refContigs)
            ]
        }

        private func alignmentFileFormat(forExtension ext: String) -> FileFormat {
            switch ext {
            case "bam": return .bam
            case "cram": return .cram
            case "sam": return .sam
            default: return .unknown
            }
        }
    }
}

// MARK: - VCF Import

extension ImportCommand {

    /// Import a VCF variant file into a Lungfish project.
    ///
    /// Validates the VCF header, counts variants, and copies the file
    /// (and companion index) to the output directory.
    struct VCFSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "vcf",
            abstract: "Import a VCF variant file"
        )

        @Argument(help: "Path to the VCF or VCF.GZ file")
        var inputFile: String

        @Option(
            name: [.customLong("output-dir"), .customShort("o")],
            help: "Output project directory (default: current directory)"
        )
        var outputDir: String?

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let startedAt = Date()
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let inputURL = URL(fileURLWithPath: inputFile)

            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                print(formatter.error("Input file not found: \(inputFile)"))
                throw CLIExitCode.inputError.exitCode
            }

            // Validate format from extension.
            var formatURL = inputURL
            if formatURL.pathExtension.lowercased() == "gz" {
                formatURL = formatURL.deletingPathExtension()
            }
            let ext = formatURL.pathExtension.lowercased()
            guard ["vcf", "bcf"].contains(ext) else {
                print(formatter.error("Unsupported variant format: .\(ext). Expected .vcf, .vcf.gz, or .bcf"))
                throw CLIExitCode.formatError.exitCode
            }

            let outputDirectory = resolveOutputDirectory(outputDir)

            print(formatter.header("VCF Import"))
            print("")

            // Parse and summarize the VCF.
            if !globalOptions.quiet {
                print(formatter.info("Reading VCF header and variants..."))
            }

            let reader = VCFReader(validateRecords: false, parseGenotypes: false)
            let summary: VCFSummary
            do {
                summary = try await reader.summarize(from: inputURL)
            } catch {
                print(formatter.error("Failed to parse VCF: \(error.localizedDescription)"))
                throw CLIExitCode.formatError.exitCode
            }

            // Create output directory and copy file.
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            var createdArtifacts: [URL] = []
            do {
                let destURL = outputDirectory.appendingPathComponent(inputURL.lastPathComponent)
                if try copyImportArtifactIfNeeded(from: inputURL, to: destURL) {
                    createdArtifacts.append(destURL)
                }

                // Copy companion index (.tbi, .csi) if present.
                let indexArtifact = try copyVCFIndex(
                    for: inputURL,
                    to: outputDirectory,
                    formatter: formatter,
                    createdArtifacts: &createdArtifacts
                )

                let variantFormat = variantFileFormat(forExtension: ext)
                try await CLIProvenanceSupport.recordSingleStepRun(
                    name: "lungfish import vcf",
                    parameters: vcfProvenanceParameters(inputURL: inputURL),
                    defaults: vcfProvenanceDefaults(),
                    resolved: vcfProvenanceResolved(
                        outputURL: destURL,
                        format: ext,
                        indexArtifact: indexArtifact,
                        summary: summary
                    ),
                    toolName: "lungfish import vcf",
                    toolVersion: "lungfish-cli \(LungfishCLI.configuration.version)",
                    command: vcfProvenanceCommand(inputURL: inputURL, outputDirectory: outputDirectory),
                    inputs: vcfInputRecords(inputURL: inputURL, format: variantFormat, indexArtifact: indexArtifact),
                    outputs: vcfOutputRecords(destURL: destURL, format: variantFormat, indexArtifact: indexArtifact),
                    exitCode: 0,
                    wallTime: Date().timeIntervalSince(startedAt),
                    stderr: nil,
                    status: .completed,
                    outputDirectory: outputDirectory
                )

                print("")
                print(formatter.header("Summary"))
                print("")

                // Format variant type breakdown.
                let typeBreakdown = summary.variantTypes
                    .sorted { $0.value > $1.value }
                    .map { "\($0.key): \(formatNumber(Int64($0.value)))" }
                    .joined(separator: ", ")

                print(formatter.keyValueTable([
                    ("Format", summary.header.fileFormat),
                    ("Variants", formatNumber(Int64(summary.variantCount))),
                    ("Types", typeBreakdown.isEmpty ? "N/A" : typeBreakdown),
                    ("Samples", String(summary.header.sampleNames.count)),
                    ("Contigs", String(summary.chromosomes.count)),
                ]))

                if !summary.header.sampleNames.isEmpty {
                    let sampleList = summary.header.sampleNames.prefix(10)
                        .joined(separator: ", ")
                    let suffix = summary.header.sampleNames.count > 10
                        ? " (+\(summary.header.sampleNames.count - 10) more)" : ""
                    print("")
                    print("  Samples: \(sampleList)\(suffix)")
                }

                print("")
                print(formatter.success("VCF import complete: \(destURL.lastPathComponent)"))
            } catch {
                removeCreatedImportArtifacts(createdArtifacts)
                throw error
            }
        }

        /// Copies a companion index file (.tbi, .csi) if one exists next to the input.
        private func copyVCFIndex(
            for inputURL: URL,
            to outputDirectory: URL,
            formatter: TerminalFormatter,
            createdArtifacts: inout [URL]
        ) throws -> (sourceURL: URL, destinationURL: URL)? {
            let fm = FileManager.default
            let candidates = [
                inputURL.path + ".tbi",
                inputURL.path + ".csi",
            ]

            for candidatePath in candidates {
                if fm.fileExists(atPath: candidatePath) {
                    let indexURL = URL(fileURLWithPath: candidatePath)
                    let destIndex = outputDirectory.appendingPathComponent(indexURL.lastPathComponent)
                    if try copyImportArtifactIfNeeded(from: indexURL, to: destIndex) {
                        createdArtifacts.append(destIndex)
                        if !globalOptions.quiet {
                            print(formatter.info("Copied index: \(indexURL.lastPathComponent)"))
                        }
                    }
                    return (sourceURL: indexURL, destinationURL: destIndex)
                }
            }
            return nil
        }

        private func vcfInputRecords(
            inputURL: URL,
            format: FileFormat,
            indexArtifact: (sourceURL: URL, destinationURL: URL)?
        ) -> [FileRecord] {
            var records = [
                ProvenanceRecorder.fileRecord(url: inputURL, format: format, role: .input)
            ]
            if let indexURL = indexArtifact?.sourceURL {
                records.append(ProvenanceRecorder.fileRecord(url: indexURL, format: .unknown, role: .index))
            }
            return records
        }

        private func vcfOutputRecords(
            destURL: URL,
            format: FileFormat,
            indexArtifact: (sourceURL: URL, destinationURL: URL)?
        ) -> [FileRecord] {
            var records = [
                ProvenanceRecorder.fileRecord(url: destURL, format: format, role: .output)
            ]
            if let indexURL = indexArtifact?.destinationURL {
                records.append(ProvenanceRecorder.fileRecord(url: indexURL, format: .unknown, role: .index))
            }
            return records
        }

        private func vcfProvenanceCommand(inputURL: URL, outputDirectory: URL) -> [String] {
            var command = ["lungfish", "import", "vcf", inputURL.path, "--output-dir", outputDirectory.path]
            if globalOptions.quiet {
                command.append("--quiet")
            }
            if globalOptions.noColor {
                command.append("--no-color")
            }
            return command
        }

        private func vcfProvenanceParameters(
            inputURL: URL
        ) -> [String: ParameterValue] {
            [
                "inputFile": .string(inputURL.path),
                "outputDir": outputDir.map(ParameterValue.string) ?? .null,
                "quiet": .boolean(globalOptions.quiet),
                "noColor": .boolean(globalOptions.noColor)
            ]
        }

        private func vcfProvenanceDefaults() -> [String: ParameterValue] {
            [
                "outputDir": .string(FileManager.default.currentDirectoryPath),
                "quiet": .boolean(false),
                "noColor": .boolean(false)
            ]
        }

        private func vcfProvenanceResolved(
            outputURL: URL,
            format: String,
            indexArtifact: (sourceURL: URL, destinationURL: URL)?,
            summary: VCFSummary
        ) -> [String: ParameterValue] {
            [
                "outputFile": .string(outputURL.path),
                "outputDirectory": .string(outputURL.deletingLastPathComponent().path),
                "format": .string(format),
                "indexFile": indexArtifact.map { .string($0.destinationURL.path) } ?? .null,
                "indexSource": indexArtifact.map { .string($0.sourceURL.path) } ?? .null,
                "vcfHeaderFormat": .string(summary.header.fileFormat),
                "variantCount": .integer(summary.variantCount),
                "sampleCount": .integer(summary.header.sampleNames.count),
                "contigCount": .integer(summary.chromosomes.count)
            ]
        }

        private func variantFileFormat(forExtension ext: String) -> FileFormat {
            switch ext {
            case "vcf": return .vcf
            case "bcf": return .bcf
            default: return .unknown
            }
        }
    }
}

// MARK: - FASTA Import

extension ImportCommand {

    /// Import a standalone reference sequence file into a Lungfish project.
    ///
    /// Accepts FASTA/GenBank/EMBL (plain or compressed), then builds a canonical
    /// `.lungfishref` bundle in the project's "Reference Sequences" folder.
    struct FASTASubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "fasta",
            abstract: "Import a standalone reference sequence file as a .lungfishref bundle"
        )

        @Argument(help: "Path to the input reference (.fa/.fasta/.gb/.embl, optionally .gz/.bgz/.bz2/.xz/.zst)")
        var inputFile: String

        @Option(
            name: [.customLong("output-dir"), .customShort("o")],
            help: "Output project directory (default: current directory)"
        )
        var outputDir: String?

        @Option(
            name: .customLong("name"),
            help: "Display name for the reference (default: filename)"
        )
        var name: String?

        @OptionGroup var globalOptions: GlobalOptions

        private static let compressionExtensions: Set<String> = ["gz", "gzip", "bgz", "bz2", "xz", "zst", "zstd"]
        private static let fastaExtensions: Set<String> = ["fa", "fasta", "fna", "fsa", "fas", "faa", "ffn", "frn"]
        private static let genbankExtensions: Set<String> = ["gb", "gbk", "genbank", "gbff", "embl"]

        private struct BuildInputs {
            let fastaURL: URL
            let annotationInputs: [AnnotationInput]
            let organism: String
            let sequenceNames: [String]
            let sequenceCount: Int
            let totalLength: Int64
        }

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let inputURL = URL(fileURLWithPath: inputFile)

            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                print(formatter.error("Input file not found: \(inputFile)"))
                throw CLIExitCode.inputError.exitCode
            }

            let ext = normalizedExtension(for: inputURL)
            guard Self.fastaExtensions.contains(ext) || Self.genbankExtensions.contains(ext) else {
                print(formatter.error("Unsupported reference format: .\(ext)"))
                throw CLIExitCode.formatError.exitCode
            }

            let outputDirectory = resolveOutputDirectory(outputDir)
            let refsDirectory = try ReferenceSequenceFolder.ensureFolder(in: outputDirectory)
            try FileManager.default.createDirectory(at: refsDirectory, withIntermediateDirectories: true)

            print(formatter.header("Reference Import"))
            print("")

            if !globalOptions.quiet {
                print(formatter.info("Preparing reference input..."))
            }

            let tempDirectory = try ProjectTempDirectory.createFromContext(
                prefix: "lungfish-cli-ref-import-",
                contextURL: outputDirectory
            )
            defer { try? FileManager.default.removeItem(at: tempDirectory) }

            let buildInputs = try await prepareBuildInputs(
                sourceURL: inputURL,
                extensionHint: ext,
                tempDirectory: tempDirectory
            )

            let displayName = resolvedBundleName(explicitName: name, sourceURL: inputURL)
            let bundleName = makeUniqueBundleName(base: displayName, in: refsDirectory)

            if !globalOptions.quiet {
                print(formatter.info("Building .lungfishref bundle..."))
            }

            let sourceInfo = SourceInfo(
                organism: buildInputs.organism.isEmpty ? bundleName : buildInputs.organism,
                assembly: bundleName,
                database: "Imported File",
                sourceURL: inputURL,
                downloadDate: Date(),
                notes: "Imported from \(inputURL.lastPathComponent)"
            )

            let configuration = BuildConfiguration(
                name: bundleName,
                identifier: "org.lungfish.cli.import.\(UUID().uuidString.lowercased())",
                fastaURL: buildInputs.fastaURL,
                annotationFiles: buildInputs.annotationInputs,
                outputDirectory: refsDirectory,
                source: sourceInfo,
                compressFASTA: true,
                provenanceWorkflowName: "lungfish import fasta",
                provenanceCommand: provenanceCommand(
                    sourceURL: inputURL,
                    outputDirectory: outputDirectory,
                    bundleName: bundleName
                ),
                provenanceInputFiles: [inputURL]
            )

            let bundleURL = try await NativeBundleBuilder().build(configuration: configuration)

            print("")
            print(formatter.header("Summary"))
            print("")
            print(formatter.keyValueTable([
                ("Name", bundleName),
                ("Sequences", String(buildInputs.sequenceCount)),
                ("Total length", formatBases(buildInputs.totalLength)),
                ("Bundle", bundleURL.lastPathComponent),
            ]))

            if !buildInputs.sequenceNames.isEmpty {
                let displayNames = buildInputs.sequenceNames.prefix(10)
                    .joined(separator: ", ")
                let suffix = buildInputs.sequenceNames.count > 10
                    ? " (+\(buildInputs.sequenceNames.count - 10) more)" : ""
                print("")
                print("  Sequences: \(displayNames)\(suffix)")
            }

            print("")
            print(formatter.success(
                "Reference import complete: \(bundleName) (\(buildInputs.sequenceCount) sequences, \(formatBases(buildInputs.totalLength)))"
            ))
        }

        private func normalizedExtension(for url: URL) -> String {
            var ext = url.pathExtension.lowercased()
            if Self.compressionExtensions.contains(ext) {
                ext = url.deletingPathExtension().pathExtension.lowercased()
            }
            return ext
        }

        private func resolvedBundleName(explicitName: String?, sourceURL: URL) -> String {
            let rawName: String
            if let explicitName {
                rawName = explicitName
            } else {
                var stripped = sourceURL
                while !stripped.pathExtension.isEmpty {
                    stripped = stripped.deletingPathExtension()
                }
                rawName = stripped.lastPathComponent
            }

            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = trimmed.isEmpty ? "Imported Reference" : trimmed
            return fallback
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
        }

        private func makeUniqueBundleName(base: String, in directory: URL) -> String {
            let fm = FileManager.default
            var candidate = base
            var counter = 2

            while fm.fileExists(atPath: bundleURL(for: candidate, in: directory).path) {
                candidate = "\(base) \(counter)"
                counter += 1
            }

            return candidate
        }

        private func bundleURL(for bundleName: String, in directory: URL) -> URL {
            let safe = bundleName
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "/", with: "-")
            return directory.appendingPathComponent("\(safe).lungfishref", isDirectory: true)
        }

        private func provenanceCommand(
            sourceURL: URL,
            outputDirectory: URL,
            bundleName: String
        ) -> [String] {
            var command = [
                "lungfish",
                "import",
                "fasta",
                sourceURL.path,
                "--output-dir",
                outputDirectory.path,
                "--name",
                bundleName,
            ]
            if globalOptions.quiet {
                command.append("--quiet")
            }
            return command
        }

        private func prepareBuildInputs(
            sourceURL: URL,
            extensionHint: String,
            tempDirectory: URL
        ) async throws -> BuildInputs {
            let inputURL: URL
            if Self.compressionExtensions.contains(sourceURL.pathExtension.lowercased()) {
                let decompressedName = extensionHint.isEmpty
                    ? "decompressed-input"
                    : "decompressed-input.\(extensionHint)"
                let decompressed = tempDirectory.appendingPathComponent(decompressedName)
                try decompressInput(sourceURL: sourceURL, outputURL: decompressed)
                inputURL = decompressed
            } else {
                inputURL = sourceURL
            }

            if Self.genbankExtensions.contains(extensionHint) {
                let reader = try GenBankReader(url: inputURL)
                let records = try await reader.readAll()
                guard !records.isEmpty else {
                    throw CLIError.validationFailed(errors: ["No sequences found in \(sourceURL.lastPathComponent)"])
                }

                let sequences = records.map(\.sequence)
                guard !sequences.isEmpty else {
                    throw CLIError.validationFailed(errors: ["No sequences found in \(sourceURL.lastPathComponent)"])
                }

                let fastaOutput = tempDirectory.appendingPathComponent("input.fa")
                try FASTAWriter(url: fastaOutput).write(sequences)

                let sequenceNames = sequences.map(\.name)
                let totalLength = sequences.reduce(Int64(0)) { partial, sequence in
                    partial + Int64(sequence.length)
                }

                let hasAnnotations = records.contains { !$0.annotations.isEmpty }
                let annotationInputs: [AnnotationInput] = hasAnnotations ? [
                    AnnotationInput(
                        url: inputURL,
                        name: "Imported Annotations",
                        description: "Converted from \(sourceURL.lastPathComponent)",
                        id: "imported_annotations",
                        annotationType: .gene
                    ),
                ] : []

                let organism = records.first?.definition
                    ?? records.first?.sequence.description
                    ?? sourceURL.deletingPathExtension().lastPathComponent

                return BuildInputs(
                    fastaURL: fastaOutput,
                    annotationInputs: annotationInputs,
                    organism: organism,
                    sequenceNames: sequenceNames,
                    sequenceCount: sequences.count,
                    totalLength: totalLength
                )
            }

            let sequences = try await FASTAReader(url: inputURL).readAll()
            guard !sequences.isEmpty else {
                throw CLIError.validationFailed(errors: ["No sequences found in \(sourceURL.lastPathComponent)"])
            }

            let sequenceNames = sequences.map(\.name)
            let totalLength = sequences.reduce(Int64(0)) { partial, sequence in
                partial + Int64(sequence.length)
            }

            return BuildInputs(
                fastaURL: inputURL,
                annotationInputs: [],
                organism: sourceURL.deletingPathExtension().lastPathComponent,
                sequenceNames: sequenceNames,
                sequenceCount: sequences.count,
                totalLength: totalLength
            )
        }

        private func decompressInput(sourceURL: URL, outputURL: URL) throws {
            let fm = FileManager.default
            if fm.fileExists(atPath: outputURL.path) {
                try? fm.removeItem(at: outputURL)
            }
            fm.createFile(atPath: outputURL.path, contents: nil)

            let outputHandle = try FileHandle(forWritingTo: outputURL)
            defer { try? outputHandle.close() }

            let wrapper = sourceURL.pathExtension.lowercased()
            let executable: String
            let arguments: [String]
            switch wrapper {
            case "gz", "gzip", "bgz":
                executable = "/usr/bin/gzip"
                arguments = ["-dc", sourceURL.path]
            case "bz2":
                executable = "/usr/bin/bzip2"
                arguments = ["-dc", sourceURL.path]
            case "xz":
                executable = "/usr/bin/xz"
                arguments = ["-dc", sourceURL.path]
            case "zst", "zstd":
                executable = "/usr/bin/env"
                arguments = ["zstd", "-dc", sourceURL.path]
            default:
                throw CLIError.validationFailed(errors: ["Unsupported compression wrapper: .\(wrapper)"])
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = outputHandle
            let stderrPipe = Pipe()
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                throw CLIError.conversionFailed(reason: "Failed to launch decompressor: \(error.localizedDescription)")
            }
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let message = stderr?.isEmpty == false ? stderr! : "decompressor exited with code \(process.terminationStatus)"
                throw CLIError.conversionFailed(reason: message)
            }
        }
    }
}

// MARK: - Kraken2 Import

extension ImportCommand {

    /// Import Kraken2 classification results into a Lungfish project.
    ///
    /// Copies the kreport (and optionally the per-read output file) into a
    /// `classification-kraken2` subdirectory and prints a species summary.
    struct Kraken2Subcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "kraken2",
            abstract: "Import Kraken2 classification results"
        )

        @Argument(help: "Path to the Kraken2 kreport file")
        var kreportFile: String

        @Option(
            name: .customLong("output"),
            help: "Path to the Kraken2 per-read output file"
        )
        var outputFile: String?

        @Option(
            name: .customLong("name"),
            help: "Optional imported result name (used in output directory)"
        )
        var name: String?

        @Option(
            name: [.customLong("output-dir"), .customShort("o")],
            help: "Output project directory (default: current directory)"
        )
        var outputDir: String?

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let kreportURL = URL(fileURLWithPath: kreportFile)

            guard FileManager.default.fileExists(atPath: kreportURL.path) else {
                print(formatter.error("Kreport file not found: \(kreportFile)"))
                throw CLIExitCode.inputError.exitCode
            }

            if let outputPath = outputFile {
                guard FileManager.default.fileExists(atPath: outputPath) else {
                    print(formatter.error("Output file not found: \(outputPath)"))
                    throw CLIExitCode.inputError.exitCode
                }
            }

            let outputDirectory = resolveOutputDirectory(outputDir)

            print(formatter.header("Kraken2 Import"))
            print("")

            let kreportData: Data
            do {
                kreportData = try Data(contentsOf: kreportURL)
            } catch {
                print(formatter.error("Failed to parse kreport: \(error.localizedDescription)"))
                throw CLIExitCode.formatError.exitCode
            }
            guard let kreportContent = String(data: kreportData, encoding: .utf8) else {
                print(formatter.error("Cannot read kreport file as text"))
                throw CLIExitCode.formatError.exitCode
            }
            let parsed = parseKreport(kreportContent)

            let imported: Kraken2ImportResult
            do {
                var provenanceCommand = [
                    "lungfish-cli",
                    "import",
                    "kraken2",
                    kreportURL.path,
                    "--output-dir",
                    outputDirectory.path,
                ]
                if let outputFile {
                    provenanceCommand += ["--output", URL(fileURLWithPath: outputFile).path]
                }
                if let name {
                    provenanceCommand += ["--name", name]
                }
                imported = try MetagenomicsImportService.importKraken2(
                    kreportURL: kreportURL,
                    outputDirectory: outputDirectory,
                    outputFileURL: outputFile.map { URL(fileURLWithPath: $0) },
                    preferredName: name,
                    provenanceCommand: provenanceCommand
                )
            } catch {
                print(formatter.error(error.localizedDescription))
                throw metagenomicsImportExitCode(for: error).exitCode
            }

            print(formatter.keyValueTable([
                ("Kreport", kreportURL.lastPathComponent),
                ("Output", imported.resultDirectory.lastPathComponent),
                ("Total reads", formatNumber(Int64(imported.totalReads))),
                ("Classified", formatNumber(Int64(parsed.classifiedReads))),
                ("Unclassified", formatNumber(Int64(parsed.unclassifiedReads))),
                ("Species", String(imported.speciesCount)),
            ]))
            print("")

            if !parsed.speciesEntries.isEmpty {
                print(formatter.header("Top Species"))
                print("")

                let topSpecies = parsed.speciesEntries
                    .sorted { $0.reads > $1.reads }
                    .prefix(15)

                let rows: [[String]] = topSpecies.map { entry in
                    [
                        entry.name,
                        formatNumber(Int64(entry.reads)),
                        String(format: "%.2f%%", entry.percentage),
                    ]
                }

                print(formatter.table(
                    headers: ["Species", "Reads", "Fraction"],
                    rows: Array(rows)
                ))
                print("")
            }

            print(formatter.success("Kraken2 import complete: \(imported.resultDirectory.lastPathComponent)"))
        }
    }
}

// MARK: - EsViritu Import

extension ImportCommand {

    /// Import EsViritu viral detection results into a Lungfish project.
    ///
    /// Copies the results directory and prints a detection summary.
    struct EsVirituSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "esviritu",
            abstract: "Import EsViritu viral detection results"
        )

        @Argument(help: "Path to the EsViritu results directory")
        var inputPath: String

        @Option(
            name: [.customLong("output-dir"), .customShort("o")],
            help: "Output project directory (default: current directory)"
        )
        var outputDir: String?

        @Option(
            name: .customLong("name"),
            help: "Optional imported result name (used in output directory)"
        )
        var name: String?

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let inputURL = URL(fileURLWithPath: inputPath)

            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                print(formatter.error("Input path not found: \(inputPath)"))
                throw CLIExitCode.inputError.exitCode
            }

            let outputDirectory = resolveOutputDirectory(outputDir)

            print(formatter.header("EsViritu Import"))
            print("")

            let imported: EsVirituImportResult
            do {
                var provenanceCommand = [
                    "lungfish-cli",
                    "import",
                    "esviritu",
                    inputURL.path,
                    "--output-dir",
                    outputDirectory.path,
                ]
                if let name {
                    provenanceCommand += ["--name", name]
                }
                imported = try MetagenomicsImportService.importEsViritu(
                    inputURL: inputURL,
                    outputDirectory: outputDirectory,
                    preferredName: name,
                    provenanceCommand: provenanceCommand
                )
            } catch {
                print(formatter.error(error.localizedDescription))
                throw metagenomicsImportExitCode(for: error).exitCode
            }

            print(formatter.keyValueTable([
                ("Source", inputURL.lastPathComponent),
                ("Files imported", String(imported.importedFileCount)),
                ("Detections", String(imported.virusCount)),
                ("Output", imported.resultDirectory.lastPathComponent),
            ]))
            print("")

            print(formatter.success("EsViritu import complete: \(imported.importedFileCount) file(s)"))
        }
    }
}

// MARK: - TaxTriage Import

extension ImportCommand {

    /// Import TaxTriage classification results into a Lungfish project.
    ///
    /// Copies the results directory and prints a triage summary.
    struct TaxTriageSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "taxtriage",
            abstract: "Import TaxTriage classification results"
        )

        @Argument(help: "Path to the TaxTriage results directory")
        var inputPath: String

        @Option(
            name: [.customLong("output-dir"), .customShort("o")],
            help: "Output project directory (default: current directory)"
        )
        var outputDir: String?

        @Option(
            name: .customLong("name"),
            help: "Optional imported result name (used in output directory)"
        )
        var name: String?

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let inputURL = URL(fileURLWithPath: inputPath)

            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                print(formatter.error("Input path not found: \(inputPath)"))
                throw CLIExitCode.inputError.exitCode
            }

            let outputDirectory = resolveOutputDirectory(outputDir)

            print(formatter.header("TaxTriage Import"))
            print("")

            let imported: TaxTriageImportResult
            do {
                var provenanceCommand = [
                    "lungfish-cli",
                    "import",
                    "taxtriage",
                    inputURL.path,
                    "--output-dir",
                    outputDirectory.path,
                ]
                if let name {
                    provenanceCommand += ["--name", name]
                }
                imported = try MetagenomicsImportService.importTaxTriage(
                    inputURL: inputURL,
                    outputDirectory: outputDirectory,
                    preferredName: name,
                    provenanceCommand: provenanceCommand
                )
            } catch {
                print(formatter.error(error.localizedDescription))
                throw metagenomicsImportExitCode(for: error).exitCode
            }

            print(formatter.keyValueTable([
                ("Source", inputURL.lastPathComponent),
                ("Files imported", String(imported.importedFileCount)),
                ("Report entries", imported.reportEntryCount > 0 ? String(imported.reportEntryCount) : "N/A"),
                ("Output", imported.resultDirectory.lastPathComponent),
            ]))
            print("")

            // List imported files.
            let importedFiles = scanRegularFilesRecursively(in: imported.resultDirectory)
            if !globalOptions.quiet && !importedFiles.isEmpty {
                print(formatter.header("Imported Files"))
                for file in importedFiles.prefix(20) {
                    print("  \(formatter.path(file.lastPathComponent))")
                }
                if importedFiles.count > 20 {
                    print("  (+\(importedFiles.count - 20) more)")
                }
                print("")
            }

            print(formatter.success("TaxTriage import complete: \(imported.importedFileCount) file(s)"))
        }
    }
}

// MARK: - NAO-MGS Import

extension ImportCommand {

    /// Import NAO-MGS metagenomic surveillance results into a Lungfish project.
    ///
    /// Creates a canonical `naomgs-*` bundle containing manifest, cached hits,
    /// optional BAM alignment files, and downloaded references.
    struct NaoMgsSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "nao-mgs",
            abstract: "Import NAO-MGS metagenomic surveillance results"
        )

        @Argument(help: "Path to NAO-MGS results directory or virus_hits_final.tsv(.gz)")
        var inputPath: String

        @Option(name: .customLong("sample-name"), help: "Override sample name")
        var sampleName: String?

        @Option(
            name: [.customLong("output-dir"), .customShort("o")],
            help: "Output project/import directory (default: current directory)"
        )
        var outputDir: String?

        @Flag(
            name: .customLong("fetch-references"),
            inversion: .prefixedNo,
            help: "Fetch NCBI reference FASTA files into references/ (default: enabled)"
        )
        var fetchReferences: Bool = true

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)

            let inputURL = URL(fileURLWithPath: inputPath)
            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                print(formatter.error("Input not found: \(inputPath)"))
                throw CLIExitCode.inputError.exitCode
            }

            let outputDirectory: URL
            if let dir = outputDir {
                outputDirectory = URL(fileURLWithPath: dir)
            } else {
                outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            }

            let imported: NaoMgsImportResult
            do {
                var provenanceCommand = [
                    "lungfish-cli",
                    "import",
                    "nao-mgs",
                    inputURL.path,
                    "--output-dir",
                    outputDirectory.path,
                ]
                if let sampleName {
                    provenanceCommand += ["--sample-name", sampleName]
                }
                if !fetchReferences {
                    provenanceCommand.append("--no-fetch-references")
                }
                imported = try await MetagenomicsImportService.importNaoMgs(
                    inputURL: inputURL,
                    outputDirectory: outputDirectory,
                    sampleName: sampleName,
                    fetchReferences: fetchReferences,
                    preferredName: sampleName,
                    provenanceCommand: provenanceCommand
                ) { progress, message in
                    guard !globalOptions.quiet else { return }
                    print(String(format: "[%3.0f%%] %@", progress * 100, message))
                }
            } catch {
                print(formatter.error(error.localizedDescription))
                throw metagenomicsImportExitCode(for: error).exitCode
            }

            print(formatter.header("NAO-MGS Import"))
            print("")
            print(formatter.keyValueTable([
                ("Sample", imported.sampleName),
                ("Total hits", formatNumber(Int64(imported.totalHitReads))),
                ("Distinct taxa", String(imported.taxonCount)),
                ("References fetched", String(imported.fetchedReferenceCount)),
                ("Output", imported.resultDirectory.lastPathComponent),
            ]))
            print("")
            print(formatter.success("NAO-MGS import complete: \(imported.resultDirectory.lastPathComponent)"))
        }
    }

    // MARK: - NVD Import

    /// Import NVD (Novel Virus Diagnostics) BLAST results into a Lungfish project.
    ///
    /// Parses `*_blast_concatenated.csv(.gz)` and writes an app-viewable
    /// `nvd-{experiment}` bundle with `manifest.json`, `hits.sqlite`, copied
    /// sample assets when present, and canonical provenance.
    struct NvdSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "nvd",
            abstract: "Import NVD BLAST results"
        )

        @Argument(help: "Path to NVD results directory (containing 05_labkey_bundling/)")
        var inputPath: String

        @Option(
            name: [.customLong("output-dir"), .customShort("o")],
            help: "Output project/import directory (default: current directory)"
        )
        var outputDir: String?

        @Option(
            name: .customLong("name"),
            help: "Override the bundle name (default: nvd-{experiment})"
        )
        var name: String?

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let inputURL = URL(fileURLWithPath: inputPath)

            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                print(formatter.error("Input directory not found: \(inputPath)"))
                throw CLIExitCode.inputError.exitCode
            }

            if !globalOptions.quiet {
                print(formatter.header("NVD Import"))
                print("")
            }

            let outputDirectory: URL
            if let dir = outputDir {
                outputDirectory = URL(fileURLWithPath: dir)
            } else {
                outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            }

            var provenanceCommand = [
                "lungfish-cli",
                "import",
                "nvd",
                inputURL.path,
                "--output-dir",
                outputDirectory.path,
            ]
            if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                provenanceCommand += ["--name", name]
            }

            do {
                let imported = try await MetagenomicsImportService.importNvd(
                    inputURL: inputURL,
                    outputDirectory: outputDirectory,
                    preferredName: name,
                    samtoolsPath: nil,
                    provenanceCommand: provenanceCommand
                ) { progress, message in
                    if !globalOptions.quiet, progress < 1.0 {
                        print(formatter.info(message))
                    }
                }

                if !globalOptions.quiet {
                    print(formatter.keyValueTable([
                        ("Total hits", String(imported.hitCount)),
                        ("Samples", String(imported.sampleCount)),
                        ("Contigs", String(imported.contigCount)),
                        ("Output", imported.resultDirectory.lastPathComponent),
                    ]))
                    print("")
                    print(formatter.success("NVD import complete: \(imported.resultDirectory.lastPathComponent)"))
                }
            } catch {
                print(formatter.error(error.localizedDescription))
                throw metagenomicsImportExitCode(for: error).exitCode
            }
        }
    }
}

// MARK: - Metagenomics Import Error Mapping

private func metagenomicsImportExitCode(for error: Error) -> CLIExitCode {
    if let importError = error as? MetagenomicsImportError {
        return metagenomicsImportExitCode(for: importError)
    }
    if error is CancellationError {
        return .cancelled
    }
    return .workflowError
}

private func metagenomicsImportExitCode(for error: MetagenomicsImportError) -> CLIExitCode {
    switch error {
    case .inputNotFound:
        return .inputError
    case .parseFailed:
        return .formatError
    case .outputAlreadyExists:
        return .outputError
    case .outputDirectoryCreationFailed, .copyFailed:
        return .outputError
    case .toolUnavailable:
        return .dependency
    case .importAborted(_, let underlying):
        return metagenomicsImportExitCode(for: underlying)
    }
}

// MARK: - Kreport Parsing

/// Parsed entry from a Kraken2 kreport file.
private struct KreportEntry {
    let percentage: Double
    let reads: Int
    let name: String
    let rank: String
}

/// Parsed summary from a Kraken2 kreport file.
private struct KreportSummary {
    let totalReads: Int
    let classifiedReads: Int
    let unclassifiedReads: Int
    let speciesEntries: [KreportEntry]
}

/// Parses a Kraken2 kreport file.
///
/// kreport format columns:
/// 1. % of reads at or below this node
/// 2. Number of reads at or below this node
/// 3. Number of reads assigned directly to this node
/// 4. Rank code (U, R, D, P, C, O, F, G, S, etc.)
/// 5. NCBI taxonomy ID
/// 6. Scientific name (indented)
private func parseKreport(_ content: String) -> KreportSummary {
    var totalReads = 0
    var unclassifiedReads = 0
    var classifiedReads = 0
    var speciesEntries: [KreportEntry] = []

    let lines = content.split(separator: "\n")
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let cols = trimmed.split(separator: "\t")
        guard cols.count >= 6 else { continue }

        let percentage = Double(cols[0].trimmingCharacters(in: .whitespaces)) ?? 0
        let cumulativeReads = Int(cols[1].trimmingCharacters(in: .whitespaces)) ?? 0
        let rank = String(cols[3].trimmingCharacters(in: .whitespaces))
        let name = String(cols[5].trimmingCharacters(in: .whitespaces))

        if rank == "U" {
            unclassifiedReads = cumulativeReads
        } else if rank == "R" {
            // Root-level entry gives us total classified.
            totalReads = cumulativeReads + unclassifiedReads
            classifiedReads = cumulativeReads
        }

        if rank == "S" {
            speciesEntries.append(KreportEntry(
                percentage: percentage,
                reads: cumulativeReads,
                name: name,
                rank: rank
            ))
        }
    }

    // If we never saw root, estimate from unclassified percentage.
    if totalReads == 0 && unclassifiedReads > 0 {
        totalReads = unclassifiedReads
        classifiedReads = 0
    }

    return KreportSummary(
        totalReads: totalReads,
        classifiedReads: classifiedReads,
        unclassifiedReads: unclassifiedReads,
        speciesEntries: speciesEntries
    )
}

// MARK: - NAO-MGS Taxon Summary Printer

/// Prints a formatted NAO-MGS taxon summary table.
///
/// Extracted as a free function to avoid `@MainActor`/`@Sendable` issues.
private func printNaoMgsTaxonSummary(
    _ summaries: some Collection<NaoMgsTaxonSummary>,
    formatter: TerminalFormatter
) {
    guard !summaries.isEmpty else { return }

    print(formatter.header("Top Viral Taxa"))
    print("")

    let rows: [[String]] = summaries.map { summary in
        [
            String(summary.taxId),
            String(summary.name.prefix(50)),
            String(summary.hitCount),
            String(format: "%.1f%%", summary.avgIdentity),
            String(format: "%.1f", summary.avgBitScore),
            String(summary.accessions.count),
        ]
    }

    print(formatter.table(
        headers: ["TaxID", "Organism", "Hits", "Avg %ID", "Avg Score", "Refs"],
        rows: rows
    ))
    print("")
}

// MARK: - Shared Helpers

/// Resolves the output directory from an optional path string.
///
/// Returns the provided path as a URL, or defaults to the current working
/// directory if no path was specified.
private func resolveOutputDirectory(_ outputDir: String?) -> URL {
    if let dir = outputDir {
        return URL(fileURLWithPath: dir)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

/// Formats a number with thousands separators.
private func formatNumber(_ value: Int64) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.groupingSeparator = ","
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
}

/// Formats a base count with appropriate unit suffix (bp, kb, Mb, Gb).
private func formatBases(_ bases: Int64) -> String {
    if bases < 1_000 {
        return "\(bases) bp"
    } else if bases < 1_000_000 {
        return String(format: "%.1f kb", Double(bases) / 1_000)
    } else if bases < 1_000_000_000 {
        return String(format: "%.1f Mb", Double(bases) / 1_000_000)
    } else {
        return String(format: "%.2f Gb", Double(bases) / 1_000_000_000)
    }
}

private struct ImportArtifactConflictError: Error, LocalizedError {
    let sourceURL: URL
    let destinationURL: URL

    var errorDescription: String? {
        """
        Destination already exists with different contents: \(destinationURL.path). \
        Remove or rename the existing file before importing \(sourceURL.path).
        """
    }
}

private func copyImportArtifactIfNeeded(from sourceURL: URL, to destinationURL: URL) throws -> Bool {
    let fileManager = FileManager.default
    if sourceURL.standardizedFileURL.path == destinationURL.standardizedFileURL.path {
        return false
    }

    if fileManager.fileExists(atPath: destinationURL.path) {
        guard try importArtifactsMatch(sourceURL, destinationURL) else {
            throw ImportArtifactConflictError(sourceURL: sourceURL, destinationURL: destinationURL)
        }
        return false
    }

    try fileManager.copyItem(at: sourceURL, to: destinationURL)
    return true
}

private func importArtifactsMatch(_ lhs: URL, _ rhs: URL) throws -> Bool {
    let lhsSize = try ProvenanceFileHasher.fileSize(of: lhs)
    let rhsSize = try ProvenanceFileHasher.fileSize(of: rhs)
    guard lhsSize == rhsSize else { return false }
    return try ProvenanceFileHasher.sha256(of: lhs) == ProvenanceFileHasher.sha256(of: rhs)
}

private func removeCreatedImportArtifacts(_ urls: [URL]) {
    for url in urls.reversed() {
        try? FileManager.default.removeItem(at: url)
    }
}

private func detectNativeToolVersion(_ tool: NativeTool) async -> String {
    do {
        let result = try await NativeToolRunner.shared.run(tool, arguments: ["--version"], timeout: 30)
        let combined = (result.stdout + "\n" + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = combined.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) {
            return String(combined[range])
        }
        return combined.split(whereSeparator: \.isNewline).first.map(String.init) ?? "unknown"
    } catch {
        return "unknown"
    }
}

private func nativeToolProvenanceStep(
    toolName: String,
    toolVersion: String,
    result: NativeToolResult,
    fallbackArgv: [String],
    inputs: [ProvenanceFileDescriptor],
    outputs: [ProvenanceFileDescriptor],
    startedAt: Date,
    completedAt: Date
) -> ProvenanceStep {
    let argv = result.arguments.isEmpty ? fallbackArgv : result.arguments
    return ProvenanceStep(
        toolName: toolName,
        toolVersion: toolVersion,
        argv: argv,
        reproducibleCommand: argv.map(shellEscape).joined(separator: " "),
        inputs: inputs,
        outputs: outputs,
        exitStatus: Int(result.exitCode),
        wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
        stderr: result.stderr,
        startedAt: startedAt,
        completedAt: completedAt
    )
}

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

            let store = SampleMetadataStore(
                scanResult: scanResult,
                sampleColumnIndex: bestColumn.index,
                knownSampleIds: knownSampleIds
            )

            // Persist to bundle (pass original CSV data for storage)
            try store.persist(originalData: csvData, to: bundleURL)
            try writeProvenance(
                store: store,
                inputURL: inputURL,
                bundleURL: bundleURL,
                metadataURL: bundleURL.appendingPathComponent("metadata/sample_metadata.tsv"),
                sampleColumnIndex: bestColumn.index,
                sampleColumnName: bestColumn.name,
                knownSampleCount: knownSampleIds.count,
                totalMetadataRows: scanResult.totalRows,
                startedAt: startedAt
            )

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
                toolName: "lungfish-cli",
                toolVersion: WorkflowRun.currentAppVersion
            )
            .argv([
                "lungfish-cli",
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

/// Recursively scans a directory and returns regular files sorted by path.
private func scanRegularFilesRecursively(in directory: URL) -> [URL] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    return enumerator
        .compactMap { $0 as? URL }
        .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        .sorted { $0.path < $1.path }
}
