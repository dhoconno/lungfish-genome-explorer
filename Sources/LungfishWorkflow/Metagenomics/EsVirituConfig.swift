// EsVirituConfig.swift - Configuration for an EsViritu viral detection run
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - EsVirituConfig

/// Configuration for a single EsViritu viral metagenomics detection run.
///
/// Captures all parameters needed to execute the EsViritu pipeline: input
/// FASTQ files, database location, quality control settings, and output paths.
///
/// ## EsViritu Overview
///
/// EsViritu is a viral metagenomics tool that detects and characterizes
/// viruses from sequencing data. It performs:
/// - Quality filtering (via fastp)
/// - Viral read detection and assembly
/// - Taxonomic profiling of detected viruses
/// - Coverage analysis across viral genomes
///
/// ## Input Modes
///
/// | Mode      | Files | Description |
/// |-----------|-------|-------------|
/// | Unpaired  | 1     | Single-end or interleaved reads |
/// | Paired    | 2     | Forward (R1) and reverse (R2) reads |
///
/// ## Thread Safety
///
/// `EsVirituConfig` is a value type conforming to `Sendable` and `Codable`,
/// safe to pass across isolation boundaries.
public struct EsVirituConfig: Sendable, Codable, Equatable {

    // MARK: - Input

    /// One or two FASTQ input files.
    ///
    /// For paired-end data, supply exactly two files (R1, R2). For single-end
    /// or interleaved reads, supply one file.
    public var inputFiles: [URL]

    /// Whether the input is paired-end.
    ///
    /// When `true`, ``inputFiles`` must contain exactly two elements and
    /// the `-p paired` flag is passed to EsViritu.
    public let isPairedEnd: Bool

    /// Sample name used for output file naming.
    ///
    /// EsViritu uses this as the prefix for all output files (e.g.,
    /// `<sampleName>.detected_virus.info.tsv`).
    public let sampleName: String

    // MARK: - Output

    /// Directory where output files are written.
    ///
    /// The pipeline creates multiple output files including detection results,
    /// assembly summaries, taxonomic profiles, and coverage data.
    public var outputDirectory: URL

    // MARK: - Database

    /// Path to the EsViritu database directory.
    ///
    /// This directory contains the curated viral reference database used
    /// for detection and classification. Downloaded via
    /// ``EsVirituDatabaseManager``.
    public let databasePath: URL

    // MARK: - Parameters

    /// Whether to run fastp quality control before detection.
    ///
    /// When enabled, reads are quality-filtered and adapter-trimmed before
    /// viral detection. Recommended for raw sequencing data.
    public var qualityFilter: Bool

    /// Minimum read length after quality filtering.
    ///
    /// Reads shorter than this threshold are discarded during quality
    /// filtering. Only applies when ``qualityFilter`` is `true`.
    public var minReadLength: Int

    /// Number of CPU threads for EsViritu to use.
    ///
    /// Passed as part of the command-line arguments. Defaults to the
    /// number of active processor cores on the system.
    public var threads: Int

    // MARK: - Initialization

    /// Creates an EsViritu configuration with explicit parameters.
    ///
    /// - Parameters:
    ///   - inputFiles: FASTQ input file(s).
    ///   - isPairedEnd: Whether the input is paired-end.
    ///   - sampleName: Sample name for output file prefixes.
    ///   - outputDirectory: Output directory for results.
    ///   - databasePath: Path to the EsViritu database directory.
    ///   - qualityFilter: Run fastp QC (default: true).
    ///   - minReadLength: Minimum read length filter (default: 100).
    ///   - threads: Thread count (default: system processor count).
    public init(
        inputFiles: [URL],
        isPairedEnd: Bool,
        sampleName: String,
        outputDirectory: URL,
        databasePath: URL,
        qualityFilter: Bool = true,
        minReadLength: Int = 100,
        threads: Int = ProcessInfo.processInfo.activeProcessorCount
    ) {
        self.inputFiles = inputFiles
        self.isPairedEnd = isPairedEnd
        self.sampleName = sampleName
        self.outputDirectory = outputDirectory
        self.databasePath = databasePath
        self.qualityFilter = qualityFilter
        self.minReadLength = minReadLength
        self.threads = threads
    }

    // MARK: - Computed Output URLs

    /// Path to the detected virus information TSV.
    ///
    /// Contains per-virus detection results including read counts,
    /// genome coverage, and classification confidence.
    public var detectionOutputURL: URL {
        outputDirectory.appendingPathComponent("\(sampleName).detected_virus.info.tsv")
    }

    /// Path to the assembly summary TSV.
    ///
    /// Contains de novo assembly results for detected viral contigs,
    /// including contig lengths and coverage statistics.
    public var assemblyOutputURL: URL {
        outputDirectory.appendingPathComponent("\(sampleName).detected_virus.assembly_summary.tsv")
    }

    /// Path to the taxonomic profile TSV.
    ///
    /// Contains the community-level taxonomic profile of all detected
    /// viruses with relative abundance estimates.
    public var taxProfileURL: URL {
        outputDirectory.appendingPathComponent("\(sampleName).tax_profile.tsv")
    }

    /// Path to the virus coverage windows TSV.
    ///
    /// Contains per-window coverage depth across detected viral genomes,
    /// useful for identifying partial vs. complete genome recovery.
    public var coverageURL: URL {
        outputDirectory.appendingPathComponent("\(sampleName).virus_coverage_windows.tsv")
    }

    /// Path to the EsViritu run log.
    ///
    /// Contains detailed logging output from the pipeline execution,
    /// useful for debugging and reproducibility.
    public var logURL: URL {
        outputDirectory.appendingPathComponent("\(sampleName)_esviritu.log")
    }

    /// Path to the saved parameters YAML file.
    ///
    /// EsViritu records all parameters used for the run in this file
    /// for reproducibility.
    public var paramsURL: URL {
        outputDirectory.appendingPathComponent("\(sampleName)_esviritu.params.yaml")
    }

    // MARK: - Argument Building

    /// Builds the command-line arguments for the `EsViritu` tool.
    ///
    /// This produces a complete argument list suitable for
    /// ``CondaManager/runTool(name:arguments:environment:workingDirectory:timeout:environmentVariables:)``.
    ///
    /// - Returns: An array of argument strings (excluding the tool name itself).
    public func esVirituArguments() -> [String] {
        var args: [String] = []

        // Read input
        args += ["-r"]
        for file in inputFiles {
            args.append(file.path)
        }

        // Sample name
        args += ["-s", sampleName]

        // Output directory
        args += ["-o", outputDirectory.path]

        // Paired-end mode: "unpaired" (default) or "paired" (requires 2 files after -r)
        args += ["-p", isPairedEnd ? "paired" : "unpaired"]

        // Thread count
        args += ["-t", String(threads)]

        // Quality filtering (fastp): True or False
        args += ["-q", qualityFilter ? "True" : "False"]

        // Database path (also set via ESVIRITU_DB env var as fallback)
        args += ["--db", databasePath.path]

        // Keep intermediate BAM files for alignment inspection in the viewer.
        // The final BAM ({SAMPLE}.third.filt.sorted.bam) shows reads mapped
        // to detected viral contigs and is viewable in Lungfish's BAM viewer.
        args += ["--keep", "True"]

        return args
    }

    /// Formats the EsViritu command as a shell-ready string.
    ///
    /// Produces a multi-line command with backslash continuations for
    /// readability. Each argument pair appears on its own line.
    ///
    /// - Returns: A complete `EsViritu ...` command string.
    public func commandString() -> String {
        let args = esVirituArguments()
        let escaped = args.map { shellEscape($0) }
        return "EsViritu " + escaped.joined(separator: " \\\n  ")
    }
}

// MARK: - EsVirituConfigError

/// Errors produced during EsViritu configuration validation.
public enum EsVirituConfigError: Error, LocalizedError, Sendable {

    /// No input files were provided.
    case noInputFiles

    /// Paired-end mode requires exactly two input files.
    case pairedEndRequiresTwoFiles(got: Int)

    /// An input file does not exist at the specified path.
    case inputFileNotFound(URL)

    /// The database directory does not exist.
    case databaseNotFound(URL)

    /// The sample name is empty.
    case emptySampleName

    /// The minimum read length is invalid (must be positive).
    case invalidMinReadLength(Int)

    /// The output directory could not be created.
    case outputDirectoryCreationFailed(URL, Error)

    /// An input path is a directory, not a FASTQ file.
    case inputPathIsDirectory(URL)

    public var errorDescription: String? {
        switch self {
        case .noInputFiles:
            return "No input FASTQ files specified"
        case .pairedEndRequiresTwoFiles(let got):
            return "Paired-end mode requires exactly 2 input files, got \(got)"
        case .inputFileNotFound(let url):
            return "Input file not found: \(url.lastPathComponent)"
        case .inputPathIsDirectory(let url):
            return "Input path is a directory, expected FASTQ file: \(url.lastPathComponent)"
        case .databaseNotFound(let url):
            return "EsViritu database directory not found: \(url.path)"
        case .emptySampleName:
            return "Sample name cannot be empty"
        case .invalidMinReadLength(let value):
            return "Minimum read length must be positive, got \(value)"
        case .outputDirectoryCreationFailed(let url, let error):
            return "Cannot create output directory at \(url.path): \(error.localizedDescription)"
        }
    }
}

// MARK: - Validation

extension EsVirituConfig {

    /// Validates this configuration, checking file existence and parameter ranges.
    ///
    /// - Throws: ``EsVirituConfigError`` describing the first validation failure.
    public func validate() throws {
        // Input files
        guard !inputFiles.isEmpty else {
            throw EsVirituConfigError.noInputFiles
        }

        if isPairedEnd && inputFiles.count != 2 {
            throw EsVirituConfigError.pairedEndRequiresTwoFiles(got: inputFiles.count)
        }

        let fm = FileManager.default
        for file in inputFiles {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
                throw EsVirituConfigError.inputFileNotFound(file)
            }
            if isDirectory.boolValue {
                throw EsVirituConfigError.inputPathIsDirectory(file)
            }
        }

        // Sample name
        guard !sampleName.isEmpty else {
            throw EsVirituConfigError.emptySampleName
        }

        // Min read length
        guard minReadLength > 0 else {
            throw EsVirituConfigError.invalidMinReadLength(minReadLength)
        }

        // Database
        guard fm.fileExists(atPath: databasePath.path) else {
            throw EsVirituConfigError.databaseNotFound(databasePath)
        }
    }
}
