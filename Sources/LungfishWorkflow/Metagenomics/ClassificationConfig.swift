// ClassificationConfig.swift - Configuration for a Kraken2 classification run
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - ClassificationConfig

/// Configuration for a single Kraken2 classification run.
///
/// Captures all parameters needed to execute `kraken2` and optionally `bracken`:
/// input files, database selection, tool-level flags, and output location.
///
/// ## Goals
///
/// The ``goal`` property determines post-classification behavior:
///
/// | Goal       | Pipeline |
/// |-----------|---------|
/// | `.classify` | Kraken2 only |
/// | `.profile`  | Kraken2 + Bracken abundance estimation |
/// | `.extract`  | Kraken2, then present taxonomy extraction sheet |
///
/// ## Presets
///
/// Three sensitivity presets map to recommended parameter combinations:
///
/// | Preset    | Confidence | Min Hit Groups | Use Case |
/// |-----------|-----------|----------------|----------|
/// | Sensitive | 0.0       | 1              | Exploratory analysis, maximise recall |
/// | Balanced  | 0.2       | 2              | General-purpose classification |
/// | Precise   | 0.5       | 3              | High-confidence calls, minimise FP |
///
/// ## Thread Safety
///
/// `ClassificationConfig` is a value type conforming to `Sendable` and `Codable`,
/// safe to pass across isolation boundaries.
public struct ClassificationConfig: Sendable, Codable, Equatable {

    // MARK: - Goal

    /// The user's high-level intent for the classification run.
    ///
    /// Determines which pipeline steps execute after Kraken2 completes:
    ///
    /// | Goal       | Pipeline |
    /// |-----------|---------|
    /// | `.classify` | Kraken2 only |
    /// | `.profile`  | Kraken2 + Bracken abundance estimation |
    /// | `.extract`  | Kraken2, then present taxonomy extraction sheet |
    public enum Goal: String, Sendable, Codable, CaseIterable {
        /// Assign each read to a taxon using Kraken2 only.
        case classify

        /// Estimate community abundance using Kraken2 + Bracken.
        case profile

        /// Classify reads, then immediately present extraction UI.
        case extract
    }

    /// The user-selected goal for this run.
    ///
    /// Defaults to `.classify` for backward compatibility.
    public let goal: Goal

    // MARK: - Input

    /// One or two FASTQ input files.
    ///
    /// For paired-end data, supply exactly two files (R1, R2). For single-end,
    /// supply one file.
    public let inputFiles: [URL]

    /// Whether the input is paired-end.
    ///
    /// When `true`, ``inputFiles`` must contain exactly two elements and
    /// the `--paired` flag is passed to `kraken2`.
    public let isPairedEnd: Bool

    // MARK: - Database

    /// Display name of the database, matching a ``MetagenomicsDatabaseInfo`` entry.
    public let databaseName: String

    /// Database version or build date (e.g., "20240904").
    ///
    /// This is critical for reproducibility — knowing which exact database was used
    /// allows results to be compared or reproduced years later.
    public let databaseVersion: String

    /// Resolved filesystem path to the Kraken2 database directory.
    public let databasePath: URL

    // MARK: - Kraken2 Parameters

    /// Confidence threshold for Kraken2 classification (0.0 to 1.0).
    ///
    /// Higher values produce fewer but more confident assignments.
    /// Passed as `--confidence <value>`.
    public var confidence: Double

    /// Minimum number of hit groups required for a classification.
    ///
    /// Passed as `--minimum-hit-groups <value>`.
    public var minimumHitGroups: Int

    /// Number of threads for Kraken2 to use.
    ///
    /// Passed as `--threads <value>`.
    public var threads: Int

    /// Whether to use memory-mapped I/O instead of loading the database into RAM.
    ///
    /// Enable when the database exceeds available physical memory. Significantly
    /// slower but avoids swap thrashing. Passed as `--memory-mapping`.
    public var memoryMapping: Bool

    /// Whether to use Kraken2's quick mode (first classified label only).
    ///
    /// Faster but less accurate. Passed as `--quick`.
    public var quickMode: Bool

    // MARK: - Output

    /// Directory where output files are written.
    ///
    /// The pipeline creates:
    /// - `classification.kreport` (Kraken2 report)
    /// - `classification.kraken` (per-read output)
    /// - `classification.bracken` (Bracken output, if profiling)
    /// - `.lungfish-provenance.json` (provenance sidecar)
    public let outputDirectory: URL

    // MARK: - Initialization

    /// Creates a classification configuration with explicit parameters.
    ///
    /// - Parameters:
    ///   - goal: The classification goal (default: `.classify`).
    ///   - inputFiles: FASTQ input file(s).
    ///   - isPairedEnd: Whether the input is paired-end.
    ///   - databaseName: Name of the database in the registry.
    ///   - databasePath: Resolved path to the database directory.
    ///   - confidence: Kraken2 confidence threshold (default: 0.0).
    ///   - minimumHitGroups: Minimum hit groups (default: 2).
    ///   - threads: Thread count (default: 4).
    ///   - memoryMapping: Use memory-mapped I/O (default: false).
    ///   - quickMode: Use quick mode (default: false).
    ///   - outputDirectory: Output directory for results.
    public init(
        goal: Goal = .classify,
        inputFiles: [URL],
        isPairedEnd: Bool,
        databaseName: String,
        databaseVersion: String = "",
        databasePath: URL,
        confidence: Double = 0.0,
        minimumHitGroups: Int = 2,
        threads: Int = 4,
        memoryMapping: Bool = false,
        quickMode: Bool = false,
        outputDirectory: URL
    ) {
        self.goal = goal
        self.inputFiles = inputFiles
        self.isPairedEnd = isPairedEnd
        self.databaseName = databaseName
        self.databaseVersion = databaseVersion
        self.databasePath = databasePath
        self.confidence = confidence
        self.minimumHitGroups = minimumHitGroups
        self.threads = threads
        self.memoryMapping = memoryMapping
        self.quickMode = quickMode
        self.outputDirectory = outputDirectory
    }

    // MARK: - Presets

    /// Sensitivity presets that map to concrete Kraken2/Bracken parameter sets.
    public enum Preset: String, Sendable, Codable, CaseIterable {
        /// Maximum recall: confidence=0.0, minHitGroups=1.
        case sensitive

        /// General-purpose: confidence=0.2, minHitGroups=2.
        case balanced

        /// High-confidence: confidence=0.5, minHitGroups=3.
        case precise
    }

    /// Creates a configuration from a preset.
    ///
    /// The preset sets ``confidence`` and ``minimumHitGroups``; all other
    /// parameters are supplied explicitly.
    ///
    /// - Parameters:
    ///   - preset: The sensitivity preset to apply.
    ///   - goal: The classification goal (default: `.classify`).
    ///   - inputFiles: FASTQ input file(s).
    ///   - isPairedEnd: Whether the input is paired-end.
    ///   - databaseName: Name of the database.
    ///   - databasePath: Path to the database directory.
    ///   - threads: Thread count (default: 4).
    ///   - memoryMapping: Use memory-mapped I/O (default: false).
    ///   - quickMode: Use quick mode (default: false).
    ///   - outputDirectory: Output directory.
    /// - Returns: A fully configured ``ClassificationConfig``.
    public static func fromPreset(
        _ preset: Preset,
        goal: Goal = .classify,
        inputFiles: [URL],
        isPairedEnd: Bool,
        databaseName: String,
        databaseVersion: String = "",
        databasePath: URL,
        threads: Int = 4,
        memoryMapping: Bool = false,
        quickMode: Bool = false,
        outputDirectory: URL
    ) -> ClassificationConfig {
        let (confidence, minHitGroups) = preset.parameters
        return ClassificationConfig(
            goal: goal,
            inputFiles: inputFiles,
            isPairedEnd: isPairedEnd,
            databaseName: databaseName,
            databaseVersion: databaseVersion,
            databasePath: databasePath,
            confidence: confidence,
            minimumHitGroups: minHitGroups,
            threads: threads,
            memoryMapping: memoryMapping,
            quickMode: quickMode,
            outputDirectory: outputDirectory
        )
    }

    // MARK: - Computed Properties

    /// The output path for the Kraken2 report file.
    public var reportURL: URL {
        outputDirectory.appendingPathComponent("classification.kreport")
    }

    /// The output path for the per-read Kraken2 output file.
    public var outputURL: URL {
        outputDirectory.appendingPathComponent("classification.kraken")
    }

    /// The output path for the Bracken output file.
    public var brackenURL: URL {
        outputDirectory.appendingPathComponent("classification.bracken")
    }

    // MARK: - Argument Building

    /// Builds the command-line arguments for `kraken2`.
    ///
    /// This produces a complete argument list suitable for
    /// ``CondaManager/runTool(name:arguments:environment:workingDirectory:timeout:)``.
    ///
    /// - Returns: An array of argument strings (excluding the tool name itself).
    public func kraken2Arguments() -> [String] {
        var args: [String] = []

        // Database
        args += ["--db", databasePath.path]

        // Threads
        args += ["--threads", String(threads)]

        // Confidence
        args += ["--confidence", String(confidence)]

        // Minimum hit groups
        args += ["--minimum-hit-groups", String(minimumHitGroups)]

        // Output files
        args += ["--output", outputURL.path]
        args += ["--report", reportURL.path]

        // Optional flags
        if memoryMapping {
            args.append("--memory-mapping")
        }

        if quickMode {
            args.append("--quick")
        }

        if isPairedEnd {
            args.append("--paired")
        }

        // Use report minimizer data for bracken compatibility
        args.append("--report-minimizer-data")

        // Input files (must be last)
        for file in inputFiles {
            args.append(file.path)
        }

        return args
    }

    /// Formats the kraken2 command as a shell-ready string.
    ///
    /// Produces a multi-line command with backslash continuations for
    /// readability. Each argument pair appears on its own line.
    ///
    /// - Returns: A complete `kraken2 ...` command string.
    public func kraken2CommandString() -> String {
        let args = kraken2Arguments()
        let escaped = args.map { classificationShellEscape($0) }
        return "kraken2 " + escaped.joined(separator: " \\\n  ")
    }
}

// MARK: - Shell Escaping

/// Escapes a string for safe use in a POSIX shell command.
///
/// Wraps the value in single quotes if it contains characters that
/// require escaping (spaces, parentheses, dollar signs, etc.).
/// Single quotes within the value are escaped as `'\''`.
///
/// This is a module-level free function to avoid `@MainActor` isolation
/// issues when called from `@Sendable` contexts.
///
/// - Parameter value: The raw string to escape.
/// - Returns: A shell-safe representation of the string.
func classificationShellEscape(_ value: String) -> String {
    // Characters that are safe unquoted in POSIX shells
    let safeCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-_./:=@+,"))
    if !value.isEmpty && value.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
        return value
    }
    // Wrap in single quotes, escaping any embedded single quotes
    let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
    return "'\(escaped)'"
}

// MARK: - Preset Parameters

extension ClassificationConfig.Preset {

    /// Returns the (confidence, minimumHitGroups) tuple for this preset.
    public var parameters: (confidence: Double, minimumHitGroups: Int) {
        switch self {
        case .sensitive:
            return (confidence: 0.0, minimumHitGroups: 1)
        case .balanced:
            return (confidence: 0.2, minimumHitGroups: 2)
        case .precise:
            return (confidence: 0.5, minimumHitGroups: 3)
        }
    }
}

// MARK: - ClassificationConfigError

/// Errors produced during configuration validation.
public enum ClassificationConfigError: Error, LocalizedError, Sendable {

    /// No input files were provided.
    case noInputFiles

    /// Paired-end mode requires exactly two input files.
    case pairedEndRequiresTwoFiles(got: Int)

    /// An input file does not exist at the specified path.
    case inputFileNotFound(URL)

    /// The database directory does not exist or is incomplete.
    case databaseNotFound(URL)

    /// The database is missing required Kraken2 files.
    case databaseMissingFiles(URL, missing: [String])

    /// The confidence value is out of range.
    case invalidConfidence(Double)

    /// The output directory could not be created.
    case outputDirectoryCreationFailed(URL, Error)

    public var errorDescription: String? {
        switch self {
        case .noInputFiles:
            return "No input FASTQ files specified"
        case .pairedEndRequiresTwoFiles(let got):
            return "Paired-end mode requires exactly 2 input files, got \(got)"
        case .inputFileNotFound(let url):
            return "Input file not found: \(url.lastPathComponent)"
        case .databaseNotFound(let url):
            return "Database directory not found: \(url.path)"
        case .databaseMissingFiles(let url, let missing):
            return "Database at \(url.path) is missing: \(missing.joined(separator: ", "))"
        case .invalidConfidence(let value):
            return "Confidence must be between 0.0 and 1.0, got \(value)"
        case .outputDirectoryCreationFailed(let url, let error):
            return "Cannot create output directory at \(url.path): \(error.localizedDescription)"
        }
    }
}

// MARK: - Validation

extension ClassificationConfig {

    /// Validates this configuration, checking file existence and parameter ranges.
    ///
    /// - Throws: ``ClassificationConfigError`` describing the first validation failure.
    public func validate() throws {
        // Input files
        guard !inputFiles.isEmpty else {
            throw ClassificationConfigError.noInputFiles
        }

        if isPairedEnd && inputFiles.count != 2 {
            throw ClassificationConfigError.pairedEndRequiresTwoFiles(got: inputFiles.count)
        }

        let fm = FileManager.default
        for file in inputFiles {
            guard fm.fileExists(atPath: file.path) else {
                throw ClassificationConfigError.inputFileNotFound(file)
            }
        }

        // Confidence range
        guard confidence >= 0.0 && confidence <= 1.0 else {
            throw ClassificationConfigError.invalidConfidence(confidence)
        }

        // Database
        guard fm.fileExists(atPath: databasePath.path) else {
            throw ClassificationConfigError.databaseNotFound(databasePath)
        }

        let requiredFiles = MetagenomicsDatabaseRegistry.requiredKraken2Files
        let missingFiles = requiredFiles.filter { filename in
            !fm.fileExists(atPath: databasePath.appendingPathComponent(filename).path)
        }
        if !missingFiles.isEmpty {
            throw ClassificationConfigError.databaseMissingFiles(databasePath, missing: missingFiles)
        }
    }
}
