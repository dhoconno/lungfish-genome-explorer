// EsVirituAnalysisRunTypes.swift - The options, units, results and text reporter of EsViritu on the executor
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// The options of one `lungfish-cli esviritu detect` run, as the command parsed them.
public struct EsVirituAnalysisRunOptions: Sendable, Equatable {
    /// `--read-format`. `auto` lets the read-set planner decide each sample's layout.
    public enum ReadFormatChoice: String, Sendable, Equatable, CaseIterable {
        case auto
        case unpaired
        case paired
        case interleaved
    }

    /// `--sample`, the one sample's name. A `--batch` run names each sample after its files.
    public var sampleName: String?
    public var readFormat: ReadFormatChoice
    /// `--paired`.
    public var pairedEnd: Bool
    /// `--db`, or nil for the installed database.
    public var databasePath: URL?
    public var threads: Int
    /// The inverse of `--no-qc`.
    public var qualityFilter: Bool
    /// `--extra-args` as given, split in the plan.
    public var extraArguments: String
    /// A conflict between the command's flags that the plan refuses with exit 3, such as
    /// `--project` given with `--output`. Nil when the flags agree.
    public var usageConflict: String?

    public init(
        sampleName: String?,
        readFormat: ReadFormatChoice = .auto,
        pairedEnd: Bool = false,
        databasePath: URL? = nil,
        threads: Int,
        qualityFilter: Bool = true,
        extraArguments: String = "",
        usageConflict: String? = nil
    ) {
        self.sampleName = sampleName
        self.readFormat = readFormat
        self.pairedEnd = pairedEnd
        self.databasePath = databasePath
        self.threads = threads
        self.qualityFilter = qualityFilter
        self.extraArguments = extraArguments
        self.usageConflict = usageConflict
    }
}

/// Why the plan of `esviritu detect` refused a request, with the exit code the command has always
/// used for it, `CLIExitCode.inputError` (3) or `CLIExitCode.dependency` (126).
public enum EsVirituAnalysisRunRefusal: Error, LocalizedError, Equatable, AnalysisRunExitCoding {
    case input(String)
    case dependency(String)

    public var errorDescription: String? {
        switch self {
        case .input(let message), .dependency(let message):
            return message
        }
    }

    public var analysisRunExitCode: Int32 {
        switch self {
        case .input: return 3
        case .dependency: return 126
        }
    }
}

/// What every sample of one run shares, settled in the plan.
public struct EsVirituRunSettings: Sendable, Equatable {
    public let databasePath: URL
    public let threads: Int
    public let qualityFilter: Bool
    public let extraArguments: [String]
}

/// One sample of an EsViritu run, a unit of the executor.
public struct EsVirituSampleUnit: Sendable {
    /// The sample's inputs as given, files or `.lungfishfastq` bundles.
    public let inputs: [URL]
    /// The read format the plan chose. A planned sample may change it at run time.
    public let readFormat: EsVirituReadFormat
    public let inputLayout: FASTQReadLayoutClassification?
    /// Whether the read-set planner decides the sample's files and format (`--read-format auto`).
    public let plansReadSet: Bool
    public let settings: EsVirituRunSettings
}

/// What one sample that ran hands to the finalize.
public struct EsVirituSampleResult: Sendable {
    /// The sample's inputs as given.
    public let inputs: [URL]
    /// The configuration EsViritu ran with.
    public let config: EsVirituConfig
    public let result: EsVirituResult
    /// The detections the parsed table holds, and their families and species.
    public let detectionCount: Int
    public let familyCount: Int
    public let speciesCount: Int
}

/// The human text of a run in the command's text mode, at the points where `esviritu detect` has
/// always printed it. The machine stream is the executor's events, so a run with `--format json`
/// passes no reporter. Every method may be called from any thread.
public protocol EsVirituRunReporting: Sendable {
    /// A line about the inputs being resolved, such as a virtual bundle being materialized.
    func resolving(_ message: String)
    /// The sample's configuration, just before EsViritu runs. `advisory` warns of reads too short
    /// to align, and the run goes on.
    func willRun(_ config: EsVirituConfig, inputs: [URL], advisory: String?)
    /// One progress message of the pipeline.
    func progress(_ fraction: Double, _ message: String)
    /// The sample's results, once EsViritu ran and its table parsed.
    func didRun(_ result: EsVirituResult)
}
