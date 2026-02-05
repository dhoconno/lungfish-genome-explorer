// BundleCommand.swift - Reference bundle management commands
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

/// Manage reference genome bundles (.lungfishref)
struct BundleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bundle",
        abstract: "Manage reference genome bundles (.lungfishref)",
        discussion: """
            Reference genome bundles are directory packages containing a genome sequence,
            annotations, variants, and signal tracks in optimized binary formats.

            Use these commands to create, inspect, and validate bundles.

            Examples:
              lungfish bundle info MyGenome.lungfishref
              lungfish bundle create --fasta genome.fa --name "My Genome" --output ./
              lungfish bundle validate MyGenome.lungfishref
            """,
        subcommands: [
            BundleInfoSubcommand.self,
            BundleCreateSubcommand.self,
            BundleValidateSubcommand.self,
            BundleListSubcommand.self,
        ],
        defaultSubcommand: BundleInfoSubcommand.self
    )
}

// MARK: - Info Subcommand

/// Display bundle information
struct BundleInfoSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Display bundle information",
        discussion: """
            Shows detailed information about a reference bundle including:
            - Name, identifier, and description
            - Source organism and assembly
            - Genome size and chromosome count
            - Annotation, variant, and signal tracks

            Examples:
              lungfish bundle info MyGenome.lungfishref
              lungfish bundle info MyGenome.lungfishref --format json
            """
    )

    @Argument(help: "Path to the .lungfishref bundle")
    var bundlePath: String

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        // Validate path
        let bundleURL = URL(fileURLWithPath: bundlePath)
        guard FileManager.default.fileExists(atPath: bundlePath) else {
            throw CLIError.inputFileNotFound(path: bundlePath)
        }

        // Load manifest
        let manifest: BundleManifest
        do {
            manifest = try BundleManifest.load(from: bundleURL)
        } catch {
            throw CLIError.conversionFailed(reason: "Failed to load bundle manifest: \(error.localizedDescription)")
        }

        // Output based on format
        switch globalOptions.outputFormat {
        case .json:
            let handler = JSONOutputHandler()
            handler.writeData(BundleInfoOutput(manifest: manifest, path: bundlePath), label: nil)

        case .tsv:
            print("name\tidentifier\torganism\tassembly\ttotal_length\tchromosomes\tannotations\tvariants\ttracks")
            print("\(manifest.name)\t\(manifest.identifier)\t\(manifest.source.organism)\t\(manifest.source.assembly)\t\(manifest.genome.totalLength)\t\(manifest.genome.chromosomes.count)\t\(manifest.annotations.count)\t\(manifest.variants.count)\t\(manifest.tracks.count)")

        case .text:
            print(formatter.header("Bundle Information"))
            print(formatter.keyValueTable([
                ("Name", manifest.name),
                ("Identifier", manifest.identifier),
                ("Description", manifest.description ?? "(none)"),
                ("Format Version", manifest.formatVersion),
                ("Created", manifest.createdDate.formatted()),
            ]))

            print("\n" + formatter.header("Source"))
            print(formatter.keyValueTable([
                ("Organism", manifest.source.organism),
                ("Common Name", manifest.source.commonName ?? "(none)"),
                ("Assembly", manifest.source.assembly),
                ("Database", manifest.source.database ?? "(none)"),
                ("Source URL", manifest.source.sourceURL?.absoluteString ?? "(none)"),
            ]))

            print("\n" + formatter.header("Genome"))
            print(formatter.keyValueTable([
                ("Total Length", "\(formatter.number(Int(manifest.genome.totalLength))) bp"),
                ("Chromosomes", formatter.number(manifest.genome.chromosomes.count)),
                ("Sequence File", manifest.genome.path),
                ("Index File", manifest.genome.indexPath),
            ]))

            if !manifest.genome.chromosomes.isEmpty {
                print("\n" + formatter.header("Chromosomes"))
                let chromHeaders = ["Name", "Length (bp)", "Primary", "Mitochondrial"]
                let chromRows = manifest.genome.chromosomes.map { chrom -> [String] in
                    [
                        chrom.name,
                        formatter.number(Int(chrom.length)),
                        chrom.isPrimary ? "Yes" : "No",
                        chrom.isMitochondrial ? "Yes" : "No"
                    ]
                }
                print(formatter.table(headers: chromHeaders, rows: chromRows))
            }

            if !manifest.annotations.isEmpty {
                print("\n" + formatter.header("Annotation Tracks"))
                let annoHeaders = ["ID", "Name", "Type", "Features", "Path"]
                let annoRows = manifest.annotations.map { track -> [String] in
                    [
                        track.id,
                        track.name,
                        track.annotationType.rawValue,
                        track.featureCount.map { formatter.number($0) } ?? "-",
                        track.path
                    ]
                }
                print(formatter.table(headers: annoHeaders, rows: annoRows))
            }

            if !manifest.variants.isEmpty {
                print("\n" + formatter.header("Variant Tracks"))
                let varHeaders = ["ID", "Name", "Type", "Variants", "Path"]
                let varRows = manifest.variants.map { track -> [String] in
                    [
                        track.id,
                        track.name,
                        track.variantType.rawValue,
                        track.variantCount.map { formatter.number($0) } ?? "-",
                        track.path
                    ]
                }
                print(formatter.table(headers: varHeaders, rows: varRows))
            }

            if !manifest.tracks.isEmpty {
                print("\n" + formatter.header("Signal Tracks"))
                let sigHeaders = ["ID", "Name", "Type", "Path"]
                let sigRows = manifest.tracks.map { track -> [String] in
                    [
                        track.id,
                        track.name,
                        track.signalType.rawValue,
                        track.path
                    ]
                }
                print(formatter.table(headers: sigHeaders, rows: sigRows))
            }
        }
    }
}

/// Output structure for JSON format
struct BundleInfoOutput: Codable {
    let manifest: BundleManifest
    let path: String
}

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
              lungfish bundle create --fasta genome.fa --name "My Genome" --output-dir ./bundles
              lungfish bundle create --fasta genome.fa --annotation genes.gff3 --name "Annotated Genome" --output-dir ./
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

        // Use NativeBundleBuilder which uses locally installed bioinformatics tools
        // (samtools, bcftools, bgzip, etc.) via Homebrew or bundled with the app.
        // This is more reliable than containers and works on all macOS versions.
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

        if globalOptions.outputFormat == .text {
            print() // Newline after progress
            print(formatter.success("Bundle created: \(bundleURL.path)"))
        } else if globalOptions.outputFormat == .json {
            let handler = JSONOutputHandler()
            handler.writeData(["path": bundleURL.path, "name": name], label: nil)
        }
    }
}

// MARK: - Validate Subcommand

/// Validate a bundle
struct BundleValidateSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate a reference bundle",
        discussion: """
            Validates the structure and integrity of a .lungfishref bundle.

            Checks:
            - manifest.json exists and is valid
            - All referenced files exist
            - Genome sequence is readable
            - Index files are valid

            Examples:
              lungfish bundle validate MyGenome.lungfishref
              lungfish bundle validate *.lungfishref
            """
    )

    @Argument(help: "Bundle path(s) to validate")
    var bundles: [String]

    @Flag(name: .long, help: "Check file integrity (slower)")
    var checkIntegrity: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)
        var allValid = true
        var results: [BundleValidationResult] = []

        for bundlePath in bundles {
            let bundleURL = URL(fileURLWithPath: bundlePath)

            guard FileManager.default.fileExists(atPath: bundlePath) else {
                allValid = false
                results.append(BundleValidationResult(
                    path: bundlePath,
                    valid: false,
                    errors: ["Bundle not found"]
                ))
                if globalOptions.outputFormat == .text {
                    print(formatter.error("\(bundleURL.lastPathComponent): Not found"))
                }
                continue
            }

            var errors: [String] = []

            // Check manifest exists
            let manifestURL = bundleURL.appendingPathComponent("manifest.json")
            if !FileManager.default.fileExists(atPath: manifestURL.path) {
                errors.append("manifest.json not found")
            } else {
                // Try to load and validate manifest
                do {
                    let manifest = try BundleManifest.load(from: bundleURL)
                    let validationErrors = manifest.validate()
                    errors.append(contentsOf: validationErrors.map { $0.localizedDescription })

                    // Check referenced files exist
                    let genomePath = bundleURL.appendingPathComponent(manifest.genome.path)
                    if !FileManager.default.fileExists(atPath: genomePath.path) {
                        errors.append("Genome file not found: \(manifest.genome.path)")
                    }

                    let indexPath = bundleURL.appendingPathComponent(manifest.genome.indexPath)
                    if !FileManager.default.fileExists(atPath: indexPath.path) {
                        errors.append("Index file not found: \(manifest.genome.indexPath)")
                    }

                    for anno in manifest.annotations {
                        let annoPath = bundleURL.appendingPathComponent(anno.path)
                        if !FileManager.default.fileExists(atPath: annoPath.path) {
                            errors.append("Annotation file not found: \(anno.path)")
                        }
                    }

                    for variant in manifest.variants {
                        let varPath = bundleURL.appendingPathComponent(variant.path)
                        if !FileManager.default.fileExists(atPath: varPath.path) {
                            errors.append("Variant file not found: \(variant.path)")
                        }
                    }

                    for track in manifest.tracks {
                        let trackPath = bundleURL.appendingPathComponent(track.path)
                        if !FileManager.default.fileExists(atPath: trackPath.path) {
                            errors.append("Signal track not found: \(track.path)")
                        }
                    }
                } catch {
                    errors.append("Failed to load manifest: \(error.localizedDescription)")
                }
            }

            let isValid = errors.isEmpty
            if !isValid { allValid = false }

            results.append(BundleValidationResult(
                path: bundlePath,
                valid: isValid,
                errors: errors
            ))

            if globalOptions.outputFormat == .text {
                if isValid {
                    print(formatter.success("\(bundleURL.lastPathComponent): Valid"))
                } else {
                    print(formatter.error("\(bundleURL.lastPathComponent): Invalid"))
                    for error in errors {
                        print("  - \(error)")
                    }
                }
            }
        }

        if globalOptions.outputFormat == .json {
            let handler = JSONOutputHandler()
            handler.writeData(BundleValidationOutput(bundles: results, allValid: allValid), label: nil)
        }

        if !allValid {
            throw ExitCode.failure
        }
    }
}

/// Validation result for a single bundle
struct BundleValidationResult: Codable {
    let path: String
    let valid: Bool
    let errors: [String]
}

/// Overall validation output
struct BundleValidationOutput: Codable {
    let bundles: [BundleValidationResult]
    let allValid: Bool
}

// MARK: - List Subcommand

/// List bundle contents
struct BundleListSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List bundle contents",
        discussion: """
            Lists the files and tracks contained in a bundle.

            Examples:
              lungfish bundle list MyGenome.lungfishref
              lungfish bundle list MyGenome.lungfishref --tracks
            """
    )

    @Argument(help: "Path to the .lungfishref bundle")
    var bundlePath: String

    @Flag(name: .long, help: "Show tracks only")
    var tracks: Bool = false

    @Flag(name: .long, help: "Show files only")
    var files: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        let bundleURL = URL(fileURLWithPath: bundlePath)
        guard FileManager.default.fileExists(atPath: bundlePath) else {
            throw CLIError.inputFileNotFound(path: bundlePath)
        }

        let manifest: BundleManifest
        do {
            manifest = try BundleManifest.load(from: bundleURL)
        } catch {
            throw CLIError.conversionFailed(reason: "Failed to load bundle manifest: \(error.localizedDescription)")
        }

        if globalOptions.outputFormat == .json {
            let output = BundleListOutput(
                files: tracks ? nil : listBundleFiles(bundleURL),
                tracks: files ? nil : BundleTrackList(
                    annotations: manifest.annotations.map { $0.id },
                    variants: manifest.variants.map { $0.id },
                    signals: manifest.tracks.map { $0.id }
                )
            )
            let handler = JSONOutputHandler()
            handler.writeData(output, label: nil)
            return
        }

        // Text output
        if !tracks {
            print(formatter.header("Files"))
            for file in listBundleFiles(bundleURL) {
                print("  \(file)")
            }
        }

        if !files {
            if !manifest.annotations.isEmpty {
                print("\n" + formatter.header("Annotation Tracks"))
                for track in manifest.annotations {
                    print("  \(track.id): \(track.name) (\(track.annotationType.rawValue))")
                }
            }

            if !manifest.variants.isEmpty {
                print("\n" + formatter.header("Variant Tracks"))
                for track in manifest.variants {
                    print("  \(track.id): \(track.name) (\(track.variantType.rawValue))")
                }
            }

            if !manifest.tracks.isEmpty {
                print("\n" + formatter.header("Signal Tracks"))
                for track in manifest.tracks {
                    print("  \(track.id): \(track.name) (\(track.signalType.rawValue))")
                }
            }
        }
    }

    private func listBundleFiles(_ bundleURL: URL) -> [String] {
        var files: [String] = []
        let fileManager = FileManager.default

        if let enumerator = fileManager.enumerator(at: bundleURL, includingPropertiesForKeys: nil) {
            while let fileURL = enumerator.nextObject() as? URL {
                let relativePath = fileURL.path.replacingOccurrences(of: bundleURL.path + "/", with: "")
                files.append(relativePath)
            }
        }

        return files.sorted()
    }
}

/// Output structure for list command
struct BundleListOutput: Codable {
    let files: [String]?
    let tracks: BundleTrackList?
}

/// Track listing for JSON output
struct BundleTrackList: Codable {
    let annotations: [String]
    let variants: [String]
    let signals: [String]
}


