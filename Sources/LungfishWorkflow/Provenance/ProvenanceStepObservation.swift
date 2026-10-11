// ProvenanceStepObservation.swift - What ToolProcess observed about the launch of a declared step
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// What ToolProcess observed about the launch of a declared step, kept under the step's `observation`
/// key (`docs/formats/provenance.md`).
///
/// It says how the step's process ended, why ToolProcess stopped it, whether its output was read or
/// written whole, what its adapter changed in the environment and where the step stood in its run. A
/// writer fills it only for a step it declared around the step's one launch, so a step without it reads
/// as not observed. It never holds the executed argv, which never replaces the step's own, nor the peak
/// memory that `wait4` reported, which no record writes until a golden normalizer rule for it is
/// approved (Phase 2.7 decision P4).
public struct ProvenanceStepObservation: Codable, Sendable, Equatable {
    /// How the step's process ended, or why it never ran.
    public enum Termination: Sendable, Equatable {
        /// It called exit with this status.
        case exited(code: Int)
        /// An uncaught signal with this number ended it. The step's `exitStatus` holds the same number,
        /// as it always has.
        case signaled(signal: Int)
        /// It ran, but something outside ToolProcess reaped it, so its status is unknown.
        case statusLost
        /// It could not be launched, or one of its files could not be opened.
        case launchFailed(reason: String)
        /// It never launched, because its run stopped first or an earlier stage could not launch.
        case notLaunched
    }

    /// Why ToolProcess signaled the step's process itself.
    public enum Stop: Sendable, Equatable {
        /// The task that ran it was cancelled.
        case cancelled
        /// The run passed a limit after this many seconds.
        case timedOut(limit: TimeoutLimit, seconds: Double)
        /// Another stage of its pipeline failed or could not launch.
        case pipelineStageFailed(stage: Int)
    }

    /// Which limit a run passed.
    public enum TimeoutLimit: String, Codable, Sendable, Equatable {
        /// The run lasted longer than its limit.
        case wallClock
        /// No captured stream wrote anything for that long.
        case idle
    }

    /// What the step's adapter changed in the environment it launched the step with. It never holds the
    /// inherited environment.
    public struct Environment: Codable, Sendable, Equatable {
        /// What the change starts from.
        public enum Base: String, Codable, Sendable, Equatable {
            /// The environment of the process that runs LGE.
            case inherited
            /// An empty environment, so the adapter set every variable.
            case hermetic
        }

        public let base: Base
        /// The name of every variable the adapter set, sorted.
        public let changed: [String]
        /// The sanitized value of each variable whose value a record keeps
        /// (`ToolProcessEnvironmentChange.valueRecordedNames`).
        public let values: [String: String]
        /// The names the adapter removed from an inherited base, sorted.
        public let unset: [String]
        /// The sanitized PATH entries the adapter put before the base PATH, in order.
        public let pathPrefix: [String]

        public init(base: Base, changed: [String], values: [String: String], unset: [String], pathPrefix: [String]) {
            self.base = base
            self.changed = changed
            self.values = values
            self.unset = unset
            self.pathPrefix = pathPrefix
        }

        private enum CodingKeys: String, CodingKey {
            case base, changed, values, unset, pathPrefix
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            base = try container.decode(Base.self, forKey: .base)
            changed = try container.decode([String].self, forKey: .changed)
            values = try container.decodeIfPresent([String: String].self, forKey: .values) ?? [:]
            unset = try container.decodeIfPresent([String].self, forKey: .unset) ?? []
            pathPrefix = try container.decode([String].self, forKey: .pathPrefix)
        }

        /// `values` and `unset` are written only when they hold something.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(base, forKey: .base)
            try container.encode(changed, forKey: .changed)
            try container.encodeIfPresent(values.isEmpty ? nil : values, forKey: .values)
            try container.encodeIfPresent(unset.isEmpty ? nil : unset, forKey: .unset)
            try container.encode(pathPrefix, forKey: .pathPrefix)
        }
    }

    /// Where the step stood in its run, from 0, and how many stages the run declared.
    public struct Stage: Codable, Sendable, Equatable {
        public let index: Int
        public let count: Int

        public init(index: Int, count: Int) {
            self.index = index
            self.count = count
        }
    }

    public let termination: Termination
    /// Nil when ToolProcess did not stop the step itself.
    public let stop: Stop?
    /// Whether every output of the step was read or written whole. Nil, and shown as Not recorded, for
    /// a stage that streamed its stdout, whose reader is judged after the run, and for a stage that
    /// never launched (Phase 2.7 decision P3).
    public let outputComplete: Bool?
    /// Nil when the adapter did not say what it changed.
    public let environment: Environment?
    public let stage: Stage

    public init(
        termination: Termination,
        stop: Stop?,
        outputComplete: Bool?,
        environment: Environment?,
        stage: Stage
    ) {
        self.termination = termination
        self.stop = stop
        self.outputComplete = outputComplete
        self.environment = environment
        self.stage = stage
    }

    private enum CodingKeys: String, CodingKey {
        case termination, stop, outputComplete, environment, stage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        termination = try container.decode(Termination.self, forKey: .termination)
        stop = try container.decodeIfPresent(Stop.self, forKey: .stop)
        outputComplete = try container.decodeIfPresent(Bool.self, forKey: .outputComplete)
        environment = try container.decodeIfPresent(Environment.self, forKey: .environment)
        stage = try container.decode(Stage.self, forKey: .stage)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(termination, forKey: .termination)
        try container.encodeIfPresent(stop, forKey: .stop)
        try container.encodeIfPresent(outputComplete, forKey: .outputComplete)
        try container.encodeIfPresent(environment, forKey: .environment)
        try container.encode(stage, forKey: .stage)
    }
}

// MARK: - From the ToolProcess observation

extension ProvenanceStepObservation {
    /// What one stage of a ToolProcess run did, as a record keeps it. The stage's argv, times, stderr,
    /// identity hint and peak memory are left out.
    public init(_ stage: ToolProcessRunObservation.Stage) {
        self.init(
            termination: Termination(stage.ending),
            stop: stage.stop.map(Stop.init),
            outputComplete: stage.outputComplete,
            environment: stage.environmentChange.map(Environment.init),
            stage: Stage(index: stage.index, count: stage.stageCount)
        )
    }
}

extension ProvenanceStepObservation.Termination {
    init(_ ending: ToolProcessRunObservation.Ending) {
        switch ending {
        case .terminated(.exited(let code)): self = .exited(code: Int(code))
        case .terminated(.signaled(let signal)): self = .signaled(signal: Int(signal))
        case .statusLost: self = .statusLost
        case .launchFailed(let reason): self = .launchFailed(reason: reason)
        case .notLaunched: self = .notLaunched
        }
    }
}

extension ProvenanceStepObservation.Stop {
    init(_ stop: ToolProcessStop) {
        switch stop {
        case .cancelled: self = .cancelled
        case .timedOut(.wallClock(let limit)): self = .timedOut(limit: .wallClock, seconds: Self.seconds(limit))
        case .timedOut(.idle(let limit)): self = .timedOut(limit: .idle, seconds: Self.seconds(limit))
        case .pipelineStageFailed(let stage): self = .pipelineStageFailed(stage: stage)
        }
    }

    /// Divides by 1e18, which a double holds exactly, so 1.5 seconds reads 1.5.
    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

extension ProvenanceStepObservation.Environment {
    init(_ change: ToolProcessEnvironmentChange) {
        self.init(
            base: change.base == .hermetic ? .hermetic : .inherited,
            changed: change.set.map(\.name),
            values: Dictionary(
                change.set.compactMap { variable in variable.value.map { (variable.name, $0) } },
                uniquingKeysWith: { first, _ in first }
            ),
            unset: change.unset,
            pathPrefix: change.pathPrefix
        )
    }
}

// MARK: - Coding of the cases

extension ProvenanceStepObservation.Termination: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, code, signal, reason
    }

    private enum Kind: String, Codable {
        case exited, signaled, statusLost, launchFailed, notLaunched
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .exited: self = .exited(code: try container.decode(Int.self, forKey: .code))
        case .signaled: self = .signaled(signal: try container.decode(Int.self, forKey: .signal))
        case .statusLost: self = .statusLost
        case .launchFailed: self = .launchFailed(reason: try container.decode(String.self, forKey: .reason))
        case .notLaunched: self = .notLaunched
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .exited(let code):
            try container.encode(Kind.exited, forKey: .kind)
            try container.encode(code, forKey: .code)
        case .signaled(let signal):
            try container.encode(Kind.signaled, forKey: .kind)
            try container.encode(signal, forKey: .signal)
        case .statusLost:
            try container.encode(Kind.statusLost, forKey: .kind)
        case .launchFailed(let reason):
            try container.encode(Kind.launchFailed, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .notLaunched:
            try container.encode(Kind.notLaunched, forKey: .kind)
        }
    }
}

extension ProvenanceStepObservation.Stop: Codable {
    private enum CodingKeys: String, CodingKey {
        case reason, limit, seconds, stage
    }

    private enum Reason: String, Codable {
        case cancelled, timedOut, pipelineStageFailed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Reason.self, forKey: .reason) {
        case .cancelled:
            self = .cancelled
        case .timedOut:
            self = .timedOut(
                limit: try container.decode(ProvenanceStepObservation.TimeoutLimit.self, forKey: .limit),
                seconds: try container.decode(Double.self, forKey: .seconds)
            )
        case .pipelineStageFailed:
            self = .pipelineStageFailed(stage: try container.decode(Int.self, forKey: .stage))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cancelled:
            try container.encode(Reason.cancelled, forKey: .reason)
        case .timedOut(let limit, let seconds):
            try container.encode(Reason.timedOut, forKey: .reason)
            try container.encode(limit, forKey: .limit)
            try container.encode(seconds, forKey: .seconds)
        case .pipelineStageFailed(let stage):
            try container.encode(Reason.pipelineStageFailed, forKey: .reason)
            try container.encode(stage, forKey: .stage)
        }
    }
}
