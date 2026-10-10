// ToolVersionEvidence.swift - What a tool version is known from
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A record's `toolVersion` is a free string today. It can hold a version a
// probe printed, a pin copied from the lock without running the tool, the
// literal `unknown` (or `unresolved`, `unavailable`, an empty string), or the
// text of a failed probe. This type names those cases so a reader can tell a
// measured version from a pin from a gap. It computes only. No writer, reader
// or exporter uses it yet, and it is not `Codable`, because the record wire
// shape belongs to Phase 2.6.

import Foundation
import LungfishIO

public enum ToolVersionEvidence: Sendable, Hashable {
    /// A version the tool's own probe printed. `reportedLine` is the raw line
    /// the probe printed when the caller kept it (`2.31-r1302`), and it is
    /// never what a writer records.
    case observed(version: String, reportedLine: String?)
    /// A version copied from the lock without running the tool. It says what
    /// the lock pins, not what is installed.
    case lockPin(version: String, id: ManagedToolID)
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

    /// The version, for an observed or pinned version.
    public var version: String? {
        switch self {
        case .observed(let version, _), .lockPin(let version, _): return version
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
        case .observed(let version, _), .lockPin(let version, _):
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
