// ToolProcessObservation.swift - The provenance observer hook of ToolProcess and what it delivers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The task-local provenance observer of ToolProcess runs
/// (`docs/contracts/RECORDING-PROVENANCE.md`, "The ToolProcess observer hook").
///
/// An adapter binds an observer around the one launch of a declared
/// provenance step.
///
/// ```swift
/// let result = try await ToolProcessObservation.$observer.withValue(observer) {
///     try await ToolProcess.run(spec)
/// }
/// ```
///
/// A run built inside that scope, whether a single run, a handle or a
/// pipeline, reads the observer once where it is built, in the caller's
/// context, and delivers exactly one ``ToolProcessRunObservation`` with one
/// entry per stage. That holds for a launch failure and a cancellation too.
/// A run built outside the scope delivers nothing, so a version probe that
/// the same adapter runs never becomes a step. An invalid spec builds no run
/// and delivers nothing.
///
/// A task that `Task {}` starts inside the scope inherits the binding, and
/// `Task.detached` or a hop to a GCD queue drops it. Bind the observer around
/// the declared launch alone, never around a scope that also runs probes.
public enum ToolProcessObservation {
    /// The observer of runs built in the current task, or nil for none.
    @TaskLocal public static var observer: ToolProcessObserver?
}

/// Receives the one observation of each run built while it is bound.
///
/// `deliver` runs on the run's serial queue once the run is over, after its
/// stages are reaped and before anything waiting on the run wakes. That is
/// before ``ToolProcess/run(_:onEvent:onLaunch:)``,
/// ``ToolProcess/runPipeline(_:timeout:idleTimeout:failurePolicy:onEvent:onLaunch:)``
/// and ``ToolProcess/runBlocking(_:cancellation:onEvent:onLaunch:)`` return or
/// throw, before ``ToolProcessRun/result()`` and
/// ``ToolProcessRun/waitBlocking()`` return, and also when nobody waits on a
/// dropped handle.
///
/// Keep it to an append into a buffer that returns at once. A waiter on the
/// run cannot wake until it returns, so it never waits on the run or on
/// anything that waits on it, and it never hashes, reads a file, probes a
/// version or starts a `Task`. Runs in parallel deliver from their own queues
/// at the same moment, so the buffer takes a lock, and
/// ``ToolProcessRunObservation/sequenceNumber`` gives their launch order.
public struct ToolProcessObserver: Sendable {
    /// Called once per run with what it did.
    public let deliver: @Sendable (ToolProcessRunObservation) -> Void

    public init(deliver: @escaping @Sendable (ToolProcessRunObservation) -> Void) {
        self.deliver = deliver
    }
}

/// What one ToolProcess run did, for a provenance record, with one entry per
/// stage the run declared.
///
/// The entries come from the same per-stage values that the run's result or
/// error carries, so a record and the result never disagree. The observation
/// holds no stdout bytes, and its stderr is bounded before delivery.
public struct ToolProcessRunObservation: Sendable, Equatable {
    /// The order in which runs with an observer were built in this process,
    /// so a buffer can order observations by launch rather than by the
    /// order their runs ended.
    public let sequenceNumber: UInt64
    /// The wall-clock time when the run was built, just before its first
    /// launch, read through the provenance time source.
    public let startedAt: Date
    /// Time from the first launch until every stage exited and its output
    /// was drained, on a monotonic clock, as ``ToolPipelineResult/wallTime``
    /// reports it.
    public let wallTime: Duration
    /// Why ToolProcess stopped the whole run, a cancellation or a limit, or
    /// nil. A stage's own ``Stage/stop`` also says when another stage's
    /// failure stopped it.
    public let stop: ToolProcessStop?
    /// One entry per declared stage, in stage order, whether it launched or not.
    public let stages: [Stage]

    public init(sequenceNumber: UInt64, startedAt: Date, wallTime: Duration, stop: ToolProcessStop?, stages: [Stage]) {
        self.sequenceNumber = sequenceNumber
        self.startedAt = startedAt
        self.wallTime = wallTime
        self.stop = stop
        self.stages = stages
    }
}

extension ToolProcessRunObservation {
    /// How a stage ended, or why it never ran.
    public enum Ending: Sendable, Equatable {
        /// The stage ran and ended this way, as its result reports.
        case terminated(ToolProcessTermination)
        /// The stage ran, but something outside ToolProcess reaped it, so its
        /// status is unknown. Its result reports `exited(code: -1)`, which a
        /// record must not copy as an exit status.
        case statusLost
        /// The stage could not be launched, or one of its input or output
        /// files could not be opened.
        case launchFailed(reason: String)
        /// The stage never launched, because the run stopped first or an
        /// earlier stage could not launch.
        case notLaunched

        /// True when the stage's process was spawned.
        public var launched: Bool {
            switch self {
            case .terminated, .statusLost: return true
            case .launchFailed, .notLaunched: return false
            }
        }
    }

    /// The part of a stage's captured stderr that a record can keep, its
    /// first ``headByteLimit`` and last ``tailByteLimit`` bytes.
    ///
    /// The limits are four bytes per character over the 2,048 and 8,192
    /// characters of ``ProvenanceStderr``, so a large capture never sits in
    /// an observation buffer.
    ///
    /// No recorder keeps an excerpt yet. A recorder first leaves out the first
    /// line of the decoded ``head`` when ``earlierBytesDropped`` is true,
    /// because that line lost its start. When ``omittedByteCount`` is 0 the
    /// decoded ``head`` then holds the rest of the capture, and the recorder
    /// applies ``ProvenanceStderr/truncated(_:)`` to it. Otherwise it never
    /// joins characters of ``head`` and ``tail`` and never applies
    /// `truncated(_:)` to their join, because the cut keeps whole lines only
    /// and keeps nothing of a window that holds no line break (Phase 2.8,
    /// decision P4), so a join can keep a fragment of a path. It cuts the
    /// decoded ``head`` by the head rule and the decoded ``tail`` by the tail
    /// rule, each on its own. For a capture of four-byte characters the excerpt
    /// lacks the character after the head window and the one before the tail
    /// window, which the cut also reads, so the recorder counts such an edge as
    /// no line break and keeps one line less. ``ProvenanceStderr`` has no public
    /// entry point for one side yet, and the first recorder adds it.
    public struct StderrExcerpt: Sendable, Equatable {
        /// Bytes kept from the start of the capture.
        public static let headByteLimit = ProvenanceStderr.headLength * 4
        /// Bytes kept from the end of a capture longer than both limits together.
        public static let tailByteLimit = ProvenanceStderr.tailLength * 4

        /// The whole capture when it fits in both limits together, and its
        /// first ``headByteLimit`` bytes otherwise.
        public let head: Data
        /// Empty when ``head`` holds the whole capture, and the last
        /// ``tailByteLimit`` bytes otherwise.
        public let tail: Data
        /// How many bytes between ``head`` and ``tail`` were left out.
        public let omittedByteCount: Int
        /// True when the capture limit of the spec had already dropped earlier
        /// bytes, so ``head`` is not the start of what the stage wrote.
        public let earlierBytesDropped: Bool

        /// Cuts `captured` to the two limits. The kept bytes are copies, so
        /// the excerpt never holds the capture's storage.
        public init(captured: Data, earlierBytesDropped: Bool) {
            let limit = Self.headByteLimit + Self.tailByteLimit
            if captured.count <= limit {
                head = Self.copy(captured)
                tail = Data()
                omittedByteCount = 0
            } else {
                head = Self.copy(captured.prefix(Self.headByteLimit))
                tail = Self.copy(captured.suffix(Self.tailByteLimit))
                omittedByteCount = captured.count - limit
            }
            self.earlierBytesDropped = earlierBytesDropped
        }

        private static func copy(_ bytes: Data) -> Data {
            bytes.withUnsafeBytes { Data($0) }
        }
    }

    /// What one stage did.
    public struct Stage: Sendable, Equatable {
        /// The stage's position in the run, from 0.
        public let index: Int
        /// How many stages the run declared, 1 for a single run.
        public let stageCount: Int
        /// The spec's label.
        public let label: String
        /// The argv the stage was or would have been launched with, the
        /// executable path first.
        public let argv: [String]
        /// The working directory, or nil for the caller's current directory.
        public let workingDirectory: URL?
        /// How the stage ended, or why it never ran.
        public let ending: Ending
        /// The wall-clock time of the launch, the run's ``ToolProcessRunObservation/startedAt``
        /// plus the time to the launch on a monotonic clock, or nil when the
        /// stage never launched.
        public let startedAt: Date?
        /// Time from launch to the exit of the stage's root process, on a
        /// monotonic clock, or nil when the stage never launched.
        public let wallTime: Duration?
        /// Set when ToolProcess signaled the stage's group and tree itself.
        public let stop: ToolProcessStop?
        /// Whether every output of the stage was read or written whole, as
        /// ``ToolProcessResult/outputComplete`` reports, or nil when not
        /// recorded. It is not recorded for a stage that streams stdout,
        /// whose reader is judged after the run ends, nor for a stage that
        /// never launched.
        public let outputComplete: Bool?
        /// True when the stage failed on its own account, by the rule of
        /// ``ToolPipelineResult/failedStageIndices``. A stage that the
        /// failure policy or a stop ended is not one, nor a stage killed by
        /// SIGPIPE whose downstream stage finished cleanly, nor a stage that
        /// never launched. A stage that could not launch is one.
        public let failedOnItsOwn: Bool
        /// The bounded stderr, or nil when the stage's stderr was not
        /// captured or the stage never launched.
        public let stderr: StderrExcerpt?
        /// What the adapter changed in the environment, or nil when it did not say.
        public let environmentChange: ToolProcessEnvironmentChange?
        /// The adapter's name for what ran, such as a conda environment or a
        /// `NativeTool` name, or nil.
        public let identityHint: String?
        /// The peak resident memory of the stage's root process and of the
        /// descendants it waited for, from `wait4` (`ru_maxrss`), or nil when
        /// the stage was not reaped by ToolProcess.
        ///
        /// No record writes it until a golden normalizer rule for it is
        /// approved (Phase 2.7 decision P4). A record consumer that copies it
        /// lands together with that rule.
        public let observedPeakMemoryBytes: UInt64?

        public init(
            index: Int,
            stageCount: Int,
            label: String,
            argv: [String],
            workingDirectory: URL?,
            ending: Ending,
            startedAt: Date?,
            wallTime: Duration?,
            stop: ToolProcessStop?,
            outputComplete: Bool?,
            failedOnItsOwn: Bool,
            stderr: StderrExcerpt?,
            environmentChange: ToolProcessEnvironmentChange?,
            identityHint: String?,
            observedPeakMemoryBytes: UInt64?
        ) {
            self.index = index
            self.stageCount = stageCount
            self.label = label
            self.argv = argv
            self.workingDirectory = workingDirectory
            self.ending = ending
            self.startedAt = startedAt
            self.wallTime = wallTime
            self.stop = stop
            self.outputComplete = outputComplete
            self.failedOnItsOwn = failedOnItsOwn
            self.stderr = stderr
            self.environmentChange = environmentChange
            self.identityHint = identityHint
            self.observedPeakMemoryBytes = observedPeakMemoryBytes
        }
    }
}
