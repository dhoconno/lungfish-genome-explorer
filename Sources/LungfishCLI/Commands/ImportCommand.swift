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
            let runClock = ProvenanceRunClock()
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
                    toolVersion: LungfishCLI.configuration.version,
                    command: sampleMetadataProvenanceCommand(inputURL: inputURL, bundleURL: bundleURL),
                    inputs: inputRecords,
                    outputs: outputRecords,
                    exitCode: 0,
                    wallTime: runClock.elapsed,
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
                CLICommandIdentity.executableName,
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
}

// MARK: - VCF Import

/// `--import-profile` accepts the `VCFImportProfile` raw values
/// (`auto`, `low-memory`, `fast`, `ultra-low-memory`).
extension VCFImportProfile: ExpressibleByArgument {}

extension ImportCommand {

    /// Import a VCF variant file into a Lungfish project.
    ///
    /// Validates the VCF header, counts variants, and copies the file
    /// (and companion index) to the output directory. When the output
    /// directory is an existing `.lungfishref` bundle, the variants are
    /// attached to the bundle's variant database instead.
    struct VCFSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "vcf",
            abstract: "Import a VCF variant file"
        )

        @Argument(help: "Path to the VCF or VCF.GZ file")
        var inputFile: String

        @Option(
            name: [.customLong("output-dir"), .customShort("o")],
            help: "Output project directory, or an existing .lungfishref bundle to attach the variants to (default: current directory)"
        )
        var outputDir: String?

        @Option(
            name: .customLong("name"),
            help: "Display name for the variant track when attaching to a .lungfishref bundle (default: filename)"
        )
        var name: String?

        @Option(
            name: .customLong("import-profile"),
            help: "Variant database import profile when attaching to a .lungfishref bundle (default: auto)"
        )
        var importProfile: VCFImportProfile?

        @Option(
            name: .customLong("replace"),
            help: ArgumentHelp(
                "Replace the existing variant track with this id instead of adding a new track.",
                discussion: "Without --replace, a VCF whose file name matches an existing track is added under "
                    + "a new id (calls, calls-2, calls-3, ...); nothing is overwritten. "
                    + "Use `bundle list <bundle> --tracks` to see track ids."
            )
        )
        var replace: String?

        @OptionGroup(visibility: .hidden) var globalOptions: GlobalOptions

        func run() async throws {
            let runClock = ProvenanceRunClock()
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

            // An existing `.lungfishref` bundle gets the variants
            // attached to its variant database through the same
            // `VCFBundleVariantImport` core the GUI Import Center uses.
            if outputDirectory.pathExtension.lowercased() == "lungfishref" {
                guard FileManager.default.fileExists(
                    atPath: outputDirectory.appendingPathComponent(BundleManifest.filename).path
                ) else {
                    print(formatter.error(
                        "\(outputDir ?? outputDirectory.path) looks like a .lungfishref bundle path, but no bundle exists there yet. "
                            + "Create the reference bundle first, then attach the VCF to it."
                    ))
                    throw CLIExitCode.inputError.exitCode
                }
                guard ext == "vcf" else {
                    print(formatter.error("Only .vcf or .vcf.gz files can be attached to a .lungfishref bundle."))
                    throw CLIExitCode.formatError.exitCode
                }
                try runAttachToExistingBundle(
                    inputURL: inputURL,
                    bundleURL: outputDirectory,
                    formatter: formatter,
                    runClock: runClock
                )
                return
            }
            if name != nil || importProfile != nil || replace != nil {
                print(formatter.error("--name, --import-profile and --replace apply only when --output-dir is an existing .lungfishref bundle."))
                throw CLIExitCode.inputError.exitCode
            }

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
                    toolVersion: LungfishCLI.configuration.version,
                    command: vcfProvenanceCommand(inputURL: inputURL, outputDirectory: outputDirectory),
                    inputs: vcfInputRecords(inputURL: inputURL, format: variantFormat, indexArtifact: indexArtifact),
                    outputs: vcfOutputRecords(destURL: destURL, format: variantFormat, indexArtifact: indexArtifact),
                    exitCode: 0,
                    wallTime: runClock.elapsed,
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

        /// Attaches `inputURL` to an existing bundle's variant database as
        /// `variants/<track>.db`, updates the manifest's variant tracks and
        /// writes `variants/<track>.lungfish-provenance.json`.
        private func runAttachToExistingBundle(
            inputURL: URL,
            bundleURL: URL,
            formatter: TerminalFormatter,
            runClock: ProvenanceRunClock
        ) throws {
            let profile = importProfile ?? .auto
            print(formatter.header("VCF Import"))
            print("")
            print(formatter.keyValueTable([
                ("Input", inputURL.lastPathComponent),
                ("Bundle", bundleURL.path),
                ("Import profile", profile.rawValue),
            ]))
            print("")

            let quiet = globalOptions.quiet
            let command = vcfAttachCommand(inputURL: inputURL, bundleURL: bundleURL)
            let request = VCFBundleVariantImport.Request(
                vcfURL: inputURL,
                bundleURL: bundleURL,
                trackName: name,
                importProfile: profile,
                replaceTrackID: replace
            )
            let result: VCFBundleVariantImport.Result
            do {
                result = try VCFBundleVariantImport.attachInProcess(
                    request,
                    progressHandler: { _, message in
                        guard !quiet else { return }
                        print(formatter.info(message))
                    },
                    makeProvenance: { context in
                        try Self.vcfAttachProvenance(context: context, command: command, runClock: runClock)
                    }
                )
            } catch let error as VCFBundleVariantImport.Error {
                // `--replace` named a track the bundle does not have: a usage
                // error, not a failed import.
                print(formatter.error(error.localizedDescription))
                throw CLIExitCode.inputError.exitCode
            } catch {
                print(formatter.error("VCF attach failed: \(error.localizedDescription)"))
                throw CLIExitCode.failure.exitCode
            }
            if let warning = result.cleanupWarning {
                print(formatter.warning(warning))
            }

            print("")
            print(formatter.header("Summary"))
            print("")
            print(formatter.keyValueTable([
                ("Track ID", result.trackInfo.id),
                ("Track name", result.trackInfo.name),
                ("Variants", formatNumber(Int64(result.variantCount))),
                ("Database", result.trackInfo.databasePath ?? ""),
                ("Renamed chromosomes", String(result.chromosomeMapping.count)),
            ]))
            print("")
            print(formatter.success("VCF import complete: attached '\(result.trackInfo.name)' to \(bundleURL.lastPathComponent)"))
        }

        private func vcfAttachCommand(inputURL: URL, bundleURL: URL) -> [String] {
            var command = [CLICommandIdentity.executableName, "import", "vcf", inputURL.path, "--output-dir", bundleURL.path]
            if let name {
                command += ["--name", name]
            }
            if let importProfile {
                command += ["--import-profile", importProfile.rawValue]
            }
            if let replace {
                command += ["--replace", replace]
            }
            if globalOptions.quiet {
                command.append("--quiet")
            }
            if globalOptions.noColor {
                command.append("--no-color")
            }
            return command
        }

        static func vcfAttachProvenance(
            context: VCFBundleVariantImport.ProvenanceContext,
            command: [String],
            runClock: ProvenanceRunClock
        ) throws -> ProvenanceEnvelope {
            let request = context.request
            let toolVersion = "lungfish-cli \(LungfishCLI.configuration.version)"
            let input = try ProvenanceFileDescriptor.file(url: request.vcfURL, format: .vcf, role: .input)
            let output = try ProvenanceFileDescriptor.file(url: context.databaseURL, format: .unknown, role: .output)
            let startedAt = runClock.startedAt, completedAt = runClock.now
            let step = ProvenanceStep(
                toolName: "lungfish import vcf",
                toolVersion: toolVersion,
                argv: command,
                inputs: [input],
                outputs: [output],
                exitStatus: 0,
                wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
                stderr: nil,
                startedAt: startedAt,
                completedAt: completedAt
            )
            return ProvenanceEnvelope(
                createdAt: startedAt,
                workflowName: "lungfish import vcf",
                toolName: "lungfish import vcf",
                toolVersion: toolVersion,
                argv: command,
                durableReplayArgv: command,
                options: ProvenanceOptions(
                    explicit: [
                        "vcfPath": .file(request.vcfURL),
                        "bundlePath": .file(request.bundleURL),
                        "importProfile": .string(request.importProfile.rawValue),
                    ].merging(
                        request.replaceTrackID.map { ["replaceTrackId": .string($0)] } ?? [:],
                        uniquingKeysWith: { _, new in new }
                    ),
                    defaults: [
                        "trackName": .string(VCFBundleVariantImport.defaultTrackName(forVCFURL: request.vcfURL)),
                        "outputDirectory": .string("variants"),
                    ],
                    resolvedDefaults: [
                        "trackId": .string(context.trackInfo.id),
                        "replacedExistingTrack": .boolean(request.replaceTrackID != nil),
                        "trackName": .string(context.trackInfo.name),
                        "variantCount": .integer(context.variantCount),
                        "databasePath": .string(VCFBundleVariantImport.databaseRelativePath(trackID: context.trackInfo.id)),
                        "workflowProvenancePath": .string(VCFBundleVariantImport.provenanceRelativePath(trackID: context.trackInfo.id)),
                        "referenceBundleIdentifier": .string(context.originalManifest.identifier),
                        "referenceBundleName": .string(context.originalManifest.name),
                        "legacyBCFManifestFieldsAreSentinels": .boolean(true),
                    ]
                ),
                runtimeIdentity: ProvenanceRuntimeIdentity(),
                files: [input, output],
                output: output,
                outputs: [output],
                steps: [step],
                wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
                exitStatus: 0,
                stderr: nil
            )
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
            var command = [CLICommandIdentity.executableName, "import", "vcf", inputURL.path, "--output-dir", outputDirectory.path]
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

// MARK: - Shared Helpers

/// Resolves the output directory from an optional path string.
///
/// Returns the provided path as a URL, or defaults to the current working
/// directory if no path was specified.
func resolveOutputDirectory(_ outputDir: String?) -> URL {
    if let dir = outputDir {
        return URL(fileURLWithPath: dir)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

/// Formats a number with thousands separators.
func formatNumber(_ value: Int64) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.groupingSeparator = ","
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
}

/// Formats a base count with appropriate unit suffix (bp, kb, Mb, Gb).
func formatBases(_ bases: Int64) -> String {
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

struct ImportArtifactConflictError: Error, LocalizedError {
    let sourceURL: URL
    let destinationURL: URL

    var errorDescription: String? {
        """
        Destination already exists with different contents: \(destinationURL.path). \
        Remove or rename the existing file before importing \(sourceURL.path).
        """
    }
}

func copyImportArtifactIfNeeded(from sourceURL: URL, to destinationURL: URL) throws -> Bool {
    let fileManager = FileManager.default
    if sourceURL.canonicalFilePath == destinationURL.canonicalFilePath {
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

func removeCreatedImportArtifacts(_ urls: [URL]) {
    for url in urls.reversed() {
        try? FileManager.default.removeItem(at: url)
    }
}

func detectNativeToolVersion(_ tool: NativeTool) async -> String {
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

func nativeToolProvenanceStep(
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

/// Recursively scans a directory and returns regular files sorted by path.
func scanRegularFilesRecursively(in directory: URL) -> [URL] {
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
