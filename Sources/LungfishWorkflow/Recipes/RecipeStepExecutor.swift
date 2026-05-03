// RecipeStepExecutor.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - RecipeFileFormat

/// File layout for data flowing between recipe steps.
///
/// This is distinct from ``FileFormat`` (in `ProvenanceRecord.swift`), which
/// describes genomic file types.  `RecipeFileFormat` describes how FASTQ reads
/// are arranged on disk as they move from step to step in a recipe pipeline.
public enum RecipeFileFormat: String, Codable, Sendable, Equatable {
    /// Separate R1.fq.gz + R2.fq.gz paired-end files.
    case pairedR1R2
    /// Single interleaved FASTQ file.
    case interleaved
    /// Post-merge layout: merged.fq.gz + unmerged_R1.fq.gz + unmerged_R2.fq.gz
    case merged
    /// Single-end reads in a single file.
    case single
}

// MARK: - StepInput

/// Input data provided to a recipe step executor.
public struct StepInput: Sendable {
    /// Primary file: R1 for `pairedR1R2`; the single file for `interleaved`/`single`; merged reads for `merged`.
    public let r1: URL
    /// Secondary file: R2 for `pairedR1R2`; unmerged_R1 for `merged`; nil otherwise.
    public let r2: URL?
    /// Tertiary file: unmerged_R2 for `merged`; nil otherwise.
    public let r3: URL?
    /// Format of the input data.
    public let format: RecipeFileFormat

    public init(r1: URL, r2: URL? = nil, r3: URL? = nil, format: RecipeFileFormat) {
        self.r1 = r1
        self.r2 = r2
        self.r3 = r3
        self.format = format
    }
}

// MARK: - StepOutput

/// Output data produced by a recipe step executor.
public struct StepOutput: Sendable {
    /// Primary output file.
    public let r1: URL
    /// Secondary output file (format-dependent; may be nil).
    public let r2: URL?
    /// Tertiary output file (format-dependent; may be nil).
    public let r3: URL?
    /// Format of the output data.
    public let format: RecipeFileFormat
    /// Optional read count reported by the step (e.g. from fastp JSON stats).
    public let readCount: Int?
    /// The native tool that was invoked to produce this output (nil for internal operations).
    public let tool: NativeTool?
    /// The full argument array passed to the tool.
    public let arguments: [String]?

    public init(r1: URL, r2: URL? = nil, r3: URL? = nil,
                format: RecipeFileFormat, readCount: Int? = nil,
                tool: NativeTool? = nil, arguments: [String]? = nil) {
        self.r1 = r1
        self.r2 = r2
        self.r3 = r3
        self.format = format
        self.readCount = readCount
        self.tool = tool
        self.arguments = arguments
    }
}

// MARK: - StepContext

/// Contextual resources available to every recipe step executor.
public struct StepContext: Sendable {
    /// Scratch workspace directory for intermediate files.
    public let workspace: URL
    /// Number of CPU threads to pass to tools.
    public let threads: Int
    /// Human-readable sample name used for naming output files.
    public let sampleName: String
    /// Tool runner used to invoke native bioinformatics executables.
    public let runner: NativeToolRunner
    /// Progress callback: fraction (0–1) and descriptive status message.
    public let progress: @Sendable (Double, String) -> Void

    public init(
        workspace: URL,
        threads: Int,
        sampleName: String,
        runner: NativeToolRunner,
        progress: @escaping @Sendable (Double, String) -> Void
    ) {
        self.workspace = workspace
        self.threads = threads
        self.sampleName = sampleName
        self.runner = runner
        self.progress = progress
    }

    func recipeToolTimeout(for tool: NativeTool, input: StepInput) -> TimeInterval {
        recipeToolTimeout(
            for: tool,
            inputURLs: [input.r1, input.r2, input.r3].compactMap { $0 }
        )
    }

    func recipeToolTimeout(for tool: NativeTool, inputURLs: [URL]) -> TimeInterval {
        let inputBytes = inputURLs.reduce(Int64(0)) { total, url in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return total + (attrs?[.size] as? Int64 ?? 0)
        }
        return Self.recipeToolTimeout(for: tool, inputBytes: inputBytes)
    }

    static func recipeToolTimeout(for tool: NativeTool, inputBytes: Int64) -> TimeInterval {
        if inputBytes >= 1_000_000_000 {
            return .infinity
        }

        let minimum: TimeInterval
        let bytesPerSecond: Double

        switch tool {
        case .fastp:
            minimum = 3_600
            bytesPerSecond = 5_000_000
        case .ribodetector:
            minimum = 7_200
            bytesPerSecond = 500_000
        case .deacon:
            minimum = 7_200
            bytesPerSecond = 3_000_000
        case .seqkit:
            minimum = 1_800
            bytesPerSecond = 10_000_000
        case .reformat, .clumpify, .bbduk, .bbmerge, .repair, .tadpole, .bbmap, .mapPacBio:
            minimum = 1_800
            bytesPerSecond = 2_500_000
        default:
            minimum = 1_800
            bytesPerSecond = 2_500_000
        }

        guard inputBytes > 0 else { return minimum }
        let sizeScaledTimeout = Double(inputBytes) / bytesPerSecond
        return max(minimum, sizeScaledTimeout)
    }
}

// MARK: - RecipeStepExecutor

/// Protocol for recipe step executors.
///
/// Each conforming type handles exactly one step `typeID` and transforms a
/// ``StepInput`` into a ``StepOutput`` given a ``StepContext``.
public protocol RecipeStepExecutor: Sendable {
    /// Unique string identifier matching the `type` field in a `RecipeStep` JSON.
    static var typeID: String { get }

    /// Human-readable display name shown in progress UI.
    static var displayName: String { get }

    /// The ``RecipeFileFormat`` this executor expects as input.
    var inputFormat: RecipeFileFormat { get }

    /// The ``RecipeFileFormat`` this executor produces as output.
    var outputFormat: RecipeFileFormat { get }

    /// Initialise the executor from the optional parameter dictionary stored in the recipe step.
    init(params: [String: AnyCodableValue]?) throws

    /// Execute the step, consuming `input` and returning a ``StepOutput``.
    func execute(input: StepInput, context: StepContext) async throws -> StepOutput
}

// MARK: - FastpFusible

/// Protocol for fastp-based steps that can be fused into a single invocation.
///
/// When the recipe engine detects consecutive `FastpFusible` steps it may
/// combine their argument lists into one `fastp` call to avoid redundant I/O.
public protocol FastpFusible: RecipeStepExecutor {
    /// Additional fastp command-line arguments contributed by this step.
    func fastpArgs() -> [String]
}

// MARK: - RecipeEngineError

/// Errors produced during recipe validation and step execution.
public enum RecipeEngineError: Error, LocalizedError {
    /// A step `type` string does not match any registered ``RecipeStepExecutor``.
    case unknownStepType(String)

    /// The format of a step's actual output does not match what the next step expected.
    case formatMismatch(expected: RecipeFileFormat, got: RecipeFileFormat, step: String)

    /// A step claims an incompatible transition between two ``RecipeFileFormat`` values.
    case incompatibleFormatChain(from: RecipeFileFormat, to: RecipeFileFormat, step: String)

    /// A required parameter has a value that is invalid for the given step type.
    case invalidParam(step: String, param: String, value: String)

    /// The underlying tool process exited with a non-zero status.
    case toolFailed(tool: String, step: String, stderr: String)

    /// A referenced database or index was not found on disk.
    case databaseNotFound(id: String, step: String)

    /// The actual input format does not satisfy the recipe's declared ``Recipe/InputRequirement``.
    case inputRequirementNotMet(required: Recipe.InputRequirement, actual: RecipeFileFormat)

    // MARK: LocalizedError

    public var errorDescription: String? {
        switch self {
        case .unknownStepType(let typeID):
            return "Unknown recipe step type '\(typeID)'."
        case .formatMismatch(let expected, let got, let step):
            return "Format mismatch in step '\(step)': expected \(expected.rawValue), got \(got.rawValue)."
        case .incompatibleFormatChain(let from, let to, let step):
            return "Step '\(step)' cannot accept \(from.rawValue) and produce \(to.rawValue)."
        case .invalidParam(let step, let param, let value):
            return "Invalid value '\(value)' for parameter '\(param)' in step '\(step)'."
        case .toolFailed(let tool, let step, let stderr):
            return "\(tool) failed in step '\(step)': \(stderr)"
        case .databaseNotFound(let id, let step):
            return "Database '\(id)' not found (required by step '\(step)')."
        case .inputRequirementNotMet(let required, let actual):
            return "Recipe requires \(required.rawValue) input but got \(actual.rawValue)."
        }
    }
}
