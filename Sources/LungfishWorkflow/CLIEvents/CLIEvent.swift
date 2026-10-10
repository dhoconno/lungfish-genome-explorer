// CLIEvent.swift — Shared, typed wire schema for `lungfish-cli --json-events` progress streams.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One event of a `lungfish-cli` JSON-events stream.
///
/// Before this type existed, each long-running CLI subcommand (tree
/// inference, MSA actions, variant calling, primer trim, imports, …) declared
/// its own private `Event` struct and its own untyped
/// `dict["message"] as? String` parser on the GUI side. A renamed field or event
/// name broke progress reporting silently. `CLIEvent` is the one schema both
/// sides share, emitted by ``CLIEventEmitter`` and read by ``CLIEventLineDecoder``
/// inside `CLISubprocessTransport` (LungfishKit).
///
/// On the wire an event travels in a ``CLIEventLine``, which adds the schema
/// version and typed artifacts and keeps these cases, so the app's exhaustive
/// switches do not change.
public enum CLIEvent: Sendable, Equatable, Codable {
    /// The operation has begun. `message` is shown as the first detail line.
    case start(message: String)
    /// Progress update. `fraction` is clamped to `0...1` by the emitter.
    case progress(fraction: Double, message: String)
    /// A free-form log line at a given severity, distinct from progress.
    case log(level: CLIEventLogLevel, message: String)
    /// An output artifact became available mid-run (rare; most commands only
    /// report outputs at ``complete(outputs:message:)``).
    case output(path: String, role: String)
    /// The operation finished successfully. `outputs` lists every produced
    /// path (bundle directories, files); most commands report exactly one.
    case complete(outputs: [String], message: String?)
    /// The operation failed. `detail` is optional extra context (for example
    /// stderr) beyond the human-readable `message`.
    case failed(message: String, detail: String?)

    /// Every key of a line, shared by the event and its ``CLIEventLine`` envelope so
    /// one container writes and reads the whole object.
    enum WireKey: String, CodingKey {
        case event
        case schemaVersion
        case progress
        case message
        case output
        case outputs
        case error
        case detail
        case level
        case role
        case path
        case artifacts
    }

    enum EventName {
        static let start = "start"
        static let progress = "progress"
        static let log = "log"
        static let output = "output"
        static let complete = "complete"
        static let failed = "failed"

        /// The names this reader knows. Any other name is an ignored line.
        static let all: Set<String> = [start, progress, log, output, complete, failed]
    }

    /// The `event` key this case is written under.
    var wireName: String {
        switch self {
        case .start: return EventName.start
        case .progress: return EventName.progress
        case .log: return EventName.log
        case .output: return EventName.output
        case .complete: return EventName.complete
        case .failed: return EventName.failed
        }
    }

    /// Whether a line of this event may carry typed artifacts.
    var carriesArtifacts: Bool {
        switch self {
        case .complete, .output: return true
        case .start, .progress, .log, .failed: return false
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WireKey.self)
        let name = try container.decode(String.self, forKey: .event)
        switch name {
        case EventName.start:
            let message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
            self = .start(message: message)
        case EventName.progress:
            let fraction = try container.decodeIfPresent(Double.self, forKey: .progress) ?? 0
            let message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
            self = .progress(fraction: max(0, min(1, fraction)), message: message)
        case EventName.log:
            // A level this reader does not know reads as info, so a writer may add one.
            let level = (try? container.decodeIfPresent(CLIEventLogLevel.self, forKey: .level)) ?? .info
            let message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
            self = .log(level: level, message: message)
        case EventName.output:
            let path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
            let role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
            self = .output(path: path, role: role)
        case EventName.complete:
            var outputs = try container.decodeIfPresent([String].self, forKey: .outputs) ?? []
            if outputs.isEmpty, let singular = try container.decodeIfPresent(String.self, forKey: .output),
               !singular.isEmpty {
                outputs = [singular]
            }
            let message = try container.decodeIfPresent(String.self, forKey: .message)
            self = .complete(outputs: outputs, message: message)
        case EventName.failed:
            let message = try container.decodeIfPresent(String.self, forKey: .error)
                ?? container.decodeIfPresent(String.self, forKey: .message)
                ?? "Operation failed"
            let detail = try container.decodeIfPresent(String.self, forKey: .detail)
            self = .failed(message: message, detail: detail)
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [WireKey.event], debugDescription: "Unknown CLIEvent name '\(name)'")
            )
        }
    }

    /// Writes the event as a line of the current schema version, without artifacts.
    public func encode(to encoder: Encoder) throws {
        try encodeLine(to: encoder, schemaVersion: CLIEventLine.currentSchemaVersion, artifacts: [])
    }

    /// The one place a line's keys are written, for the event alone and for a
    /// ``CLIEventLine``. Every line carries `schemaVersion`, and the keys older apps
    /// read stay as they were, so version 1 readers see the same event.
    func encodeLine(to encoder: Encoder, schemaVersion: Int, artifacts: [CLIEventArtifact]) throws {
        var container = encoder.container(keyedBy: WireKey.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        if carriesArtifacts, !artifacts.isEmpty {
            try container.encode(artifacts, forKey: .artifacts)
        }
        switch self {
        case let .start(message):
            try container.encode(EventName.start, forKey: .event)
            try container.encode(message, forKey: .message)
            try container.encode(0.0, forKey: .progress)
        case let .progress(fraction, message):
            try container.encode(EventName.progress, forKey: .event)
            try container.encode(max(0, min(1, fraction)), forKey: .progress)
            try container.encode(message, forKey: .message)
        case let .log(level, message):
            try container.encode(EventName.log, forKey: .event)
            try container.encode(level, forKey: .level)
            try container.encode(message, forKey: .message)
        case let .output(path, role):
            try container.encode(EventName.output, forKey: .event)
            try container.encode(path, forKey: .path)
            try container.encode(role, forKey: .role)
        case let .complete(outputs, message):
            try container.encode(EventName.complete, forKey: .event)
            try container.encode(outputs, forKey: .outputs)
            if let first = outputs.first {
                try container.encode(first, forKey: .output)
            }
            try container.encodeIfPresent(message, forKey: .message)
            try container.encode(1.0, forKey: .progress)
        case let .failed(message, detail):
            try container.encode(EventName.failed, forKey: .event)
            try container.encode(message, forKey: .error)
            try container.encodeIfPresent(detail, forKey: .detail)
        }
    }
}

/// Severity for ``CLIEvent/log(level:message:)``, mirroring
/// `OperationLogLevel` (LungfishKit) without creating a dependency from
/// Workflow onto Kit.
public enum CLIEventLogLevel: String, Sendable, Equatable, Codable {
    case debug
    case info
    case warning
    case error
}

/// Encodes and writes one ``CLIEventLine`` per line to a sink, from a
/// `lungfish-cli` subcommand. Every migrated subcommand (tree infer, tree
/// transform, MSA, variants, primer trim, imports) constructs one of these instead
/// of a private per-command `Event` struct. Each line carries the current
/// `schemaVersion`. A command that prints the line uses `printEventLine`
/// (LungfishCLI) so each one is flushed, and prints its human text with
/// `printHumanLine`, so standard output carries nothing but event lines.
public final class CLIEventEmitter: @unchecked Sendable {
    private let enabled: Bool
    private let emitLine: (String) -> Void
    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// - Parameters:
    ///   - enabled: When `false` (no `--json-events` flag), `emit` is a no-op.
    ///   - emit: Called with one already-terminated-by-the-caller line of
    ///     JSON. Typically a `print` line writer. Not marked `@Sendable`
    ///     because CLI commands pass plain, non-escaping-across-threads
    ///     closures like `{ print($0) }`; `CLIEventEmitter` itself is
    ///     `@unchecked Sendable` and serializes access to `emit` with a lock.
    public init(enabled: Bool, emit: @escaping (String) -> Void) {
        self.enabled = enabled
        self.emitLine = emit
    }

    public func emitStart(_ message: String) {
        emit(.start(message: message))
    }

    /// Labeled-argument spelling matching every existing CLI command call site.
    public func emitStart(message: String) {
        emitStart(message)
    }

    public func emitProgress(_ fraction: Double, message: String) {
        emit(.progress(fraction: fraction, message: message))
    }

    public func emitLog(_ level: CLIEventLogLevel, _ message: String) {
        emit(.log(level: level, message: message))
    }

    public func emitOutput(path: String, role: String) {
        emit(.output(path: path, role: role))
    }

    public func emitComplete(outputs: [String], message: String? = nil) {
        emit(.complete(outputs: outputs, message: message))
    }

    public func emitComplete(output: String, message: String? = nil) {
        emitComplete(outputs: [output], message: message)
    }

    /// A completion that also describes its outputs. `outputs` keeps the order
    /// version 1 readers rely on, and `artifacts` adds what they cannot say.
    public func emitComplete(outputs: [String], artifacts: [CLIEventArtifact], message: String? = nil) {
        emit(.complete(outputs: outputs, message: message), artifacts: artifacts)
    }

    public func emitFailed(_ message: String, detail: String? = nil) {
        emit(.failed(message: message, detail: detail))
    }

    public func emit(_ event: CLIEvent) {
        emit(event, artifacts: [])
    }

    /// Writes `event` with typed artifacts. Only `complete` and `output` lines carry
    /// them, so artifacts given with any other event are left off.
    public func emit(_ event: CLIEvent, artifacts: [CLIEventArtifact]) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        let envelope = CLIEventLine(event: event, artifacts: artifacts)
        guard let data = try? encoder.encode(envelope), let line = String(data: data, encoding: .utf8) else {
            return
        }
        emitLine(line)
    }
}

/// Decodes newline-delimited `CLIEvent` JSON from a byte stream, one line at
/// a time. Used by `CLISubprocessTransport` (LungfishKit) to turn a
/// subprocess's stdout into a sequence of typed events.
public struct CLIEventLineDecoder: Sendable {
    private let decoder = JSONDecoder()

    public init() {}

    /// Parses a single line of text into its envelope. Returns `nil` for blank
    /// lines and lines that are not a JSON object (for example plain diagnostic
    /// output mixed into stdout), so callers can skip non-event chatter without
    /// failing.
    ///
    /// A line from a newer writer never throws. An unknown event name, a higher
    /// schema version, an unknown key and an unknown artifact kind all decode, and
    /// a line whose event this reader does not know comes back with a nil
    /// ``CLIEventLine/event`` and is noted at debug level. Throws only when the line
    /// is not valid JSON, or names a known event with unreadable fields at a schema
    /// version this reader knows.
    public func decodeLine(_ line: String) throws -> CLIEventLine? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        let envelope = try decoder.decode(CLIEventLine.self, from: data)
        envelope.reportIfIgnored()
        return envelope
    }

    /// The event of a line, for callers that need nothing else. Returns `nil` for
    /// chatter and for a line whose event this reader does not know. Throws as
    /// ``decodeLine(_:)`` does.
    public func decode(line: String) throws -> CLIEvent? {
        try decodeLine(line)?.event
    }
}
