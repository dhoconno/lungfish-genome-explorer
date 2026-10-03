// BundleCreateSubcommand.swift - Create a new bundle
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Create Subcommand

/// Create a new bundle
struct BundleCreateSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new reference bundle",
        discussion: """
            Creates a new .lungfishref bundle from source files.

            Required: FASTA sequence file
            Optional: Annotation files (GFF3, GTF, BED), variant files (VCF)

            Examples:
              lungfish-cli bundle create --fasta genome.fa --name "My Genome" --output-dir ./bundles
              lungfish-cli bundle create --fasta genome.fa --annotation genes.gff3 --name "Annotated Genome" --output-dir ./
            """
    )

    @Option(name: .long, help: "Input FASTA file (required)")
    var fasta: String

    @Option(name: .long, help: "Bundle name (required)")
    var name: String

    @Option(name: .customLong("output-dir"), help: "Output directory (required)")
    var outputDir: String

    @Option(name: .long, help: "Bundle identifier (default: auto-generated)")
    var identifier: String?

    @Option(name: .long, help: "Bundle description")
    var bundleDescription: String?

    @Option(name: .long, help: "Source organism name")
    var organism: String = "Unknown"

    @Option(name: .long, help: "Assembly name")
    var assembly: String = "Unknown"

    @Option(name: .long, parsing: .upToNextOption, help: "Annotation file(s) to include")
    var annotation: [String] = []

    @Option(name: .long, parsing: .upToNextOption, help: "Variant file(s) to include")
    var variant: [String] = []

    @Flag(name: .long, help: "Compress FASTA with bgzip")
    var compress: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let runStartedAt = Date()
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        // Validate inputs
        guard FileManager.default.fileExists(atPath: fasta) else {
            throw CLIError.inputFileNotFound(path: fasta)
        }

        guard FileManager.default.fileExists(atPath: outputDir) else {
            throw CLIError.inputFileNotFound(path: outputDir)
        }

        // Validate annotation files
        for annoPath in annotation {
            guard FileManager.default.fileExists(atPath: annoPath) else {
                throw CLIError.inputFileNotFound(path: annoPath)
            }
        }

        // Validate variant files
        for varPath in variant {
            guard FileManager.default.fileExists(atPath: varPath) else {
                throw CLIError.inputFileNotFound(path: varPath)
            }
        }

        let fastaURL = URL(fileURLWithPath: fasta)
        let outputURL = URL(fileURLWithPath: outputDir)

        // Build annotation inputs
        let annotationInputs = annotation.map { path -> AnnotationInput in
            let url = URL(fileURLWithPath: path)
            return AnnotationInput(
                url: url,
                name: url.deletingPathExtension().lastPathComponent
            )
        }

        // Build variant inputs
        let variantInputs = variant.map { path -> VariantInput in
            let url = URL(fileURLWithPath: path)
            return VariantInput(
                url: url,
                name: url.deletingPathExtension().lastPathComponent
            )
        }

        // Generate identifier if not provided
        let bundleIdentifier = identifier ?? "com.lungfish.\(name.lowercased().replacingOccurrences(of: " ", with: "-"))"

        // Create configuration
        let config = BuildConfiguration(
            name: name,
            identifier: bundleIdentifier,
            fastaURL: fastaURL,
            annotationFiles: annotationInputs,
            variantFiles: variantInputs,
            signalFiles: [],
            outputDirectory: outputURL,
            source: SourceInfo(
                organism: organism,
                commonName: nil,
                taxonomyId: nil,
                assembly: assembly,
                assemblyAccession: nil,
                database: nil,
                sourceURL: nil,
                downloadDate: nil,
                notes: bundleDescription
            ),
            compressFASTA: compress
        )

        // Build the bundle
        if globalOptions.outputFormat == .text {
            print(formatter.info("Creating bundle '\(name)'..."))
        }

        // Use NativeBundleBuilder which uses bundled bioinformatics tools
        // (samtools, bcftools, bgzip, etc.) from the app bundle's Resources/Tools.
        let bundleURL: URL
        let builder = await NativeBundleBuilder()

        // Check for required tools
        if globalOptions.outputFormat == .text && !globalOptions.quiet {
            print(formatter.info("Checking for native bioinformatics tools..."))
        }

        if let missingInfo = await builder.checkRequiredTools() {
            if globalOptions.outputFormat == .text && !globalOptions.quiet {
                print(formatter.error("Bundled bioinformatics tools are missing."))
                print(formatter.error("Missing: \(missingInfo.missingTools.map { $0.rawValue }.joined(separator: ", "))"))
                print(formatter.error("The app bundle may be incomplete. Please reinstall the app."))
                print(formatter.info("Falling back to basic file copying (no format conversion)."))
            }
            // Fall back to basic builder
            let basicBuilder = await ReferenceBundleBuilder()
            bundleURL = try await basicBuilder.build(configuration: config) { step, progress, message in
                if globalOptions.outputFormat == .text && !globalOptions.quiet {
                    let progressPercent = Int(progress * 100)
                    print("\r\(formatter.info("[\(progressPercent)%] \(message)"))", terminator: "")
                    fflush(stdout)
                }
            }
        } else {
            if globalOptions.outputFormat == .text && !globalOptions.quiet {
                print(formatter.success("Native tools available. Using samtools, bgzip for proper format conversion."))
            }
            bundleURL = try await builder.build(configuration: config) { step, progress, message in
                if globalOptions.outputFormat == .text && !globalOptions.quiet {
                    let progressPercent = Int(progress * 100)
                    print("\r\(formatter.info("[\(progressPercent)%] \(message)"))", terminator: "")
                    fflush(stdout)
                }
            }
        }

        do {
            try await writeCreateProvenance(
                configuration: config,
                bundleURL: bundleURL,
                bundleIdentifier: bundleIdentifier,
                startedAt: runStartedAt,
                compress: compress
            )
        } catch {
            try? FileManager.default.removeItem(at: bundleURL)
            throw error
        }

        if globalOptions.outputFormat == .text {
            print() // Newline after progress
            print(formatter.success("Bundle created: \(bundleURL.path)"))
        } else if globalOptions.outputFormat == .json {
            let handler = JSONOutputHandler()
            handler.writeData(["path": bundleURL.path, "name": name], label: nil)
        }
    }

    private func writeCreateProvenance(
        configuration: BuildConfiguration,
        bundleURL: URL,
        bundleIdentifier: String,
        startedAt: Date,
        compress: Bool
    ) async throws {
        let inputs = Self.inputFileRecords(for: configuration)
        let outputs = Self.outputFileRecords(in: bundleURL)
        let parameters = Self.provenanceParameters(
            configuration: configuration,
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier,
            compress: compress
        )
        let nativeToolSteps = Self.nativeBuilderToolSteps(in: bundleURL)
        try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish bundle create",
            parameters: parameters,
            toolName: "lungfish bundle create",
            toolVersion: WorkflowRun.currentAppVersion,
            command: Self.reproducibleCommand(
                configuration: configuration,
                bundleIdentifier: bundleIdentifier,
                compress: compress
            ),
            extraSteps: nativeToolSteps,
            inputs: inputs,
            outputs: outputs,
            exitCode: 0,
            wallTime: Date().timeIntervalSince(startedAt),
            stderr: nil,
            status: .completed,
            outputDirectory: bundleURL
        )
    }

    private static func nativeBuilderToolSteps(in bundleURL: URL) -> [ProvenanceStep] {
        guard let builderEnvelope = try? ProvenanceEnvelopeReader.load(from: bundleURL) else {
            return []
        }
        return builderEnvelope.steps.filter { $0.toolName != "NativeBundleBuilder.build" }
    }

    private static func inputFileRecords(for configuration: BuildConfiguration) -> [FileRecord] {
        var records = [
            ProvenanceRecorder.fileRecord(url: configuration.fastaURL, format: .fasta, role: .reference)
        ]
        records += configuration.annotationFiles.map {
            ProvenanceRecorder.fileRecord(url: $0.url, format: fileFormat(for: $0.url), role: .input)
        }
        records += configuration.variantFiles.map {
            ProvenanceRecorder.fileRecord(url: $0.url, format: .vcf, role: .input)
        }
        records += configuration.signalFiles.map {
            ProvenanceRecorder.fileRecord(url: $0.url, format: fileFormat(for: $0.url), role: .input)
        }
        return records
    }

    private static func outputFileRecords(in bundleURL: URL) -> [FileRecord] {
        CLIProvenanceSupport.bundlePayloadURLs(in: bundleURL).map {
            ProvenanceRecorder.fileRecord(url: $0, format: fileFormat(for: $0), role: .output)
        }
    }

    private static func provenanceParameters(
        configuration: BuildConfiguration,
        bundleURL: URL,
        bundleIdentifier: String,
        compress: Bool
    ) -> [String: ParameterValue] {
        [
            "name": .string(configuration.name),
            "identifier": .string(bundleIdentifier),
            "outputBundle": .file(bundleURL),
            "organism": .string(configuration.source.organism),
            "assembly": .string(configuration.source.assembly),
            "description": configuration.source.notes.map(ParameterValue.string) ?? .null,
            "compressFASTA": .boolean(compress),
            "annotationFiles": .array(configuration.annotationFiles.map { .file($0.url) }),
            "variantFiles": .array(configuration.variantFiles.map { .file($0.url) }),
            "signalFiles": .array(configuration.signalFiles.map { .file($0.url) }),
        ]
    }

    private static func reproducibleCommand(
        configuration: BuildConfiguration,
        bundleIdentifier: String,
        compress: Bool
    ) -> [String] {
        var command = [
            CLICommandIdentity.executableName, "bundle", "create",
            "--fasta", configuration.fastaURL.path,
            "--name", configuration.name,
            "--output-dir", configuration.outputDirectory.path,
            "--identifier", bundleIdentifier,
            "--organism", configuration.source.organism,
            "--assembly", configuration.source.assembly,
        ]
        if let description = configuration.source.notes {
            command += ["--bundle-description", description]
        }
        for annotation in configuration.annotationFiles {
            command += ["--annotation", annotation.url.path]
        }
        for variant in configuration.variantFiles {
            command += ["--variant", variant.url.path]
        }
        if compress {
            command.append("--compress")
        }
        return command
    }

    private static func fileFormat(for url: URL) -> FileFormat {
        var ext = url.pathExtension.lowercased()
        if ext == "gz" {
            ext = url.deletingPathExtension().pathExtension.lowercased()
        }
        switch ext {
        case "fa", "fasta", "fna":
            return .fasta
        case "gff", "gff3", "gtf":
            return .gff3
        case "vcf":
            return .vcf
        case "bed":
            return .bed
        case "json":
            return .json
        case "txt", "tsv", "csv":
            return .text
        default:
            return .unknown
        }
    }
}
