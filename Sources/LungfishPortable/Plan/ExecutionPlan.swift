// ExecutionPlan.swift - The plan a run on another machine follows, the executor's whole input (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The plan the Mac writes for one sample and `lungfish-executor run --plan` follows on any x86-64 Linux machine.
///
/// Every file it needs is a `PlanEntry` in the plan's folder, every value a tool would otherwise read from the host is
/// fixed here, and each step holds the engine's own argv with paths relative to the work root (SWIFT N8). Decode it with
/// `ExecutionPlan.decode(_:)`, which refuses a plan the executor must not run with a `PlanDecodeError` that names the
/// field, so the Mac's writer and the node refuse the same plan with the same words (tally-r2 K4-13).
package struct ExecutionPlan: Codable, Sendable, Equatable {
    /// The schema version this build reads and writes.
    package static let currentSchemaVersion = 1
    /// The longest grace a plan may give a step between SIGTERM and SIGKILL (inventory section 4).
    package static let maximumGraceSeconds: Double = 120
    /// The longest deadline a plan may give a step, one leap year, so the controller's millisecond count cannot trap.
    package static let maximumDeadlineSeconds: Double = 31_622_400
    /// The largest clumpify heap a plan may name, 64 TiB, so the heap in bytes cannot overflow.
    package static let maximumClumpifyHeapGB = 65_536

    package var schemaVersion: Int
    package var entries: [PlanEntry]
    package var executor: PlanExecutorBuild
    package var imageManifest: PlanImageManifestPin
    /// Every tool any step runs, with the version and build the image's manifest must list.
    package var tools: [PlanToolPin]
    /// The recipe that ran, or nil for an import with no recipe.
    package var recipe: PlanRecipeIdentity?
    package var sample: PlanSampleValues
    package var storage: PlanStorageSettings
    package var clumping: PlanClumpingChoice
    package var statistics: PlanStatisticsSettings
    /// Seconds between SIGTERM and SIGKILL for every step, above 0 and at most `maximumGraceSeconds`.
    package var graceSeconds: Double
    package var steps: [PlanStep]

    package init(
        schemaVersion: Int = ExecutionPlan.currentSchemaVersion,
        entries: [PlanEntry],
        executor: PlanExecutorBuild,
        imageManifest: PlanImageManifestPin,
        tools: [PlanToolPin],
        recipe: PlanRecipeIdentity?,
        sample: PlanSampleValues,
        storage: PlanStorageSettings,
        clumping: PlanClumpingChoice,
        statistics: PlanStatisticsSettings,
        graceSeconds: Double,
        steps: [PlanStep]
    ) {
        self.schemaVersion = schemaVersion
        self.entries = entries
        self.executor = executor
        self.imageManifest = imageManifest
        self.tools = tools
        self.recipe = recipe
        self.sample = sample
        self.storage = storage
        self.clumping = clumping
        self.statistics = statistics
        self.graceSeconds = graceSeconds
        self.steps = steps
    }
}

/// What built the executor the plan pins as its `executor` entry (tally K4.4, ARCH A3). The binary holds no version
/// string of its own, so the plan carries these and the run record states them as a pin.
package struct PlanExecutorBuild: Codable, Sendable, Equatable {
    package var lgeVersion: String
    package var lgeCommit: String
    package var targetTriple: String
    package var toolchainID: String
    package var toolchainSHA256: String
    package var staticLinuxSDKID: String
    package var staticLinuxSDKSHA256: String

    package init(
        lgeVersion: String, lgeCommit: String, targetTriple: String, toolchainID: String, toolchainSHA256: String,
        staticLinuxSDKID: String, staticLinuxSDKSHA256: String
    ) {
        self.lgeVersion = lgeVersion
        self.lgeCommit = lgeCommit
        self.targetTriple = targetTriple
        self.toolchainID = toolchainID
        self.toolchainSHA256 = toolchainSHA256
        self.staticLinuxSDKID = staticLinuxSDKID
        self.staticLinuxSDKSHA256 = staticLinuxSDKSHA256
    }
}

/// One key and value, kept in the order written.
package struct PlanKeyValue: Codable, Sendable, Equatable {
    package var key: String
    package var value: String

    package init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// The recipe identity the in-process route records (tally K4.8, BIO-r3 R8): the recipe, the name the run was given,
/// the preset it resolved to, each switch's value and source, and each step a switch turned off with that switch, as the
/// Mac's import record holds them. Its `recipe` entry's SHA-256 equals `sourceSHA256`.
package struct PlanRecipeIdentity: Codable, Sendable, Equatable {
    package var id: String
    package var name: String
    /// The name the run was given, such as a preset's id or alias.
    package var requestedName: String
    package var formatVersion: Int
    package var sourceSHA256: String
    package var presetID: String?
    package var presetName: String?
    package var switches: [PlanRecipeSwitch]
    /// The steps a switch turned off, in recipe order. The engine plans only the steps that run.
    package var turnedOffSteps: [PlanTurnedOffStep]

    package init(
        id: String, name: String, requestedName: String, formatVersion: Int, sourceSHA256: String,
        presetID: String? = nil, presetName: String? = nil, switches: [PlanRecipeSwitch] = [],
        turnedOffSteps: [PlanTurnedOffStep] = []
    ) {
        self.id = id
        self.name = name
        self.requestedName = requestedName
        self.formatVersion = formatVersion
        self.sourceSHA256 = sourceSHA256
        self.presetID = presetID
        self.presetName = presetName
        self.switches = switches
        self.turnedOffSteps = turnedOffSteps
    }
}

/// One switch of the recipe, with its value and the source that set it: `recipeDefault`, `preset` or `option`.
package struct PlanRecipeSwitch: Codable, Sendable, Equatable {
    package var id: String
    package var label: String
    package var value: Bool
    package var source: String

    package init(id: String, label: String, value: Bool, source: String) {
        self.id = id
        self.label = label
        self.value = value
        self.source = source
    }
}

/// A recipe step a switch turned off, with the number of steps that run before it, so a record states the step as not
/// run where it would have run, with the switch that turned it off.
package struct PlanTurnedOffStep: Codable, Sendable, Equatable {
    package var stepType: String
    /// The recipe's own label for the step, when it gives one.
    package var label: String?
    package var activeStepsBefore: Int
    package var switchID: String

    package init(stepType: String, label: String?, activeStepsBefore: Int, switchID: String) {
        self.stepType = stepType
        self.label = label
        self.activeStepsBefore = activeStepsBefore
        self.switchID = switchID
    }
}

/// What the in-process route fills from the Mac's side, so the adopt takes it from the plan once every input digest
/// of the run record equals the plan's entry (tally K4.8).
package struct PlanSampleValues: Codable, Sendable, Equatable {
    package var sampleName: String
    package var originalFilenames: [String]
    package var originalSizeBytes: Int64
    package var platform: String?
    package var sampleSheet: [PlanKeyValue]

    package init(
        sampleName: String, originalFilenames: [String], originalSizeBytes: Int64, platform: String? = nil,
        sampleSheet: [PlanKeyValue] = []
    ) {
        self.sampleName = sampleName
        self.originalFilenames = originalFilenames
        self.originalSizeBytes = originalSizeBytes
        self.platform = platform
        self.sampleSheet = sampleSheet
    }
}

/// The storage values the plan fixes, each with the Mac's own source for it (ARCH A1). None has an automatic value,
/// and threads and heap are positive, since no value may mean every core or the host's memory (tally K4.5).
package struct PlanStorageSettings: Codable, Sendable, Equatable {
    package var clumpingTool: PlanClumpingTool
    package var compressor: PlanCompressor
    package var qualityBinning: QualityBinningScheme
    package var threads: Int
    package var clumpifyHeapGB: Int
    /// The level the user chose, 1 to 9, which `reformat.sh` and Trim Galore take as `zl` (BIO N3).
    package var compressionLevel: Int
    package var threadsSource: ImportSettingSource
    package var clumpifyHeapSource: ImportSettingSource
    package var clumpingToolSource: ImportSettingSource
    package var compressorSource: ImportSettingSource
    package var qualityBinningSource: ImportSettingSource

    package init(
        clumpingTool: PlanClumpingTool, compressor: PlanCompressor, qualityBinning: QualityBinningScheme, threads: Int,
        clumpifyHeapGB: Int, compressionLevel: Int, threadsSource: ImportSettingSource,
        clumpifyHeapSource: ImportSettingSource, clumpingToolSource: ImportSettingSource,
        compressorSource: ImportSettingSource, qualityBinningSource: ImportSettingSource
    ) {
        self.clumpingTool = clumpingTool
        self.compressor = compressor
        self.qualityBinning = qualityBinning
        self.threads = threads
        self.clumpifyHeapGB = clumpifyHeapGB
        self.compressionLevel = compressionLevel
        self.threadsSource = threadsSource
        self.clumpifyHeapSource = clumpifyHeapSource
        self.clumpingToolSource = clumpingToolSource
        self.compressorSource = compressorSource
        self.qualityBinningSource = qualityBinningSource
    }
}

/// The statistics passes' values. Threads are positive.
package struct PlanStatisticsSettings: Codable, Sendable, Equatable {
    package var threads: Int

    package init(threads: Int) {
        self.threads = threads
    }
}

/// What a step does, so the executor and the adopt know which record fields it fills.
package enum PlanStepKind: String, Codable, Sendable, CaseIterable {
    case recipe
    case storage
    case interleave
    case compress
    case statistics
    /// The executor's own Q20 and Q30 count (BIO N6), which runs no tool.
    case qualityCount
}

/// One variable of a step's environment. The executor builds each child's environment from nothing, adds `PATH`,
/// `TMPDIR` and `HOME` itself, and then these, such as `_JAVA_OPTIONS=-Xmx<heap>g` for clumpify (tally-r2 K4-07).
package struct PlanEnvironmentVariable: Codable, Sendable, Equatable {
    package var name: String
    package var value: String

    package init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// One step of the plan, with the engine's own argv relative to the work root.
package struct PlanStep: Codable, Sendable, Equatable {
    /// Unique in the plan, 1 to 64 of `A-Z a-z 0-9 . _ -`, starting with a letter or digit, so it can name a folder.
    package var id: String
    package var title: String
    package var kind: PlanStepKind
    /// The tool the step runs, nil only for a `qualityCount` step, which the executor computes itself.
    package var tool: PlanToolPin?
    package var arguments: [String]
    package var environment: [PlanEnvironmentVariable]
    /// The step's own deadline from the plan, never the Mac's input-size rule (tally-r2 K4-06). Above 0.
    package var deadlineSeconds: Double
    package var inputs: [String]
    package var outputs: [String]
    /// The work-root path the step's standard output is written to, when the step keeps it.
    package var standardOutput: String?

    package init(
        id: String, title: String, kind: PlanStepKind, tool: PlanToolPin?, arguments: [String],
        environment: [PlanEnvironmentVariable] = [], deadlineSeconds: Double, inputs: [String], outputs: [String],
        standardOutput: String? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.tool = tool
        self.arguments = arguments
        self.environment = environment
        self.deadlineSeconds = deadlineSeconds
        self.inputs = inputs
        self.outputs = outputs
        self.standardOutput = standardOutput
    }
}

extension ExecutionPlan {
    /// Decodes and checks a plan. Every failure is a `PlanDecodeError` naming the field.
    package static func decode(_ data: Data) throws -> ExecutionPlan {
        let plan: ExecutionPlan
        do {
            plan = try JSONDecoder().decode(ExecutionPlan.self, from: data)
        } catch let error as PlanDecodeError {
            throw error
        } catch let error as DecodingError {
            throw PlanDecodeError(decodingError: error)
        }
        try plan.validate()
        return plan
    }

    /// The plan file's bytes, keys sorted so equal plans are equal bytes.
    package func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data("\n".utf8)
    }
}
