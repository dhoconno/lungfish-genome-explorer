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
            Kraken2Subcommand.self,
            EsVirituSubcommand.self,
            TaxTriageSubcommand.self,
            NaoMgsSubcommand.self,
            NvdSubcommand.self,
        ]
    )
}

// MARK: - BAM Import

extension ImportCommand {

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
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let inputURL = URL(fileURLWithPath: inputFile)

            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                print(formatter.error("Input file not found: \(inputFile)"))
                throw ExitCode.failure
            }

            // Validate format from extension.
            var formatURL = inputURL
            if formatURL.pathExtension.lowercased() == "gz" {
                formatURL = formatURL.deletingPathExtension()
            }
            let ext = formatURL.pathExtension.lowercased()
            guard ["bam", "cram", "sam"].contains(ext) else {
                print(formatter.error("Unsupported alignment format: .\(ext). Expected .bam, .cram, or .sam"))
                throw ExitCode.failure
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

            // Copy alignment file.
            let destURL = outputDirectory.appendingPathComponent(inputURL.lastPathComponent)
            if !FileManager.default.fileExists(atPath: destURL.path) {
                if !globalOptions.quiet {
                    print(formatter.info("Copying alignment file..."))
                }
                try FileManager.default.copyItem(at: inputURL, to: destURL)
            }

            // Check for companion index file and copy if present.
            let indexCopied = copyCompanionIndex(
                for: inputURL, to: outputDirectory, formatter: formatter
            )

            // Attempt to collect statistics via samtools.
            var totalReads: Int64 = 0
            var mappedReads: Int64 = 0
            var unmappedReads: Int64 = 0
            var refContigs = 0
            var statsCollected = false

            do {
                let runner = NativeToolRunner.shared
                let idxstatsResult = try await runner.run(
                    .samtools,
                    arguments: ["idxstats", destURL.path],
                    timeout: 120
                )
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
                }
            } catch {
                // samtools not available - skip stats.
                if !globalOptions.quiet {
                    print(formatter.warning("samtools not available; skipping statistics collection"))
                }
            }

            // If no index was copied and samtools is available, try creating one.
            if !indexCopied {
                do {
                    let runner = NativeToolRunner.shared
                    if !globalOptions.quiet {
                        print(formatter.info("Creating index..."))
                    }
                    let indexResult = try await runner.run(
                        .samtools,
                        arguments: ["index", destURL.path],
                        timeout: 3600
                    )
                    if indexResult.isSuccess {
                        if !globalOptions.quiet {
                            print(formatter.success("Index created"))
                        }
                    } else {
                        print(formatter.warning(
                            "Failed to create index. The file may need sorting first."
                        ))
                    }
                } catch {
                    print(formatter.warning("samtools not available; could not create index"))
                }
            }

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
                    ("Index", indexCopied ? "found" : "not found"),
                ]))
            }

            print("")
            print(formatter.success("BAM import complete: \(destURL.lastPathComponent)"))
        }

        /// Copies a companion index file (.bai, .csi, .crai) if one exists next to the input.
        private func copyCompanionIndex(
            for inputURL: URL,
            to outputDirectory: URL,
            formatter: TerminalFormatter
        ) -> Bool {
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
                    if !fm.fileExists(atPath: destIndex.path) {
                        do {
                            try fm.copyItem(at: indexURL, to: destIndex)
                            if !globalOptions.quiet {
                                print(formatter.info("Copied index: \(indexURL.lastPathComponent)"))
                            }
                        } catch {
                            // Non-fatal; we can try creating one later.
                        }
                    }
                    return true
                }
            }
            return false
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
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let inputURL = URL(fileURLWithPath: inputFile)

            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                print(formatter.error("Input file not found: \(inputFile)"))
                throw ExitCode.failure
            }

            // Validate format from extension.
            var formatURL = inputURL
            if formatURL.pathExtension.lowercased() == "gz" {
                formatURL = formatURL.deletingPathExtension()
            }
            let ext = formatURL.pathExtension.lowercased()
            guard ["vcf", "bcf"].contains(ext) else {
                print(formatter.error("Unsupported variant format: .\(ext). Expected .vcf, .vcf.gz, or .bcf"))
                throw ExitCode.failure
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
                throw ExitCode.failure
            }

            // Create output directory and copy file.
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            let destURL = outputDirectory.appendingPathComponent(inputURL.lastPathComponent)
            if !FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.copyItem(at: inputURL, to: destURL)
            }

            // Copy companion index (.tbi, .csi) if present.
            copyVCFIndex(for: inputURL, to: outputDirectory, formatter: formatter)

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
        }

        /// Copies a companion index file (.tbi, .csi) if one exists next to the input.
        private func copyVCFIndex(
            for inputURL: URL,
            to outputDirectory: URL,
            formatter: TerminalFormatter
        ) {
            let fm = FileManager.default
            let candidates = [
                inputURL.path + ".tbi",
                inputURL.path + ".csi",
            ]

            for candidatePath in candidates {
                if fm.fileExists(atPath: candidatePath) {
                    let indexURL = URL(fileURLWithPath: candidatePath)
                    let destIndex = outputDirectory.appendingPathComponent(indexURL.lastPathComponent)
                    if !fm.fileExists(atPath: destIndex.path) {
                        do {
                            try fm.copyItem(at: indexURL, to: destIndex)
                            if !globalOptions.quiet {
                                print(formatter.info("Copied index: \(indexURL.lastPathComponent)"))
                            }
                        } catch {
                            // Non-fatal.
                        }
                    }
                }
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
                throw ExitCode.failure
            }

            let ext = normalizedExtension(for: inputURL)
            guard Self.fastaExtensions.contains(ext) || Self.genbankExtensions.contains(ext) else {
                print(formatter.error("Unsupported reference format: .\(ext)"))
                throw ExitCode.failure
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
                compressFASTA: true
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

        private func prepareBuildInputs(
            sourceURL: URL,
            extensionHint: String,
            tempDirectory: URL
        ) async throws -> BuildInputs {
            let inputURL: URL
            if Self.compressionExtensions.contains(sourceURL.pathExtension.lowercased()) {
                let decompressed = tempDirectory.appendingPathComponent("decompressed-input")
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
                throw ExitCode.failure
            }

            if let outputPath = outputFile {
                guard FileManager.default.fileExists(atPath: outputPath) else {
                    print(formatter.error("Output file not found: \(outputPath)"))
                    throw ExitCode.failure
                }
            }

            let outputDirectory = resolveOutputDirectory(outputDir)

            print(formatter.header("Kraken2 Import"))
            print("")

            let parsed: KreportSummary
            do {
                let kreportData = try Data(contentsOf: kreportURL)
                guard let kreportContent = String(data: kreportData, encoding: .utf8) else {
                    print(formatter.error("Cannot read kreport file as text"))
                    throw ExitCode.failure
                }
                parsed = parseKreport(kreportContent)
            } catch {
                print(formatter.error("Failed to parse kreport: \(error.localizedDescription)"))
                throw ExitCode.failure
            }

            let imported: Kraken2ImportResult
            do {
                imported = try MetagenomicsImportService.importKraken2(
                    kreportURL: kreportURL,
                    outputDirectory: outputDirectory,
                    outputFileURL: outputFile.map { URL(fileURLWithPath: $0) },
                    preferredName: name
                )
            } catch {
                print(formatter.error(error.localizedDescription))
                throw ExitCode.failure
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
                throw ExitCode.failure
            }

            let outputDirectory = resolveOutputDirectory(outputDir)

            print(formatter.header("EsViritu Import"))
            print("")

            let imported: EsVirituImportResult
            do {
                imported = try MetagenomicsImportService.importEsViritu(
                    inputURL: inputURL,
                    outputDirectory: outputDirectory,
                    preferredName: name
                )
            } catch {
                print(formatter.error(error.localizedDescription))
                throw ExitCode.failure
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
                throw ExitCode.failure
            }

            let outputDirectory = resolveOutputDirectory(outputDir)

            print(formatter.header("TaxTriage Import"))
            print("")

            let imported: TaxTriageImportResult
            do {
                imported = try MetagenomicsImportService.importTaxTriage(
                    inputURL: inputURL,
                    outputDirectory: outputDirectory,
                    preferredName: name
                )
            } catch {
                print(formatter.error(error.localizedDescription))
                throw ExitCode.failure
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
                throw ExitCode.failure
            }

            let outputDirectory: URL
            if let dir = outputDir {
                outputDirectory = URL(fileURLWithPath: dir)
            } else {
                outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            }

            let imported: NaoMgsImportResult
            do {
                imported = try await MetagenomicsImportService.importNaoMgs(
                    inputURL: inputURL,
                    outputDirectory: outputDirectory,
                    sampleName: sampleName,
                    fetchReferences: fetchReferences,
                    preferredName: sampleName
                ) { progress, message in
                    guard !globalOptions.quiet else { return }
                    print(String(format: "[%3.0f%%] %@", progress * 100, message))
                }
            } catch {
                print(formatter.error(error.localizedDescription))
                throw ExitCode.failure
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
    /// Parses `*_blast_concatenated.csv` and writes a `manifest.json` summary
    /// into an `nvd-{experiment}` bundle directory.
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
                throw ExitCode.failure
            }

            // Locate blast_concatenated.csv
            let labkeyDir = inputURL.appendingPathComponent("05_labkey_bundling", isDirectory: true)
            guard FileManager.default.fileExists(atPath: labkeyDir.path) else {
                print(formatter.error("Expected 05_labkey_bundling/ inside: \(inputPath)"))
                throw ExitCode.failure
            }

            let labkeyContents = try FileManager.default.contentsOfDirectory(
                at: labkeyDir,
                includingPropertiesForKeys: nil
            )
            guard let csvURL = labkeyContents.first(where: { $0.lastPathComponent.hasSuffix("_blast_concatenated.csv") }) else {
                print(formatter.error("No *_blast_concatenated.csv found in 05_labkey_bundling/"))
                throw ExitCode.failure
            }

            if !globalOptions.quiet {
                print(formatter.header("NVD Import"))
                print("")
                print(formatter.info("Parsing \(csvURL.lastPathComponent)..."))
            }

            let parser = NvdResultParser()
            let result = try await parser.parse(at: csvURL) { lineCount in
                if lineCount % 5000 == 0 && !globalOptions.quiet {
                    print(String(format: "[%3.0f%%] Parsed %d rows", 0.0, lineCount))
                }
            }

            let outputDirectory: URL
            if let dir = outputDir {
                outputDirectory = URL(fileURLWithPath: dir)
            } else {
                outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            }

            let bundleName = name ?? "nvd-\(result.experiment.isEmpty ? inputURL.lastPathComponent : result.experiment)"
            let bundleDir = outputDirectory.appendingPathComponent(bundleName, isDirectory: true)
            try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

            // Build per-sample summaries
            var perSampleHits: [String: Int] = [:]
            var perSampleContigs: [String: Set<String>] = [:]
            var perSampleTotalReads: [String: Int] = [:]
            for hit in result.hits {
                perSampleHits[hit.sampleId, default: 0] += 1
                perSampleContigs[hit.sampleId, default: []].insert(hit.qseqid)
                if perSampleTotalReads[hit.sampleId] == nil {
                    perSampleTotalReads[hit.sampleId] = hit.totalReads
                }
            }

            let sampleSummaries = result.sampleIds.sorted().map { sampleId in
                NvdSampleSummary(
                    sampleId: sampleId,
                    contigCount: perSampleContigs[sampleId]?.count ?? 0,
                    hitCount: perSampleHits[sampleId] ?? 0,
                    totalReads: perSampleTotalReads[sampleId] ?? 0,
                    bamRelativePath: "bam/\(sampleId).filtered.bam",
                    fastaRelativePath: "fasta/\(sampleId).human_virus.fasta"
                )
            }

            let topContigs: [NvdContigRow] = result.hits
                .filter { $0.hitRank == 1 }
                .prefix(200)
                .map { hit in
                    NvdContigRow(
                        sampleId: hit.sampleId,
                        qseqid: hit.qseqid,
                        qlen: hit.qlen,
                        adjustedTaxidName: hit.adjustedTaxidName,
                        adjustedTaxidRank: hit.adjustedTaxidRank,
                        sseqid: hit.sseqid,
                        stitle: hit.stitle,
                        pident: hit.pident,
                        evalue: hit.evalue,
                        bitscore: hit.bitscore,
                        mappedReads: hit.mappedReads,
                        readsPerBillion: hit.readsPerBillion
                    )
                }

            let manifest = NvdManifest(
                experiment: result.experiment,
                sampleCount: result.sampleIds.count,
                contigCount: Set(result.hits.map { "\($0.sampleId)\u{1F}\($0.qseqid)" }).count,
                hitCount: result.hits.count,
                blastDbVersion: result.hits.first?.blastDbVersion,
                snakemakeRunId: result.hits.first?.snakemakeRunId,
                sourceDirectoryPath: inputURL.path,
                samples: sampleSummaries,
                cachedTopContigs: topContigs
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let manifestData = try encoder.encode(manifest)
            let manifestURL = bundleDir.appendingPathComponent("manifest.json")
            try manifestData.write(to: manifestURL, options: .atomic)

            if !globalOptions.quiet {
                print(formatter.keyValueTable([
                    ("Experiment", result.experiment.isEmpty ? "(none)" : result.experiment),
                    ("Total hits", String(result.hits.count)),
                    ("Samples", String(result.sampleIds.count)),
                    ("Output", bundleDir.lastPathComponent),
                ]))
                print("")
                print(formatter.success("NVD import complete: \(bundleName)"))
            }
        }
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

/// Scans a directory for files matching the given extensions.
private func scanForFiles(in directory: URL, extensions: [String]) -> [URL] {
    let fm = FileManager.default
    guard let contents = try? fm.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    let lowercasedExts = Set(extensions.map { $0.lowercased() })
    return contents.filter { url in
        var ext = url.pathExtension.lowercased()
        // Handle double extensions like .tsv.gz.
        if ext == "gz" {
            ext = url.deletingPathExtension().pathExtension.lowercased()
        }
        return lowercasedExts.contains(ext) || lowercasedExts.contains(url.pathExtension.lowercased())
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
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
