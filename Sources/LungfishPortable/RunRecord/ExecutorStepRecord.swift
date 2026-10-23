// ExecutorStepRecord.swift - One plan step's part of the run record that lungfish-executor writes (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One step of a `run --plan` run: how it ended, the tool it ran, what the sweep stopped, the outputs it hashed and the
/// counts the adopt reads (tally K4.1, K4.2, tally-r2 K4-09, K4-10, K4-14, K4-15).
///
/// The fields from `outcome` to `outputs` are K3's step record (`Sources/LungfishExecutor/Process/StepRecord.swift`),
/// moved here so the Mac can decode them (ARCH-r3 ruling 2). The subreaper result and the orphan sweep are facts of the
/// executor's process, so they sit once in `ExecutorRuntimeIdentity`. Every field a later lane added is optional, so a
/// record written before it opens and shows Not recorded (K4-14).
package struct ExecutorStepRecord: Codable, Sendable, Equatable {
    /// The most bytes of a step's standard error the record keeps, the last ones written (tally K4.2).
    package static let stderrTailLimit = 4 * 1_048_576

    /// What the `prctl(PR_SET_CHILD_SUBREAPER)` call returned (tally-r2 K3-6, K3-8).
    package struct Subreaper: Codable, Sendable, Equatable {
        /// `set` when the getter read 1 after the setter, `notSet` on Linux otherwise, `unavailable` off Linux.
        package var state: String
        package var setterResult: Int32
        package var setterResultName: String
        package var getterResult: Int32
        package var getterValue: Int32?

        package init(state: String, setterResult: Int32, setterResultName: String, getterResult: Int32, getterValue: Int32?) {
            self.state = state
            self.setterResult = setterResult
            self.setterResultName = setterResultName
            self.getterResult = getterResult
            self.getterValue = getterValue
        }
    }

    /// One output's digest, its path relative to the work root.
    package struct Output: Codable, Sendable, Equatable {
        package var path: String
        package var bytes: UInt64
        package var sha256: String

        package init(path: String, bytes: UInt64, sha256: String) {
            self.path = path
            self.bytes = bytes
            self.sha256 = sha256
        }
    }

    /// The plan step's id.
    package var id: String
    package var kind: PlanStepKind
    /// The tool as the image's manifest lists it, nil for a `qualityCount` step and for a step refused before its tool
    /// was looked up.
    package var tool: ExecutorToolRecord?
    package var outcome: ExecutorRunOutcome
    package var reason: String?
    /// The termination signal that interrupted the step.
    package var signal: Int32?
    package var signalName: String?
    /// The argv as run, the tool's absolute path first and every other path relative to the work root.
    package var argv: [String]
    /// The names of the variables the tool started with. The environment is built from nothing.
    package var environmentNames: [String]
    package var graceSeconds: Double
    package var deadlineSeconds: Double?
    package var toolPID: Int32?
    package var toolExitCode: Int32?
    package var toolSignal: Int32?
    package var peakResidentBytes: UInt64?
    /// True when a process outlived the grace and was sent SIGKILL.
    package var escalatedToSIGKILL: Bool
    /// The processes the executor signalled other than the tool, found under its own PID or in the tool's group.
    package var stoppedProcesses: [Int32]
    /// Orphans re-parented to the executor and reaped by their own PID.
    package var adoptedOrphansReaped: Int
    /// ISO 8601 times in UTC, from `ExecutorRunRecord.timestamp(_:)`.
    package var startedAt: String
    package var endedAt: String
    package var wallSeconds: Double
    /// Each output's digest. Written only for a step that succeeded, after the sweep.
    package var outputs: [Output]
    /// The last `stderrTailLimit` bytes of the step's standard error, decoded as UTF-8 with replacement.
    package var stderrTail: String
    /// True when the step wrote more than `stderrTailLimit` bytes, so `stderrTail` holds only the end.
    package var stderrTruncated: Bool
    /// Every byte the step wrote to standard error.
    package var stderrBytes: UInt64
    /// The standard output the plan keeps, such as the table of `seqkit stats -a -T`, byte for byte with its digest.
    package var standardOutput: ExecutorCapturedOutput?
    /// The read counts of a recipe step's input and output.
    package var inputReadCount: Int64?
    package var outputReadCount: Int64?
    /// The executor's own Q20 and Q30 count of a `qualityCount` step (BIO N6).
    package var qualityCounts: ExecutorQualityCounts?
    /// What a `storage` step did.
    package var storage: ExecutorStorageDetails?

    package init(
        id: String, kind: PlanStepKind, tool: ExecutorToolRecord?, outcome: ExecutorRunOutcome, reason: String? = nil,
        signal: Int32? = nil, signalName: String? = nil, argv: [String], environmentNames: [String],
        graceSeconds: Double, deadlineSeconds: Double?, toolPID: Int32? = nil, toolExitCode: Int32? = nil,
        toolSignal: Int32? = nil, peakResidentBytes: UInt64? = nil, escalatedToSIGKILL: Bool = false,
        stoppedProcesses: [Int32] = [], adoptedOrphansReaped: Int = 0, startedAt: String, endedAt: String,
        wallSeconds: Double, outputs: [Output] = [], stderrTail: String = "", stderrTruncated: Bool = false,
        stderrBytes: UInt64 = 0, standardOutput: ExecutorCapturedOutput? = nil, inputReadCount: Int64? = nil,
        outputReadCount: Int64? = nil, qualityCounts: ExecutorQualityCounts? = nil,
        storage: ExecutorStorageDetails? = nil
    ) {
        self.id = id
        self.kind = kind
        self.tool = tool
        self.outcome = outcome
        self.reason = reason
        self.signal = signal
        self.signalName = signalName
        self.argv = argv
        self.environmentNames = environmentNames
        self.graceSeconds = graceSeconds
        self.deadlineSeconds = deadlineSeconds
        self.toolPID = toolPID
        self.toolExitCode = toolExitCode
        self.toolSignal = toolSignal
        self.peakResidentBytes = peakResidentBytes
        self.escalatedToSIGKILL = escalatedToSIGKILL
        self.stoppedProcesses = stoppedProcesses
        self.adoptedOrphansReaped = adoptedOrphansReaped
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.wallSeconds = wallSeconds
        self.outputs = outputs
        self.stderrTail = stderrTail
        self.stderrTruncated = stderrTruncated
        self.stderrBytes = stderrBytes
        self.standardOutput = standardOutput
        self.inputReadCount = inputReadCount
        self.outputReadCount = outputReadCount
        self.qualityCounts = qualityCounts
        self.storage = storage
    }
}

/// Where a tool's version in the record came from. The executor states only a version it read (K4-14).
package enum ExecutorToolVersionSource: String, Codable, Sendable, CaseIterable {
    /// The image's tool manifest, the one source of versions on the node (tally K4.2).
    case imageManifest
}

/// A tool a step ran, as the image's manifest lists it, with its absolute path in the image.
package struct ExecutorToolRecord: Codable, Sendable, Equatable {
    package var id: String
    package var version: String
    package var build: String
    package var path: String
    package var versionSource: ExecutorToolVersionSource

    package init(id: String, version: String, build: String, path: String, versionSource: ExecutorToolVersionSource = .imageManifest) {
        self.id = id
        self.version = version
        self.build = build
        self.path = path
        self.versionSource = versionSource
    }
}

/// A file the executor read or wrote, by its path relative to the work root, SHA-256 and size.
package struct ExecutorFileDigest: Codable, Sendable, Equatable {
    package var relativePath: String
    package var sha256: String
    package var size: Int64

    package init(relativePath: String, sha256: String, size: Int64) {
        self.relativePath = relativePath
        self.sha256 = sha256
        self.size = size
    }
}

/// A standard output the record keeps byte for byte, with the SHA-256 and size of those bytes.
package struct ExecutorCapturedOutput: Codable, Sendable, Equatable {
    package var text: String
    package var sha256: String
    package var size: Int64

    package init(text: String, sha256: String, size: Int64) {
        self.text = text
        self.sha256 = sha256
        self.size = size
    }
}

/// The integer counts of one pass of `FASTQQualityFractions` over a file, never a rounded percentage (tally K4.1).
package struct ExecutorQualityCounts: Codable, Sendable, Equatable {
    /// The bases the Q20 and Q30 counts cover.
    package var baseCount: Int64
    package var q20Count: Int64
    package var q30Count: Int64
    package var recordCount: Int64
    /// The file the pass read.
    package var file: ExecutorFileDigest

    package init(baseCount: Int64, q20Count: Int64, q30Count: Int64, recordCount: Int64, file: ExecutorFileDigest) {
        self.baseCount = baseCount
        self.q20Count = q20Count
        self.q30Count = q30Count
        self.recordCount = recordCount
        self.file = file
    }
}

/// The record counts of a mixed file, by kind, as the recipe engine counts them.
package struct ExecutorMixedLayoutCounts: Codable, Sendable, Equatable {
    package var mergedReads: Int
    package var pairs: Int
    package var unpairedReads: Int

    package init(mergedReads: Int, pairs: Int, unpairedReads: Int) {
        self.mergedReads = mergedReads
        self.pairs = pairs
        self.unpairedReads = unpairedReads
    }
}

/// The writer of a storage step's gzip output, by the name `PortableBBToolsWriter.name` gives, and the tool whose
/// version stands for it. `tool` is nil when the writer is the step's own tool, such as BBTools' native BGZF writer.
package struct ExecutorStorageWriter: Codable, Sendable, Equatable {
    package var name: String
    package var tool: ExecutorToolRecord?

    package init(name: String, tool: ExecutorToolRecord? = nil) {
        self.name = name
        self.tool = tool
    }
}

/// One tool launch of a storage step, in the order the step made it (tally-r2 K4-10).
package struct ExecutorStorageLaunch: Codable, Sendable, Equatable {
    package var tool: ExecutorToolRecord
    /// The argv as run, the tool's absolute path first and every other path relative to the work root.
    package var argv: [String]
    package var environmentNames: [String]
    package var outcome: ExecutorRunOutcome
    package var toolExitCode: Int32?
    package var toolSignal: Int32?
    package var wallSeconds: Double
    /// The work-root path of the launch's standard error.
    package var stderrPath: String
    /// The N of clumpify's `Set groups to N` line and its two memory lines as printed, for a clumpify launch.
    package var clumpifyGroups: Int?
    package var clumpifyMemoryEstimateLine: String?
    package var clumpifyMemoryAvailableLine: String?

    package init(
        tool: ExecutorToolRecord, argv: [String], environmentNames: [String], outcome: ExecutorRunOutcome,
        toolExitCode: Int32? = nil, toolSignal: Int32? = nil, wallSeconds: Double, stderrPath: String,
        clumpifyGroups: Int? = nil, clumpifyMemoryEstimateLine: String? = nil, clumpifyMemoryAvailableLine: String? = nil
    ) {
        self.tool = tool
        self.argv = argv
        self.environmentNames = environmentNames
        self.outcome = outcome
        self.toolExitCode = toolExitCode
        self.toolSignal = toolSignal
        self.wallSeconds = wallSeconds
        self.stderrPath = stderrPath
        self.clumpifyGroups = clumpifyGroups
        self.clumpifyMemoryEstimateLine = clumpifyMemoryEstimateLine
        self.clumpifyMemoryAvailableLine = clumpifyMemoryAvailableLine
    }
}

/// What a storage step did (tally K4.1, tally-r2 K4-10, K4-14).
package struct ExecutorStorageDetails: Codable, Sendable, Equatable {
    /// Nil in a record written before K4-14, shown as Not recorded.
    package var writer: ExecutorStorageWriter?
    package var effectiveCompressionLevel: Int?
    /// The N of clumpify's `Set groups to N` line, nil when clumpify did not run or did not print it.
    package var clumpifyGroups: Int?
    /// Clumpify's `Memory Estimate` and `Memory Available` lines as it printed them (BIO N2-6).
    package var clumpifyMemoryEstimateLine: String?
    package var clumpifyMemoryAvailableLine: String?
    package var clumpingRan: Bool
    /// The binning scheme that ran.
    package var qualityBinning: QualityBinningScheme
    package var inputBytes: Int64
    package var outputBytes: Int64
    package var mixedLayout: ExecutorMixedLayoutCounts?
    /// Every launch the step made, the writer probe's included. Nil in a record written before M4.
    package var launches: [ExecutorStorageLaunch]?

    package init(
        writer: ExecutorStorageWriter? = nil, effectiveCompressionLevel: Int? = nil, clumpifyGroups: Int? = nil,
        clumpifyMemoryEstimateLine: String? = nil, clumpifyMemoryAvailableLine: String? = nil, clumpingRan: Bool,
        qualityBinning: QualityBinningScheme, inputBytes: Int64, outputBytes: Int64,
        mixedLayout: ExecutorMixedLayoutCounts? = nil, launches: [ExecutorStorageLaunch]? = nil
    ) {
        self.writer = writer
        self.effectiveCompressionLevel = effectiveCompressionLevel
        self.clumpifyGroups = clumpifyGroups
        self.clumpifyMemoryEstimateLine = clumpifyMemoryEstimateLine
        self.clumpifyMemoryAvailableLine = clumpifyMemoryAvailableLine
        self.clumpingRan = clumpingRan
        self.qualityBinning = qualityBinning
        self.inputBytes = inputBytes
        self.outputBytes = outputBytes
        self.mixedLayout = mixedLayout
        self.launches = launches
    }
}
