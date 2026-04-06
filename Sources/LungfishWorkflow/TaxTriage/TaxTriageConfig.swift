// TaxTriageConfig.swift - Configuration for TaxTriage Nextflow pipeline
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

// MARK: - TaxTriageConfig

/// Configuration for a TaxTriage metagenomic classification pipeline run.
///
/// TaxTriage is a Nextflow DSL2 pipeline from JHU APL that performs end-to-end
/// metagenomic classification with confidence scoring. This configuration captures
/// all parameters needed to generate the input samplesheet and execute the pipeline
/// via Nextflow.
///
/// ## Sequencing Platforms
///
/// | Platform     | Description |
/// |-------------|-------------|
/// | `.illumina` | Short-read paired or single-end Illumina data |
/// | `.oxford`   | Oxford Nanopore long-read data |
/// | `.pacbio`   | PacBio long-read data |
///
/// ## Thread Safety
///
/// `TaxTriageConfig` is a value type conforming to `Sendable` and `Codable`,
/// safe to pass across isolation boundaries.
///
/// ## Example
///
/// ```swift
/// let sample = TaxTriageSample(
///     sampleId: "MySample",
///     fastq1: URL(fileURLWithPath: "/data/R1.fastq.gz"),
///     fastq2: URL(fileURLWithPath: "/data/R2.fastq.gz"),
///     platform: .illumina
/// )
/// let config = TaxTriageConfig(
///     samples: [sample],
///     platform: .illumina,
///     outputDirectory: URL(fileURLWithPath: "/results/taxtriage")
/// )
/// ```
public struct TaxTriageConfig: Sendable, Codable, Equatable {

    // MARK: - Platform

    /// Sequencing platform used to generate the input reads.
    ///
    /// The platform determines which TaxTriage processing modules are activated.
    public enum Platform: String, Sendable, Codable, CaseIterable {
        /// Illumina short-read sequencing.
        case illumina = "ILLUMINA"

        /// Oxford Nanopore long-read sequencing.
        case oxford = "OXFORD"

        /// PacBio long-read sequencing.
        case pacbio = "PACBIO"

        /// Human-readable display name.
        public var displayName: String {
            switch self {
            case .illumina: return "Illumina"
            case .oxford: return "Oxford Nanopore"
            case .pacbio: return "PacBio"
            }
        }
    }

    // MARK: - Input

    /// Input samples for the pipeline.
    ///
    /// TaxTriage supports multiple samples in a single run. Each sample has
    /// its own FASTQ file(s) and platform specification.
    public var samples: [TaxTriageSample]

    /// Default sequencing platform for samples without explicit platform.
    public let platform: Platform

    // MARK: - Output

    /// Directory where TaxTriage writes all output files.
    ///
    /// Passed as `--outdir` to the Nextflow pipeline. The directory is created
    /// if it does not exist.
    public let outputDirectory: URL

    // MARK: - Database

    /// Path to an existing Kraken2 database for classification.
    ///
    /// If nil, TaxTriage downloads a default database. Reusing an already
    /// downloaded database avoids redundant downloads and is recommended.
    public let kraken2DatabasePath: URL?

    // MARK: - Parameters

    /// Classifiers to run (e.g., `["kraken2"]`).
    ///
    /// TaxTriage supports multiple classifier backends. Defaults to Kraken2 only.
    public var classifiers: [String]

    /// Number of top hits to report per sample.
    ///
    /// Passed as `--top_hits_count`. Default: 10.
    public var topHitsCount: Int

    /// Kraken2 confidence threshold (0.0 to 1.0).
    ///
    /// Higher values reduce false positives at the expense of sensitivity.
    /// Passed as `--k2_confidence`. Default: 0.2.
    public var k2Confidence: Double

    /// Taxonomic rank for reporting.
    ///
    /// Single-letter NCBI rank code. Passed as `--rank`. Default: "S" (species).
    public var rank: String

    /// Whether to skip genome assembly steps.
    ///
    /// Skipping assembly significantly reduces runtime for classification-only
    /// workflows. Passed as `--skip_assembly`. Default: true.
    public var skipAssembly: Bool

    /// Whether to skip Krona interactive visualization generation.
    ///
    /// Passed as `--skip_krona`. Default: false.
    public var skipKrona: Bool

    /// Maximum memory allocation for the pipeline.
    ///
    /// Nextflow resource string (e.g., "16.GB"). Passed as `--max_memory`.
    public var maxMemory: String

    /// Maximum number of CPUs for parallel tasks.
    ///
    /// Passed as `--max_cpus`. Default: available processor count.
    public var maxCpus: Int

    // MARK: - Nextflow Execution

    /// Nextflow profile to use (e.g., "docker", "conda").
    ///
    /// Determines the execution environment for pipeline processes.
    public var profile: String

    /// Optional container runtime override.
    ///
    /// When set, overrides the automatic container runtime detection.
    /// Use "docker" or "apple" for explicit control.
    public var containerRuntime: String?

    /// Nextflow pipeline revision (Git branch or tag).
    ///
    /// Passed as `-r` to Nextflow. Default: "main".
    public var revision: String

    // MARK: - Provenance

    /// URLs of the source FASTQ bundles that contributed samples to this run.
    ///
    /// For multi-sample batch runs, this captures the originating bundles so that
    /// sidebar grouping and cross-referencing can locate results. `nil` for legacy
    /// or single-bundle runs where the output is stored inside the bundle itself.
    public var sourceBundleURLs: [URL]?

    // MARK: - Initialization

    /// Creates a TaxTriage configuration with the specified parameters.
    ///
    /// - Parameters:
    ///   - samples: Input sample definitions.
    ///   - platform: Default sequencing platform.
    ///   - outputDirectory: Output directory for results.
    ///   - kraken2DatabasePath: Path to existing Kraken2 database (optional).
    ///   - classifiers: Classifier backends to run.
    ///   - topHitsCount: Number of top hits to report.
    ///   - k2Confidence: Kraken2 confidence threshold.
    ///   - rank: Taxonomic rank for reporting.
    ///   - skipAssembly: Whether to skip assembly.
    ///   - skipKrona: Whether to skip Krona visualization.
    ///   - maxMemory: Maximum memory allocation.
    ///   - maxCpus: Maximum CPU count.
    ///   - profile: Nextflow execution profile.
    ///   - containerRuntime: Optional container runtime override.
    ///   - revision: Nextflow pipeline revision.
    ///   - sourceBundleURLs: Source FASTQ bundle URLs for provenance tracking.
    public init(
        samples: [TaxTriageSample],
        platform: Platform = .illumina,
        outputDirectory: URL,
        kraken2DatabasePath: URL? = nil,
        classifiers: [String] = ["kraken2"],
        topHitsCount: Int = 10,
        k2Confidence: Double = 0.2,
        rank: String = "S",
        skipAssembly: Bool = true,
        skipKrona: Bool = false,
        maxMemory: String = "16.GB",
        maxCpus: Int = ProcessInfo.processInfo.activeProcessorCount,
        profile: String = "docker",
        containerRuntime: String? = nil,
        revision: String = "main",
        sourceBundleURLs: [URL]? = nil
    ) {
        self.samples = samples
        self.platform = platform
        self.outputDirectory = outputDirectory
        self.kraken2DatabasePath = kraken2DatabasePath
        self.classifiers = classifiers
        self.topHitsCount = topHitsCount
        self.k2Confidence = k2Confidence
        self.rank = rank
        self.skipAssembly = skipAssembly
        self.skipKrona = skipKrona
        self.maxMemory = maxMemory
        self.maxCpus = maxCpus
        self.profile = profile
        self.containerRuntime = containerRuntime
        self.revision = revision
        self.sourceBundleURLs = sourceBundleURLs
    }

    // MARK: - Computed Properties

    /// The path to the samplesheet CSV in the output directory.
    public var samplesheetURL: URL {
        outputDirectory.appendingPathComponent("samplesheet.csv")
    }

    /// The GitHub repository identifier for the TaxTriage pipeline.
    public static let pipelineRepository = "jhuapl-bio/taxtriage"

    /// Builds the command-line arguments for the Nextflow `run` invocation.
    ///
    /// This produces the complete argument list after `nextflow run jhuapl-bio/taxtriage`.
    ///
    /// - Returns: An array of argument strings.
    public func nextflowArguments() -> [String] {
        var args: [String] = []

        // Pipeline source and revision
        args += [Self.pipelineRepository, "-r", revision]

        // Profile
        args += ["-profile", profile]

        // Input samplesheet
        args += ["--input", samplesheetURL.path]

        // Output directory
        args += ["--outdir", outputDirectory.path]

        // Database
        if let dbPath = kraken2DatabasePath {
            args += ["--db", dbPath.path]
        }

        // Classification parameters
        args += ["--top_hits_count", String(topHitsCount)]
        args += ["--k2_confidence", String(k2Confidence)]
        args += ["--rank", rank]

        // Assembly control
        if skipAssembly {
            args.append("--skip_assembly")
        }

        // Krona control
        if skipKrona {
            args.append("--skip_krona")
        }

        // Resource limits
        args += ["--max_memory", maxMemory]
        args += ["--max_cpus", String(maxCpus)]

        return args
    }
}

// MARK: - TaxTriageSample

/// A single sample for the TaxTriage pipeline.
///
/// Each sample consists of one or two FASTQ files (single-end or paired-end)
/// with an associated sample identifier and sequencing platform.
///
/// ## Example
///
/// ```swift
/// // Paired-end Illumina sample
/// let paired = TaxTriageSample(
///     sampleId: "Patient001",
///     fastq1: URL(fileURLWithPath: "/data/P001_R1.fastq.gz"),
///     fastq2: URL(fileURLWithPath: "/data/P001_R2.fastq.gz"),
///     platform: .illumina
/// )
///
/// // Single-end Nanopore sample
/// let single = TaxTriageSample(
///     sampleId: "ONT_Run1",
///     fastq1: URL(fileURLWithPath: "/data/ONT_reads.fastq.gz"),
///     fastq2: nil,
///     platform: .oxford
/// )
/// ```
public struct TaxTriageSample: Sendable, Codable, Equatable, Identifiable {

    /// Unique identifier derived from the sample name.
    public var id: String { sampleId }

    /// Sample identifier used in the samplesheet and output file naming.
    public let sampleId: String

    /// Path to the first (or only) FASTQ file.
    public var fastq1: URL

    /// Path to the second FASTQ file for paired-end data, or nil for single-end.
    public var fastq2: URL?

    /// Sequencing platform for this sample.
    public let platform: TaxTriageConfig.Platform

    /// Whether this sample is a negative control (e.g. blank extraction, NTC).
    ///
    /// Organisms detected in negative control samples are flagged as potential
    /// contaminants in batch analysis. Optional with default `false` for
    /// backward compatibility with previously serialized configs.
    public var isNegativeControl: Bool

    /// Structured sample metadata, loaded from the FASTQ bundle's metadata.csv.
    /// When present, `isAnyNegativeControl` is derived from `metadata.sampleRole`.
    /// Not serialized in the TaxTriage config JSON (populated at runtime).
    public var metadata: FASTQSampleMetadata?

    /// Creates a new TaxTriage sample.
    ///
    /// - Parameters:
    ///   - sampleId: Unique sample identifier.
    ///   - fastq1: Path to R1 (or single-end) FASTQ file.
    ///   - fastq2: Path to R2 FASTQ file (nil for single-end).
    ///   - platform: Sequencing platform.
    ///   - isNegativeControl: Whether this sample is a negative control.
    public init(
        sampleId: String,
        fastq1: URL,
        fastq2: URL? = nil,
        platform: TaxTriageConfig.Platform = .illumina,
        isNegativeControl: Bool = false,
        metadata: FASTQSampleMetadata? = nil
    ) {
        self.sampleId = sampleId
        self.fastq1 = fastq1
        self.fastq2 = fastq2
        self.platform = platform
        self.isNegativeControl = isNegativeControl
        self.metadata = metadata
    }

    // Backward-compatible decoding: isNegativeControl defaults to false if absent.
    // metadata is not serialized in config JSON; it's populated at runtime.
    enum CodingKeys: String, CodingKey {
        case sampleId, fastq1, fastq2, platform, isNegativeControl
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sampleId = try container.decode(String.self, forKey: .sampleId)
        fastq1 = try container.decode(URL.self, forKey: .fastq1)
        fastq2 = try container.decodeIfPresent(URL.self, forKey: .fastq2)
        platform = try container.decode(TaxTriageConfig.Platform.self, forKey: .platform)
        isNegativeControl = try container.decodeIfPresent(Bool.self, forKey: .isNegativeControl) ?? false
        metadata = nil  // Not serialized; populated at runtime
    }

    /// True if this sample is any type of negative control.
    ///
    /// When structured metadata is available, checks `sampleRole` for
    /// negative control or extraction blank. Falls back to `isNegativeControl`.
    public var isAnyNegativeControl: Bool {
        if let metadata {
            return metadata.sampleRole == .negativeControl
                || metadata.sampleRole == .extractionBlank
        }
        return isNegativeControl
    }

    /// Whether this sample has paired-end reads.
    public var isPairedEnd: Bool {
        fastq2 != nil
    }

    /// All FASTQ files for this sample.
    public var allFiles: [URL] {
        if let r2 = fastq2 {
            return [fastq1, r2]
        }
        return [fastq1]
    }
}

// MARK: - TaxTriageConfigError

/// Errors produced during TaxTriage configuration validation.
public enum TaxTriageConfigError: Error, LocalizedError, Sendable {

    /// No samples were provided.
    case noSamples

    /// A sample has an empty sample ID.
    case emptySampleId

    /// Duplicate sample IDs were found.
    case duplicateSampleIds([String])

    /// An input FASTQ file does not exist.
    case inputFileNotFound(sampleId: String, path: URL)

    /// The Kraken2 database path does not exist.
    case databaseNotFound(URL)

    /// The Kraken2 confidence value is out of range.
    case invalidK2Confidence(Double)

    /// The top hits count is not positive.
    case invalidTopHitsCount(Int)

    /// The output directory could not be created.
    case outputDirectoryCreationFailed(URL, Error)

    /// An input path is a directory, not a FASTQ file.
    case inputPathIsDirectory(sampleId: String, path: URL)

    public var errorDescription: String? {
        switch self {
        case .noSamples:
            return "No samples specified for TaxTriage pipeline"
        case .emptySampleId:
            return "Sample ID must not be empty"
        case .duplicateSampleIds(let ids):
            return "Duplicate sample IDs: \(ids.joined(separator: ", "))"
        case .inputFileNotFound(let sampleId, let path):
            return "Input file not found for sample '\(sampleId)': \(path.lastPathComponent)"
        case .inputPathIsDirectory(let sampleId, let path):
            return "Input path is a directory for sample '\(sampleId)', expected FASTQ file: \(path.lastPathComponent)"
        case .databaseNotFound(let url):
            return "Kraken2 database not found at \(url.path)"
        case .invalidK2Confidence(let value):
            return "k2_confidence must be between 0.0 and 1.0, got \(value)"
        case .invalidTopHitsCount(let value):
            return "top_hits_count must be positive, got \(value)"
        case .outputDirectoryCreationFailed(let url, let error):
            return "Cannot create output directory at \(url.path): \(error.localizedDescription)"
        }
    }
}

// MARK: - Validation

extension TaxTriageConfig {

    /// Validates this configuration, checking file existence and parameter ranges.
    ///
    /// - Throws: ``TaxTriageConfigError`` describing the first validation failure.
    public func validate() throws {
        // Must have at least one sample
        guard !samples.isEmpty else {
            throw TaxTriageConfigError.noSamples
        }

        // Validate each sample
        let fm = FileManager.default
        for sample in samples {
            guard !sample.sampleId.isEmpty else {
                throw TaxTriageConfigError.emptySampleId
            }

            var isDir1: ObjCBool = false
            guard fm.fileExists(atPath: sample.fastq1.path, isDirectory: &isDir1) else {
                throw TaxTriageConfigError.inputFileNotFound(
                    sampleId: sample.sampleId,
                    path: sample.fastq1
                )
            }
            if isDir1.boolValue {
                throw TaxTriageConfigError.inputPathIsDirectory(
                    sampleId: sample.sampleId,
                    path: sample.fastq1
                )
            }

            if let r2 = sample.fastq2 {
                var isDir2: ObjCBool = false
                guard fm.fileExists(atPath: r2.path, isDirectory: &isDir2) else {
                    throw TaxTriageConfigError.inputFileNotFound(
                        sampleId: sample.sampleId,
                        path: r2
                    )
                }
                if isDir2.boolValue {
                    throw TaxTriageConfigError.inputPathIsDirectory(
                        sampleId: sample.sampleId,
                        path: r2
                    )
                }
            }
        }

        // Check for duplicate sample IDs
        let ids = samples.map(\.sampleId)
        let duplicates = Dictionary(grouping: ids, by: { $0 })
            .filter { $0.value.count > 1 }
            .map(\.key)
        if !duplicates.isEmpty {
            throw TaxTriageConfigError.duplicateSampleIds(duplicates.sorted())
        }

        // Validate confidence range
        guard k2Confidence >= 0.0 && k2Confidence <= 1.0 else {
            throw TaxTriageConfigError.invalidK2Confidence(k2Confidence)
        }

        // Validate top hits count
        guard topHitsCount > 0 else {
            throw TaxTriageConfigError.invalidTopHitsCount(topHitsCount)
        }

        // Validate database if specified
        if let dbPath = kraken2DatabasePath {
            guard fm.fileExists(atPath: dbPath.path) else {
                throw TaxTriageConfigError.databaseNotFound(dbPath)
            }
        }
    }
}
