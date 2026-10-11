// ToolVersionEvidence.swift - What a tool version is known from
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A record's `toolVersion` is a free string. It can hold a version a probe
// printed, a pin copied from the lock without running the tool, the version
// the lock builds from source, the literal `unknown` (or `unresolved`,
// `unavailable`, an empty string), or the text of a failed probe. This type
// names those cases so a reader can tell a measured version from a pin from a
// gap. A step records it under `toolVersionEvidence` beside `toolVersion`, in
// the wire shape at the end of this file. A producer reads a managed
// environment's conda-meta (`condaMeta(id:environment:lock:)`), and the other
// producers are added one pipeline at a time.

import Foundation
import LungfishIO

public enum ToolVersionEvidence: Sendable, Hashable {
    /// A version read from the tool or from the environment that holds it.
    /// `reportedLine` is the raw line the probe printed when the caller kept
    /// it (`2.31-r1302`). For a version read from an environment's conda-meta
    /// it is the package record, `<name>-<version>-<build>`
    /// (`condaMeta(id:environment:lock:)`). It is never what a writer records
    /// as the version.
    case observed(version: String, reportedLine: String?)
    /// A version copied from the lock without running the tool. It says what
    /// the lock pins, not what is installed.
    case lockPin(version: String, id: ManagedToolID)
    /// The version a lock entry's source build installs from the source archive
    /// the lock pins by SHA-256, such as Bracken 3.1 beside the locked package
    /// 1.0.0. It says what the lock builds, and a conda spec cannot install it.
    case sourceBuild(version: String, id: ManagedToolID)
    /// No version is known, and why.
    case unknown(Reason)

    /// Why no version is known.
    public enum Reason: Sendable, Hashable {
        /// Nothing asked the tool for its version, or the record holds no value.
        case noProbe
        /// The probe ran and failed.
        case probeFailed
        /// The probe ran and its output held no version.
        case outputUnparseable
        /// A stored value that older writers use for "no version" (`unknown`,
        /// `unresolved`, `unavailable`, an empty string, `n/a`, `system`).
        /// The associated value is the spelling as stored, trimmed.
        case legacySpelling(String)
        /// A stored value that is a tool's complaint about the probe (the
        /// micromamba `critical libmamba` line, `ERROR: unknown command`),
        /// as stored.
        case recordedProbeError(String)
        /// A stored app version label (`Lungfish 2026.10.10 (dev)`) where an
        /// external tool's version belongs. Only context can tell, so the
        /// classifier never returns it. The export pin assessment does, for a
        /// managed tool step of a primitive record, whose reader fills a step
        /// that has no version with the record's own version.
        case recordedAppVersion(String)
    }

    /// The stored spellings that mean "no version", compared in lower case.
    /// `system` is an operating system tool whose version nobody measured, so
    /// the export plan prints it as a version while a pin cannot be built
    /// from it.
    public static let legacyUnknownSpellings: Set<String> = [
        "", "unknown", "unresolved", "unavailable", "n/a", "system",
    ]

    /// Markers of micromamba's own complaints, which `ProvenanceToolIdentityText`
    /// does not treat as probe errors. A BBMap mapping record on a root with no
    /// `bbmap` environment stored `critical libmamba The given prefix does not
    /// exist: ...` as the mapper version.
    private static let managerErrorMarkers = ["critical libmamba", "libmamba", "prefix does not exist"]

    /// True for the unknown case.
    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    /// The version, for an observed, pinned or source-built version.
    public var version: String? {
        switch self {
        case .observed(let version, _), .lockPin(let version, _), .sourceBuild(let version, _): return version
        case .unknown: return nil
        }
    }

    /// What today's writers record for this evidence in a `toolVersion` field.
    ///
    /// A version is recorded as is (never the raw reported line). A gap is
    /// recorded as `unknown`, which is what `ProvenanceVersion.required` makes
    /// of a nil or empty value, except that a legacy spelling or a probe
    /// error that was read from a record keeps its stored text. A composite
    /// `<version> (managed conda environment ...)` text is a separate wrapper
    /// the four managed pipelines build around the version, so it is not part
    /// of the evidence.
    public var recordedString: String {
        switch self {
        case .observed(let version, _), .lockPin(let version, _), .sourceBuild(let version, _):
            return version
        case .unknown(let reason):
            switch reason {
            case .legacySpelling(let spelling):
                return spelling.isEmpty ? "unknown" : spelling
            case .recordedProbeError(let line), .recordedAppVersion(let line):
                return line
            case .noProbe, .probeFailed, .outputUnparseable:
                return "unknown"
            }
        }
    }

    /// The lock's pin for `id`, recorded as pinned and not as measured. Unknown
    /// (`noProbe`) when the lock has no such entry or the entry has no version.
    public static func lockPin(for id: ManagedToolID, in lock: ManagedToolLock = .bundled) -> ToolVersionEvidence {
        guard let version = lock.entry(id: id)?.version else { return .unknown(.noProbe) }
        return .lockPin(version: version, id: id)
    }

    /// Classifies a stored `toolVersion` string.
    ///
    /// Every legacy unknown spelling and every probe-error line is unknown. A
    /// composite `<version> (managed conda environment E; executable X;
    /// package P)` is classified by its version part. Anything else is an
    /// observed version, because a stored string cannot show whether the
    /// lock or a probe supplied it.
    public static func classify(recorded: String?) -> ToolVersionEvidence {
        guard let recorded else { return .unknown(.noProbe) }
        let trimmed = recorded.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = ProvenanceToolIdentityText.parse(toolName: "", toolVersion: trimmed)
        var head = trimmed
        if parsed.environment != nil || parsed.runtimeNote != nil, let open = trimmed.lastIndex(of: "(") {
            head = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
        }
        if legacyUnknownSpellings.contains(head.lowercased()) { return .unknown(.legacySpelling(head)) }
        let lowered = head.lowercased()
        if parsed.version == "unknown" || managerErrorMarkers.contains(where: lowered.contains) {
            return .unknown(.recordedProbeError(head))
        }
        return .observed(version: head, reportedLine: nil)
    }
}

// MARK: - Evidence read from the environment that ran

extension ToolVersionEvidence {
    /// The version of a managed tool read from the `conda-meta` of the environment that ran it, with the
    /// lock's pin as the fallback (Phase 2.7 decision P12).
    ///
    /// `environment` is the conda environment folder, such as `<root>/envs/samtools`. The package is the one
    /// the lock entry's spec installs, so `bbtools` reads `bbmap`. A package record that is there gives
    /// `.observed(version:reportedLine:)`, and `reportedLine` is the record as one line,
    /// `<name>-<version>-<build>` (`minimap2-2.31-h6bd33b9_0`). That line is built from the three names and
    /// holds no path, however many paths the record itself keeps. The version is the environment's own, so it
    /// differs from the lock's when the environment was changed after the install. When the environment holds
    /// no usable record of the package, the lock's pin is recorded as a pin.
    ///
    /// A tool that a source build or a Python runtime installs (Bracken, primalscheme3) has no conda package
    /// that names its version, so neither the record nor the pin could say what ran. That is `unknown`.
    ///
    /// Call this in the writer after the run. It reads files and starts no process, so it never belongs in a
    /// `ToolProcess` observer.
    public static func condaMeta(
        id: ManagedToolID, environment: URL, lock: ManagedToolLock = .bundled
    ) -> ToolVersionEvidence {
        guard let entry = lock.entry(id: id) else { return .unknown(.noProbe) }
        guard let spec = lock.packageSpec(of: entry), let package = CondaSpec(spec: spec)?.name else {
            return .unknown(.noProbe)
        }
        if let record = CondaMetaReader.primaryPackage(named: package, inEnvironment: environment),
           let line = packageRecordLine(of: record) {
            return .observed(version: record.version, reportedLine: line)
        }
        return .lockPin(for: id, in: lock)
    }

    /// A package record as `<name>-<version>-<build>`, or nil when a part is empty or is not a plain token
    /// (a part with a slash, a space or a line break could carry a path or break the line).
    static func packageRecordLine(of record: CondaMetaPackage) -> String? {
        var parts = [record.name, record.version]
        if let build = record.build, !build.isEmpty { parts.append(build) }
        guard parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(plainRecordCharacters.contains) }) else {
            return nil
        }
        return parts.joined(separator: "-")
    }

    private static let plainRecordCharacters =
        CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-!~")
}

// MARK: - Wire shape

/// A step's `toolVersionEvidence` object. `source` is `observed`, `lockPin`, `sourceBuild` or
/// `unknown`. An observed, pinned or source-built version carries `version`, an observed one the
/// probe's `reportedLine` when the caller kept it, and a pin or a source build its lock entry's
/// `managedToolID`. An unknown version carries a `reason` and, for the reasons read from a stored
/// value, that value as `recorded`.
extension ToolVersionEvidence: Codable {
    private enum CodingKeys: String, CodingKey {
        case source
        case version
        case reportedLine
        case managedToolID
        case reason
        case recorded
    }

    private enum Source: String, Codable {
        case observed
        case lockPin
        case sourceBuild
        case unknown
    }

    private enum ReasonName: String, Codable {
        case noProbe
        case probeFailed
        case outputUnparseable
        case legacySpelling
        case recordedProbeError
        case recordedAppVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Source.self, forKey: .source) {
        case .observed:
            self = .observed(
                version: try container.decode(String.self, forKey: .version),
                reportedLine: try container.decodeIfPresent(String.self, forKey: .reportedLine)
            )
        case .lockPin:
            self = .lockPin(
                version: try container.decode(String.self, forKey: .version),
                id: try container.decode(ManagedToolID.self, forKey: .managedToolID)
            )
        case .sourceBuild:
            self = .sourceBuild(
                version: try container.decode(String.self, forKey: .version),
                id: try container.decode(ManagedToolID.self, forKey: .managedToolID)
            )
        case .unknown:
            let recorded = try container.decodeIfPresent(String.self, forKey: .recorded) ?? ""
            switch try container.decode(ReasonName.self, forKey: .reason) {
            case .noProbe: self = .unknown(.noProbe)
            case .probeFailed: self = .unknown(.probeFailed)
            case .outputUnparseable: self = .unknown(.outputUnparseable)
            case .legacySpelling: self = .unknown(.legacySpelling(recorded))
            case .recordedProbeError: self = .unknown(.recordedProbeError(recorded))
            case .recordedAppVersion: self = .unknown(.recordedAppVersion(recorded))
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .observed(let version, let reportedLine):
            try container.encode(Source.observed, forKey: .source)
            try container.encode(version, forKey: .version)
            try container.encodeIfPresent(reportedLine, forKey: .reportedLine)
        case .lockPin(let version, let id):
            try container.encode(Source.lockPin, forKey: .source)
            try container.encode(version, forKey: .version)
            try container.encode(id, forKey: .managedToolID)
        case .sourceBuild(let version, let id):
            try container.encode(Source.sourceBuild, forKey: .source)
            try container.encode(version, forKey: .version)
            try container.encode(id, forKey: .managedToolID)
        case .unknown(let reason):
            try container.encode(Source.unknown, forKey: .source)
            let name: ReasonName
            var recorded: String?
            switch reason {
            case .noProbe: name = .noProbe
            case .probeFailed: name = .probeFailed
            case .outputUnparseable: name = .outputUnparseable
            case .legacySpelling(let text):
                name = .legacySpelling
                recorded = text
            case .recordedProbeError(let text):
                name = .recordedProbeError
                recorded = text
            case .recordedAppVersion(let text):
                name = .recordedAppVersion
                recorded = text
            }
            try container.encode(name, forKey: .reason)
            try container.encodeIfPresent(recorded, forKey: .recorded)
        }
    }
}
