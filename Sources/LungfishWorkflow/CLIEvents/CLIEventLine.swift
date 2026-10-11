// CLIEventLine.swift — The envelope of one `lungfish-cli` event line, with its schema version and typed artifacts.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let eventLineLogger = Logger(subsystem: LogSubsystem.workflow, category: "CLIEventLine")

/// One output that a `complete` or `output` line describes beyond its path.
///
/// `kind` is a string on the wire, a bundle kind id such as `phylogenetic-tree` or a
/// file kind such as `bam`, and ``bundleKind`` reads the first. A reader keeps an
/// unknown kind as the string (decision S9).
public struct CLIEventArtifact: Sendable, Equatable, Codable {
    /// What the artifact is, such as a bundle kind id or a file kind. Empty when the writer did not say.
    public let kind: String
    /// The file or folder, as a path the reader can open.
    public let path: String
    /// Why the command made it, such as `alignment`. Nil when the writer did not say.
    public let role: String?
    /// The provenance record that describes it, as a path. Nil when it has none.
    public let provenancePath: String?

    public init(kind: String, path: String, role: String? = nil, provenancePath: String? = nil) {
        self.kind = kind
        self.path = path
        self.role = role
        self.provenancePath = provenancePath
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case path
        case role
        case provenancePath
    }

    /// Only `path` is required. A field of the wrong type reads as absent, because a
    /// later version may widen it and the path is still worth showing.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        kind = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        role = try? container.decodeIfPresent(String.self, forKey: .role)
        provenancePath = try? container.decodeIfPresent(String.self, forKey: .provenancePath)
    }
}

extension CLIEventArtifact {
    /// Roles that a command writes and an app runner reads, so both sides spell
    /// them the same way. A writer may use any other role, and a reader keeps a
    /// role it does not know as a plain string.
    public enum Role {
        /// The alignment a command made, such as the trimmed BAM of `bam primer-trim`.
        public static let alignment = "alignment"
        /// The index of that alignment.
        public static let alignmentIndex = "alignment-index"
        /// The provenance record of the run.
        public static let provenance = "provenance"
    }

    /// The bundle kind that ``kind`` names, looked up in `BundleKindRegistry`.
    ///
    /// Nil when ``kind`` names no registered bundle kind, such as a file kind
    /// like `bam` or a kind from a later registry, and nil when ``path`` does not
    /// carry one of that kind's folder extensions. A file kind that shares a
    /// bundle kind id, such as `fastq`, reads as nil. ``kind`` keeps the string
    /// the writer gave either way, because kinds stay strings on the wire.
    public var bundleKind: BundleKindID? {
        let id = BundleKindID(rawValue: kind)
        guard let descriptor = BundleKindRegistry.descriptor(for: id),
              descriptor.folderExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else {
            return nil
        }
        return id
    }
}

/// One line of a `lungfish-cli` event stream as it travels on the wire.
///
/// A line is a ``CLIEvent`` plus the schema version of its writer and, on `complete`
/// and `output` lines, the typed artifacts the command made. It decodes from the same
/// JSON object as the event, so the enum keeps its cases and the app's exhaustive
/// switches do not change. A reader that wants artifacts or the version decodes this
/// type and uses ``event`` for the rest.
///
/// Decoding never throws because a line is newer than this reader. A higher
/// `schemaVersion`, an unknown key, an unknown event name and an unknown artifact
/// kind all decode. A line whose event this reader does not know comes back with a nil
/// ``event`` and its name in ``eventName``, and ``CLIEventLineDecoder`` notes it at
/// debug level. `docs/formats/cli-events.md` states the version rule.
public struct CLIEventLine: Sendable, Equatable, Codable {
    /// The version new lines carry. A line without the key was written by version 1.
    public static let currentSchemaVersion = 2

    /// The version that introduced the key, which a line with an unreadable value must
    /// have come from.
    private static let firstVersionWithMarker = 2

    /// The version of the writer. Version 1 lines carry no marker and read as 1.
    public let schemaVersion: Int
    /// The `event` key as written, whether or not this reader knows the event.
    public let eventName: String?
    /// The event, or nil when this reader does not know it.
    public let event: CLIEvent?
    /// The typed artifacts of a `complete` or `output` line, empty on every other line.
    /// `outputs` of a `complete` event keeps its own order and meaning beside them.
    public let artifacts: [CLIEventArtifact]

    /// A line to write. Artifacts ride only on `complete` and `output` lines and are
    /// left off any other event.
    public init(
        event: CLIEvent,
        artifacts: [CLIEventArtifact] = [],
        schemaVersion: Int = CLIEventLine.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.eventName = event.wireName
        self.event = event
        self.artifacts = event.carriesArtifacts ? artifacts : []
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CLIEvent.WireKey.self)
        let version = Self.readSchemaVersion(in: container)
        let name = try? container.decodeIfPresent(String.self, forKey: .event)

        var known: CLIEvent?
        if let name, CLIEvent.EventName.all.contains(name) {
            do {
                known = try CLIEvent(from: decoder)
            } catch {
                // A known event with unreadable fields is a broken line at a version this
                // reader knows. At a higher version the writer may have changed its fields,
                // and the stream must go on without it.
                if version <= Self.currentSchemaVersion { throw error }
            }
        }

        schemaVersion = version
        eventName = name
        event = known
        artifacts = (known?.carriesArtifacts ?? false) ? Self.readArtifacts(in: container) : []
    }

    public func encode(to encoder: Encoder) throws {
        guard let event else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "A line this reader ignored keeps no fields, so it cannot be written again."
                )
            )
        }
        try event.encodeLine(to: encoder, schemaVersion: schemaVersion, artifacts: artifacts)
    }

    /// Notes an ignored line at debug level. The line itself is never logged, since a
    /// path in it may name a person's files, and the name is cut short because it
    /// comes from a subprocess.
    func reportIfIgnored() {
        guard event == nil else { return }
        let name = eventName.map { String($0.prefix(80)) } ?? "none"
        eventLineLogger.debug(
            "Ignored a CLI event line. Event name \(name, privacy: .public), schema version \(schemaVersion, privacy: .public)."
        )
    }

    // MARK: Lenient reads

    /// Absent means 1. A value that is present but unreadable still means at least the
    /// version that introduced the key, and no version is below 1.
    private static func readSchemaVersion(in container: KeyedDecodingContainer<CLIEvent.WireKey>) -> Int {
        if let version = try? container.decodeIfPresent(Int.self, forKey: .schemaVersion) {
            return max(1, version)
        }
        return container.contains(.schemaVersion) ? firstVersionWithMarker : 1
    }

    /// Reads every artifact it can. An element that is not an object with a path is
    /// dropped, and a value that is not an array reads as none.
    private static func readArtifacts(in container: KeyedDecodingContainer<CLIEvent.WireKey>) -> [CLIEventArtifact] {
        let elements = try? container.decodeIfPresent([Lossy<CLIEventArtifact>].self, forKey: .artifacts)
        return (elements ?? []).compactMap(\.value)
    }

    /// Decodes to nil instead of throwing, so one bad array element costs only itself.
    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) {
            value = try? Value(from: decoder)
        }
    }
}
