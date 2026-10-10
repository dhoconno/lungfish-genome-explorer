// ProvenanceLegacyDisplaySupport.swift - The Provenance tab's display of one record, as comparable data
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// ProvenanceLegacyDisplayTests loads each legacy record shape through
// ProvenanceInspectorViewModel and reduces what the tab shows to a
// ProvenanceDisplaySnapshot. The snapshot is compared with the expected file
// committed under Tests/Fixtures/provenance-display/expected, so a change to
// anything a scientist reads is deliberate and reviewed.

import Foundation
@testable import LungfishApp
import LungfishCore
import LungfishWorkflow

// MARK: - Snapshot

/// What the Inspector's Provenance tab shows for one record.
///
/// Every string passes through ``ProvenanceDisplayRedaction`` first, so the
/// snapshot names no temporary folder, home folder or managed tool root. Fields
/// the record's bytes do not carry, and that the reader fills in from the
/// Mac it runs on, are left out by the capture and are never compared.
struct ProvenanceDisplaySnapshot: Codable, Equatable {
    struct Summary: Codable, Equatable {
        var statusLabel: String
        var workflowName: String
        /// Nil when the record's bytes carry no workflow version. The reader then
        /// shows its own app version, which differs from Mac to Mac.
        var workflowVersion: String?
        var toolName: String
        var toolVersion: String
        /// The instant the Run Summary dates the record, in milliseconds since 1970.
        /// It is the `Date` itself and not the `Created` text, which follows the
        /// time zone and locale of the Mac.
        var createdAtMilliseconds: Int64?
        /// `createdAtMilliseconds` in UTC, for a reader of the expected file.
        var createdAtUTC: String?
        var exitStatus: Int?
        var wallTimeSeconds: Double?
        var stepCount: Int
        var inputCount: Int
        var outputCount: Int
        var signatureCount: Int
        var sidecarDisplayPath: String?
    }

    struct Warning: Codable, Equatable {
        var title: String
        var message: String
    }

    struct Step: Codable, Equatable {
        var ordinal: Int
        var toolName: String
        var toolVersion: String
        var displayCommand: String
        var inputs: [String]
        var outputs: [String]
        var exitStatus: Int?
        var wallTimeSeconds: Double?
        var stderr: String?
    }

    struct Run: Codable, Equatable {
        var title: String
        var subtitle: String
        var steps: [Step]
    }

    struct FileRow: Codable, Equatable {
        var role: String
        var displayPath: String
        var checksumSHA256: String?
        var fileSize: UInt64?
        var sizeLabel: String
        var format: String?
        var detail: String?
    }

    struct OptionRow: Codable, Equatable {
        var kind: String
        var name: String
        var displayValue: String
    }

    struct RuntimeRow: Codable, Equatable {
        var label: String
        var value: String
    }

    var auditStatus: String
    var auditIsBlocking: Bool
    var summary: Summary
    var warnings: [Warning]
    var lineage: [Run]
    var files: [FileRow]
    var options: [OptionRow]
    var runtime: [RuntimeRow]
    /// Whether Raw JSON holds the nested `legacyWorkflowRun` block. Records written
    /// before the converged writer carry it, and a record keeps reading that way.
    var rawJSONHoldsEmbeddedRun: Bool
}

// MARK: - Per-record choices

/// What a record's bytes carry, which decides what the snapshot may pin.
struct ProvenanceDisplayCase {
    /// The name of the expected file, without its extension.
    let name: String
    /// False when the bytes carry no workflow version.
    let recordsWorkflowVersion: Bool
    /// The Runtime labels whose values the bytes carry. Every other row comes
    /// from the reading Mac (Executable, Process ID, Architecture, Dependency
    /// Set) and is not captured.
    let recordedRuntimeLabels: [String]
}

// MARK: - Capture

extension ProvenanceDisplaySnapshot {
    @MainActor
    static func capture(
        _ model: ProvenanceInspectorViewModel,
        for displayCase: ProvenanceDisplayCase,
        redaction: ProvenanceDisplayRedaction
    ) -> ProvenanceDisplaySnapshot {
        let summary = model.summary
        return ProvenanceDisplaySnapshot(
            auditStatus: model.audit.status.rawValue,
            auditIsBlocking: model.audit.isBlocking,
            summary: Summary(
                statusLabel: summary.statusLabel,
                workflowName: redaction(summary.workflowName),
                workflowVersion: displayCase.recordsWorkflowVersion ? summary.workflowVersion : nil,
                toolName: redaction(summary.toolName),
                toolVersion: summary.toolVersion,
                createdAtMilliseconds: summary.createdAt.map(Self.milliseconds),
                createdAtUTC: summary.createdAt.map(Self.utcText),
                exitStatus: summary.exitStatus,
                wallTimeSeconds: summary.wallTimeSeconds,
                stepCount: summary.stepCount,
                inputCount: summary.inputCount,
                outputCount: summary.outputCount,
                signatureCount: summary.signatureCount,
                sidecarDisplayPath: summary.sidecarDisplayPath.map(redaction.callAsFunction)
            ),
            warnings: model.warnings.map {
                Warning(title: $0.title, message: redaction($0.message))
            },
            lineage: model.lineageRuns.map { run in
                Run(
                    title: redaction(run.title),
                    subtitle: run.subtitle,
                    steps: run.steps.map { step in
                        Step(
                            ordinal: step.ordinal,
                            toolName: step.toolName,
                            toolVersion: step.toolVersion,
                            displayCommand: redaction(step.displayCommand),
                            inputs: step.inputPathLabels.map(redaction.callAsFunction),
                            outputs: step.outputPathLabels.map(redaction.callAsFunction),
                            exitStatus: step.exitStatus,
                            wallTimeSeconds: step.wallTimeSeconds,
                            stderr: step.stderr.map(redaction.callAsFunction)
                        )
                    }
                )
            },
            files: model.fileRows.map { row in
                FileRow(
                    role: row.role,
                    displayPath: redaction(row.displayPath),
                    checksumSHA256: row.checksumSHA256,
                    fileSize: row.fileSize,
                    sizeLabel: row.fileSizeLabel,
                    format: row.format,
                    detail: row.detail
                )
            },
            options: model.optionRows.map {
                OptionRow(kind: $0.kind, name: $0.name, displayValue: redaction($0.displayValue))
            },
            runtime: model.runtimeRows
                .filter { displayCase.recordedRuntimeLabels.contains($0.label) }
                .map { RuntimeRow(label: $0.label, value: redaction($0.value)) },
            rawJSONHoldsEmbeddedRun: model.rawJSON.contains("\"legacyWorkflowRun\"")
        )
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func utcText(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

// MARK: - Expected files

extension ProvenanceDisplaySnapshot {
    /// The text of an expected file: sorted keys, indented and with unescaped
    /// slashes, so a diff shows only what changed.
    func canonicalJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func decode(expected data: Data) throws -> ProvenanceDisplaySnapshot {
        try JSONDecoder().decode(ProvenanceDisplaySnapshot.self, from: data)
    }

    /// The lines of the snapshot's JSON that name a private path. The expected
    /// files are committed, so none may hold the author's folders.
    func privatePathLeaks() throws -> [String] {
        let markers = ["/Users/", "/var/folders", "/private/var", "/tmp/"]
        return try canonicalJSON()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in markers.contains { line.contains($0) } }
    }

    /// The first lines where two renderings differ, for a failure message.
    static func lineDifferences(expected: String, actual: String, limit: Int = 12) -> String {
        let expectedLines = expected.split(separator: "\n", omittingEmptySubsequences: false)
        let actualLines = actual.split(separator: "\n", omittingEmptySubsequences: false)
        var report: [String] = []
        for index in 0..<max(expectedLines.count, actualLines.count) {
            let left = index < expectedLines.count ? String(expectedLines[index]) : "(no line)"
            let right = index < actualLines.count ? String(actualLines[index]) : "(no line)"
            guard left != right else { continue }
            report.append("line \(index + 1)\n  expected: \(left)\n  actual:   \(right)")
            if report.count == limit { break }
        }
        return report.isEmpty ? "(same lines, different data)" : report.joined(separator: "\n")
    }

    /// Writes the actual rendering under the temporary directory, never into
    /// the checkout, so a reviewer can run `diff` against the expected file.
    static func writeActual(_ json: String, named name: String) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-provenance-display-actual", isDirectory: true)
        let url = directory.appendingPathComponent("\(name).json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data((json + "\n").utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - Redaction

/// Replaces the parts of a displayed string that belong to the Mac the test
/// runs on: the temporary project, the managed tool and storage roots, the
/// temporary directory and any home folder.
struct ProvenanceDisplayRedaction {
    private var replacements: [(from: String, to: String)]

    init(projectURL: URL) {
        var pairs: [(from: String, to: String)] = []
        func add(_ url: URL, _ placeholder: String) {
            let spellings = [
                url.path,
                url.standardizedFileURL.path,
                url.resolvingSymlinksInPath().path,
            ]
            for spelling in Set(spellings) where spelling.count > 1 {
                pairs.append((from: spelling, to: placeholder))
            }
        }
        add(projectURL, "<project>")
        let managed = PortablePath.defaultManagedRoots
        add(managed.toolRoot, "<tool-root>")
        add(managed.storageRoot, "<storage-root>")
        add(FileManager.default.temporaryDirectory, "<tmp>")
        // The longest spelling first, so a folder inside another is named by its own placeholder.
        replacements = pairs.sorted { $0.from.count > $1.from.count }
    }

    func callAsFunction(_ text: String) -> String {
        var result = text
        for pair in replacements {
            result = result.replacingOccurrences(of: pair.from, with: pair.to)
        }
        // A path under the managed tool root is shown in full, or by name when that root
        // sits in a temporary folder and the tool is absent. The snapshot uses the name
        // in both cases, so it does not depend on where the Mac keeps its tools.
        result = result.replacingOccurrences(
            of: "<tool-root>(?:/[^/\\s'\"]+)*/([^/\\s'\"]+)",
            with: "$1",
            options: .regularExpression
        )
        return result.replacingOccurrences(
            of: "/Users/[^/\\s'\"]+",
            with: "<home>",
            options: .regularExpression
        )
    }
}

// MARK: - Fixture locations

enum ProvenanceDisplayFixtures {
    /// `Tests/`, found from this file so the tests do not depend on the working directory.
    static let testsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The committed records and expected files this suite reads.
    static let directory = testsDirectory
        .appendingPathComponent("Fixtures/provenance-display", isDirectory: true)

    static let expectedDirectory = directory.appendingPathComponent("expected", isDirectory: true)

    /// The real bare legacy run fetched by `lungfish-cli` 0.4.0-alpha.11, with its GFF3.
    static let sarscov2Directory = testsDirectory
        .appendingPathComponent("Fixtures/sarscov2-srr36291587", isDirectory: true)
}
