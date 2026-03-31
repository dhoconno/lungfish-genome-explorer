// AssembleCommand.swift - CLI command for de novo assembly with SPAdes
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishWorkflow
import LungfishIO
import LungfishCore

/// Run de novo genome assembly using SPAdes.
///
/// ## Examples
///
/// ```
/// # Assemble with bacterial isolate preset
/// lungfish assemble sample_R1.fastq sample_R2.fastq --paired --preset isolate
///
/// # Metagenome assembly with custom resources
/// lungfish assemble reads.fastq --preset meta --memory 32 --threads 16
///
/// # Viral assembly with custom output directory
/// lungfish assemble R1.fq R2.fq --paired --preset viral -o my-assembly/
/// ```
struct AssembleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "assemble",
        abstract: "Run de novo genome assembly with SPAdes",
        discussion: """
            Assemble reads into contigs and scaffolds using SPAdes. Supports
            bacterial isolate, metagenome, plasmid, RNA, and biosynthetic modes.
            Requires Apple Containers runtime (macOS 26+).
            """
    )

    // MARK: - Arguments

    @Argument(help: "Input FASTQ file(s). Provide two files for paired-end.")
    var fastqFiles: [String]

    @Option(name: .customLong("preset"), help: "Assembly preset: isolate, meta, viral (default: isolate)")
    var preset: AssemblyPresetArgument = .isolate

    @Option(name: .customLong("mode"), help: "SPAdes mode: isolate, meta, plasmid, rna, bio")
    var mode: String?

    @Option(name: [.customLong("output-dir"), .customShort("o")], help: "Output directory (default: ./assembly-<name>)")
    var outputDir: String?

    @Option(name: .customLong("name"), help: "Project name for the assembly")
    var projectName: String?

    @Flag(name: .customLong("paired"), help: "Input files are paired-end reads")
    var pairedEnd: Bool = false

    @Option(name: .customLong("memory"), help: "Maximum memory in GB (default: 8)")
    var memory: Int = 8

    @Option(name: .customLong("threads"), help: "Number of threads (default: 4)")
    var threads: Int = 4

    @Option(name: .customLong("kmers"), help: "Custom k-mer sizes (comma-separated, e.g. '21,33,55')")
    var kmers: String?

    @Flag(name: .customLong("no-error-correction"), help: "Skip error correction step")
    var noErrorCorrection: Bool = false

    @Flag(name: .customLong("careful"), help: "Enable careful mode (mismatch correction)")
    var careful: Bool = false

    @Option(name: .customLong("min-contig-length"), help: "Minimum contig length in bp (default: 500)")
    var minContigLength: Int = 500

    @OptionGroup var globalOptions: GlobalOptions

    // MARK: - Execution

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        // Resolve input files
        let inputURLs = fastqFiles.map { path -> URL in
            var url = URL(fileURLWithPath: path)
            if url.pathExtension.lowercased() == "gz" {
                url = url.deletingPathExtension()
            }
            return URL(fileURLWithPath: path)
        }
        for url in inputURLs {
            guard FileManager.default.fileExists(atPath: url.path) else {
                print(formatter.error("Input file not found: \(url.path)"))
                throw ExitCode.failure
            }
        }

        // Resolve mode from preset or explicit flag
        let spadesMode: SPAdesMode
        if let modeStr = mode {
            guard let m = SPAdesMode(rawValue: modeStr) else {
                print(formatter.error("Unknown SPAdes mode: \(modeStr)"))
                print(formatter.info("Valid modes: isolate, meta, plasmid, rna, bio"))
                throw ExitCode.failure
            }
            spadesMode = m
        } else {
            spadesMode = preset.toSPAdesMode()
        }

        // Resolve project name
        let name = projectName ?? inputURLs.first?.deletingPathExtension().lastPathComponent ?? "assembly"

        // Resolve output directory
        let outputDirectory: URL
        if let dir = outputDir {
            outputDirectory = URL(fileURLWithPath: dir)
        } else {
            outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("assembly-\(name)")
        }

        // Parse k-mers
        let kmerSizes: [Int]?
        if let kmersStr = kmers {
            kmerSizes = kmersStr.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if kmerSizes?.isEmpty ?? true {
                print(formatter.error("Invalid k-mer sizes: \(kmersStr)"))
                throw ExitCode.failure
            }
        } else {
            kmerSizes = nil
        }

        // Split input files into forward/reverse/unpaired
        let forwardReads: [URL]
        let reverseReads: [URL]
        let unpairedReads: [URL]
        if pairedEnd && inputURLs.count == 2 {
            forwardReads = [inputURLs[0]]
            reverseReads = [inputURLs[1]]
            unpairedReads = []
        } else {
            forwardReads = []
            reverseReads = []
            unpairedReads = inputURLs
        }

        // Build config
        let config = SPAdesAssemblyConfig(
            mode: spadesMode,
            forwardReads: forwardReads,
            reverseReads: reverseReads,
            unpairedReads: unpairedReads,
            kmerSizes: kmerSizes,
            memoryGB: memory,
            threads: threads,
            minContigLength: minContigLength,
            skipErrorCorrection: noErrorCorrection,
            careful: careful && spadesMode != .isolate,
            outputDirectory: outputDirectory,
            projectName: name
        )

        // Print configuration
        print(formatter.header("SPAdes Assembly"))
        print("")
        print(formatter.keyValueTable([
            ("Input files", inputURLs.map(\.lastPathComponent).joined(separator: ", ")),
            ("Paired-end", pairedEnd ? "yes" : "no"),
            ("Mode", spadesMode.displayName),
            ("Memory", "\(memory) GB"),
            ("Threads", "\(threads)"),
            ("Error correction", noErrorCorrection ? "no" : "yes"),
            ("Careful mode", careful ? "yes" : "no"),
            ("K-mer sizes", kmers ?? "auto"),
            ("Min contig", "\(minContigLength) bp"),
            ("Output", outputDirectory.path),
        ]))
        print("")

        // Create container runtime
        guard let runtime = await NewContainerRuntimeFactory.createRuntime() else {
            print(formatter.error("No container runtime available. SPAdes requires Apple Containers (macOS 26+)."))
            throw ExitCode.failure
        }

        // Run pipeline
        let pipeline = SPAdesAssemblyPipeline()
        let result = try await pipeline.run(
            config: config,
            runtime: runtime as! AppleContainerRuntime
        ) { fraction, message in
            if !globalOptions.quiet {
                print("\r\(formatter.info(message))", terminator: "")
            }
        }

        // Clear progress line
        print("")
        print("")

        // Print results
        let stats = result.statistics
        print(formatter.header("Assembly Results"))
        print("")
        print(formatter.keyValueTable([
            ("Contigs", "\(stats.contigCount)"),
            ("Total length", "\(stats.totalLengthBP) bp"),
            ("N50", "\(stats.n50) bp"),
            ("Largest contig", "\(stats.largestContigBP) bp"),
            ("GC content", String(format: "%.1f%%", stats.gcPercent)),
        ]))
        print("")

        // Print output files
        print(formatter.header("Output Files"))
        print("  Contigs:    \(formatter.path(result.contigsPath.path))")
        if let scaffolds = result.scaffoldsPath {
            print("  Scaffolds:  \(formatter.path(scaffolds.path))")
        }
        print("")
        print(formatter.success("Assembly completed in \(String(format: "%.1f", result.wallTimeSeconds))s"))
    }
}

// MARK: - AssemblyPresetArgument

/// ArgumentParser-compatible wrapper for assembly presets.
enum AssemblyPresetArgument: String, ExpressibleByArgument, CaseIterable {
    case isolate
    case meta
    case viral

    func toSPAdesMode() -> SPAdesMode {
        switch self {
        case .isolate: return .isolate
        case .meta: return .meta
        case .viral: return .isolate  // Viral uses isolate mode with small resources
        }
    }
}
