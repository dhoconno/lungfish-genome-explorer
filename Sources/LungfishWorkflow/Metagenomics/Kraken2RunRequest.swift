// Kraken2RunRequest.swift - What one kraken2 classify run asks for, the services its tool runs with, and its refusals
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// How a Kraken2 sample's reads are laid out, as `--read-format` names them.
public enum Kraken2ReadFormatChoice: String, Sendable, CaseIterable {
    /// Plans one input, a file or a `.lungfishfastq` bundle, with ``KrakenReadSetPlanner``.
    case auto
    case unpaired
    case paired
    case interleaved
}

/// The options of one `lungfish-cli kraken2 classify` run, as the command parsed them (2.7 A8).
///
/// ``Kraken2AnalysisRunTool`` turns them into units in its plan. Whether an option was given, as
/// opposed to left at its default, is read from the run's command line, as the record has always
/// read it, so `preset` holds the parser's value and is recorded only when `--preset` was given
/// (decision E12).
public struct Kraken2RunRequest: Sendable {
    /// The inputs as typed, files, bundles or folders.
    public var inputArguments: [String]
    /// The registry name of the database (`--db`).
    public var databaseName: String
    /// The SHA-256 the database's install receipt must hold (`--db-digest`, decision E9).
    public var databaseDigest: String?
    public var preset: ClassificationConfig.Preset
    public var confidence: Double?
    public var minimumHitGroups: Int?
    /// `--threads`, or nil for the command's default of 4.
    public var threads: Int?
    public var readFormat: Kraken2ReadFormatChoice
    public var pairedEnd: Bool
    /// Files of merged or single reads beside a `--paired` R1 and R2 (`--unpaired`).
    public var unpairedArguments: [String]
    public var recursive: Bool
    public var profile: Bool
    public var brackenReadLength: Int
    public var brackenLevel: String?
    public var brackenThreshold: Int
    public var memoryMapping: Bool
    public var quickMode: Bool
    /// `--extra-args` as typed.
    public var extraArguments: String
    /// The command's path below the executable, such as `["kraken2", "classify"]`, whose provenance
    /// policy entry the plan checks.
    public var commandPath: [String]

    /// The thread count when `--threads` is not given.
    public static let defaultThreads = 4

    public init(
        inputArguments: [String],
        databaseName: String,
        databaseDigest: String? = nil,
        preset: ClassificationConfig.Preset = .balanced,
        confidence: Double? = nil,
        minimumHitGroups: Int? = nil,
        threads: Int? = nil,
        readFormat: Kraken2ReadFormatChoice = .auto,
        pairedEnd: Bool = false,
        unpairedArguments: [String] = [],
        recursive: Bool = false,
        profile: Bool = false,
        brackenReadLength: Int = 150,
        brackenLevel: String? = nil,
        brackenThreshold: Int = 10,
        memoryMapping: Bool = false,
        quickMode: Bool = false,
        extraArguments: String = "",
        commandPath: [String] = ["kraken2", "classify"]
    ) {
        self.inputArguments = inputArguments
        self.databaseName = databaseName
        self.databaseDigest = databaseDigest
        self.preset = preset
        self.confidence = confidence
        self.minimumHitGroups = minimumHitGroups
        self.threads = threads
        self.readFormat = readFormat
        self.pairedEnd = pairedEnd
        self.unpairedArguments = unpairedArguments
        self.recursive = recursive
        self.profile = profile
        self.brackenReadLength = brackenReadLength
        self.brackenLevel = brackenLevel
        self.brackenThreshold = brackenThreshold
        self.memoryMapping = memoryMapping
        self.quickMode = quickMode
        self.extraArguments = extraArguments
        self.commandPath = commandPath
    }

    /// The thread count the run uses.
    public var effectiveThreads: Int { threads ?? Self.defaultThreads }

    /// The Bracken request of a `--profile` run, or nil.
    public var brackenProfileRequest: BrackenProfileRequest? {
        guard profile else { return nil }
        return BrackenProfileRequest(
            rank: brackenLevel.map { .explicit(TaxonomicRank(code: $0)) } ?? .automatic,
            readLength: brackenReadLength,
            threshold: brackenThreshold
        )
    }
}

/// The read format a run uses, with the layout scan that chose it.
public struct Kraken2ResolvedReadFormat: Equatable, Sendable {
    public let format: ClassificationConfig.ReadFormat
    public let layout: FASTQReadLayoutClassification?

    public init(format: ClassificationConfig.ReadFormat, layout: FASTQReadLayoutClassification?) {
        self.format = format
        self.layout = layout
    }
}

/// The files a planned read set runs, with the input each came from.
public struct Kraken2PlannedReadSet: Sendable, Equatable {
    public let executionInputURLs: [URL]
    public let originalInputURLs: [URL]

    public init(executionInputURLs: [URL], originalInputURLs: [URL]) {
        self.executionInputURLs = executionInputURLs
        self.originalInputURLs = originalInputURLs
    }
}

/// Why a Kraken2 plan refused a request before any folder exists, with the code the command exits
/// with. The codes equal `CLIExitCode` in LungfishCLI, which a CLI test pins.
public struct Kraken2RunRefusal: Error, LocalizedError, AnalysisRunExitCoding, Equatable, Sendable {
    /// `CLIExitCode.inputError`.
    public static let inputErrorCode: Int32 = 3
    /// `CLIExitCode.dependency`.
    public static let dependencyCode: Int32 = 126

    public let message: String
    public let analysisRunExitCode: Int32

    public init(message: String, exitCode: Int32) {
        self.message = message
        self.analysisRunExitCode = exitCode
    }

    public var errorDescription: String? { message }

    /// A request the inputs or options make impossible.
    public static func input(_ message: String) -> Kraken2RunRefusal {
        Kraken2RunRefusal(message: message, exitCode: inputErrorCode)
    }

    /// A database that is missing, not ready or not the one asked for.
    public static func dependency(_ message: String) -> Kraken2RunRefusal {
        Kraken2RunRefusal(message: message, exitCode: dependencyCode)
    }
}

/// What a Kraken2 run shows a person reading text, beside its events. The command line fills it in
/// text mode and leaves it empty for `--format json`.
public struct Kraken2RunPresentation: Sendable {
    /// Called once per unit with the configuration Kraken2 is about to run.
    public var configured: (@Sendable (ClassificationConfig) -> Void)?
    /// Called with each progress message of the classification pipeline.
    public var pipelineProgress: (@Sendable (String) -> Void)?

    public init(
        configured: (@Sendable (ClassificationConfig) -> Void)? = nil,
        pipelineProgress: (@Sendable (String) -> Void)? = nil
    ) {
        self.configured = configured
        self.pipelineProgress = pipelineProgress
    }

    public static let none = Kraken2RunPresentation()
}

/// What ``Kraken2AnalysisRunTool`` runs with besides its request, so a test can stand in for the
/// registry, the materializer and the pipeline.
public struct Kraken2RunServices: Sendable {
    /// Expands the inputs as typed into files and bundles. The command line expands folders.
    public var expandInputs: @Sendable (_ arguments: [String], _ recursive: Bool) throws -> [URL]
    /// The registry entry of a database name, or nil.
    public var database: @Sendable (_ name: String) async throws -> MetagenomicsDatabaseInfo?
    /// Every database the registry lists, for the refusal of an unknown name.
    public var availableDatabases: @Sendable () async throws -> [MetagenomicsDatabaseInfo]
    public var materializer: any CLISequenceInputMaterializing & Sendable
    /// Runs Kraken2, and Bracken for a profile goal, and returns the result.
    public var runPipeline: @Sendable (
        _ config: ClassificationConfig,
        _ progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ClassificationResult
    public var presentation: Kraken2RunPresentation

    public init(
        expandInputs: @escaping @Sendable ([String], Bool) throws -> [URL] = Kraken2RunServices.literalInputs,
        database: @escaping @Sendable (String) async throws -> MetagenomicsDatabaseInfo? = { name in
            try await MetagenomicsDatabaseRegistry.shared.database(named: name)
        },
        availableDatabases: @escaping @Sendable () async throws -> [MetagenomicsDatabaseInfo] = {
            try await MetagenomicsDatabaseRegistry.shared.availableDatabases()
        },
        materializer: any CLISequenceInputMaterializing & Sendable = FASTQCLIMaterializer(runner: NativeToolRunner.shared),
        runPipeline: @escaping @Sendable (ClassificationConfig, @escaping @Sendable (Double, String) -> Void) async throws -> ClassificationResult = Kraken2RunServices.sharedPipeline,
        presentation: Kraken2RunPresentation = .none
    ) {
        self.expandInputs = expandInputs
        self.database = database
        self.availableDatabases = availableDatabases
        self.materializer = materializer
        self.runPipeline = runPipeline
        self.presentation = presentation
    }

    /// Each argument as one input, without expanding folders.
    public static let literalInputs: @Sendable ([String], Bool) throws -> [URL] = { arguments, _ in
        arguments.map { URL(fileURLWithPath: $0) }
    }

    /// ``ClassificationPipeline/shared``, classify or profile by the configuration's goal.
    public static let sharedPipeline: @Sendable (
        ClassificationConfig,
        @escaping @Sendable (Double, String) -> Void
    ) async throws -> ClassificationResult = { config, progress in
        switch config.goal {
        case .profile:
            return try await ClassificationPipeline.shared.profile(config: config, progress: progress)
        case .classify, .extract:
            return try await ClassificationPipeline.shared.classify(config: config, progress: progress)
        }
    }
}
