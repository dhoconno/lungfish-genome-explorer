// CLIEventCompatCorpus.swift - The frozen version 1 CLIEvent reader and the captured version 1 runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// One frozen copy of how a version 1 app reads an event line, and the list and place of the
// version 1 transcripts captured from real runs. Every lane that shows a change keeps version 1
// apps working reads them from here, so no lane keeps a second copy of the reader.

import Foundation
import LungfishWorkflow

// MARK: - The frozen version 1 reader

/// How a version 1 app reads one event line, copied from the shipped decoder at
/// program commit 90d34c550 and then frozen. It has its own types on purpose, so
/// no later change to `CLIEvent` can move it.
///
/// Never edit this type. It stands for every `lungfish-cli` and app pair that
/// was released before the version 2 envelope, and `CLIEventCompatibilityTests` shows that
/// whatever the writer prints today, this reader still gets the same outcome and
/// the same outputs. A reader with new behavior belongs in a new type.
public enum FrozenCLIEventV1: Equatable, Decodable {
    case start(message: String)
    case progress(fraction: Double, message: String)
    case log(level: Level, message: String)
    case output(path: String, role: String)
    case complete(outputs: [String], message: String?)
    case failed(message: String, detail: String?)

    public enum Level: String, Equatable, Decodable {
        case debug
        case info
        case warning
        case error
    }

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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .event)
        switch name {
        case "start":
            let message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
            self = .start(message: message)
        case "progress":
            let fraction = try container.decodeIfPresent(Double.self, forKey: .progress) ?? 0
            let message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
            self = .progress(fraction: max(0, min(1, fraction)), message: message)
        case "log":
            let level = try container.decodeIfPresent(Level.self, forKey: .level) ?? .info
            let message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
            self = .log(level: level, message: message)
        case "output":
            let path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
            let role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
            self = .output(path: path, role: role)
        case "complete":
            var outputs = try container.decodeIfPresent([String].self, forKey: .outputs) ?? []
            if outputs.isEmpty, let singular = try container.decodeIfPresent(String.self, forKey: .output),
               !singular.isEmpty {
                outputs = [singular]
            }
            let message = try container.decodeIfPresent(String.self, forKey: .message)
            self = .complete(outputs: outputs, message: message)
        case "failed":
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

    /// The same event as the shared type, for comparing the two readers.
    public var asCLIEvent: CLIEvent {
        switch self {
        case let .start(message):
            return .start(message: message)
        case let .progress(fraction, message):
            return .progress(fraction: fraction, message: message)
        case let .log(level, message):
            return .log(level: CLIEventLogLevel(rawValue: level.rawValue) ?? .info, message: message)
        case let .output(path, role):
            return .output(path: path, role: role)
        case let .complete(outputs, message):
            return .complete(outputs: outputs, message: message)
        case let .failed(message, detail):
            return .failed(message: message, detail: detail)
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .complete, .failed: return true
        case .start, .progress, .log, .output: return false
        }
    }
}

/// The line step of the frozen reader. A line that is not a JSON object is
/// chatter and reads as nil, and a line that looks like an event but does not
/// decode throws.
public struct FrozenCLIEventV1LineDecoder {
    private let decoder = JSONDecoder()

    public init() {}

    public func decode(line: String) throws -> FrozenCLIEventV1? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try decoder.decode(FrozenCLIEventV1.self, from: data)
    }
}

// MARK: - The captured runs

/// The version 1 transcripts captured from real runs, and where they are.
public enum CLIEventCompatCorpus {
    /// The captured runs in `Tests/Fixtures/cli-events/v1`, by file name without the extension.
    /// A run added to or removed from the folder needs an edit here too.
    public static let capturedRuns = [
        "fastq-platform",
        "fastq-platform-failed",
        "msa-annotate-add",
        "msa-annotate-delete",
        "msa-annotate-edit",
        "msa-annotate-project",
        "msa-consensus",
        "msa-discriminating-sites",
        "msa-distance",
        "msa-export",
        "msa-export-failed",
        "msa-export-with-warning",
        "msa-extract",
        "msa-mask-columns",
        "msa-trim-columns",
        "tree-export-subtree",
        "tree-extract-subtree",
        "tree-relabel",
        "tree-reroot",
        "tree-reroot-failed",
    ]

    /// `Tests/Fixtures/cli-events/v1`, found from the checkout that holds this file.
    public static var v1Folder: URL {
        ProvenanceCompatCorpus.repositoryRoot
            .appendingPathComponent("Tests/Fixtures/cli-events/v1", isDirectory: true)
    }
}
