// CLIEvent.swift — Shared, typed wire schema for `lungfish-cli --json-events` progress streams.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One line of a `lungfish-cli` JSON-events stream.
///
/// Before this type existed, each long-running CLI subcommand (tree
/// inference, tree transform, MSA actions, variant calling, primer trim,
/// imports, …) declared its own private `Event` struct on the CLI side and
/// its own untyped `dict["message"] as? String` parser on the GUI side
/// (ARC-02, SIMP-04). A renamed field or event name broke progress reporting
/// silently, because a parse failure only logged a warning.
///
/// `CLIEvent` is the one schema both sides share. The CLI emits it with
/// ``CLIEventEmitter``; the GUI decodes it with ``CLIEventLineDecoder`` inside
/// `CLISubprocessTransport` (LungfishKit).
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

    private enum CodingKeys: String, CodingKey {
        case event
        case progress
        case message
        case output
        case outputs
        case error
        case detail
        case level
        case role
        case path
    }

    private enum EventName {
        static let start = "start"
        static let progress = "progress"
        static let log = "log"
        static let output = "output"
        static let complete = "complete"
        static let failed = "failed"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
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
            let level = try container.decodeIfPresent(CLIEventLogLevel.self, forKey: .level) ?? .info
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
                DecodingError.Context(codingPath: [CodingKeys.event], debugDescription: "Unknown CLIEvent name '\(name)'")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
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

/// Encodes and writes one `CLIEvent` per line to a sink, from a `lungfish-cli`
/// subcommand. Every migrated subcommand (tree infer, tree transform, MSA,
/// variants, primer trim, imports) constructs one of these instead of a
/// private per-command `Event` struct.
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

    public func emitFailed(_ message: String, detail: String? = nil) {
        emit(.failed(message: message, detail: detail))
    }

    public func emit(_ event: CLIEvent) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? encoder.encode(event), let line = String(data: data, encoding: .utf8) else {
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

    /// Parses a single line of text. Returns `nil` for blank lines and lines
    /// that are not a JSON object (for example plain diagnostic output mixed
    /// into stdout), so callers can skip non-event chatter without failing.
    /// Throws only when the line looks like an event but does not decode.
    public func decode(line: String) throws -> CLIEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try decoder.decode(CLIEvent.self, from: data)
    }
}
