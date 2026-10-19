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
import XCTest

// MARK: - Snapshot

/// What the Inspector's Provenance tab shows for one record.
///
/// Every string passes through ``ProvenanceDisplayRedaction`` first, so the
/// snapshot names no temporary folder, home folder or managed tool root. A fact
/// the record never held reads Not recorded and the capture keeps it, because
/// since plan decision S4 no reader fills one from the Mac it runs on.
struct ProvenanceDisplaySnapshot: Codable, Equatable {
    struct Summary: Codable, Equatable {
        var statusLabel: String
        var workflowName: String
        /// Not recorded when the record's bytes carry no workflow version.
        var workflowVersion: String?
        var toolName: String
        var toolVersion: String
        /// The instant the Run Summary dates the record, in milliseconds since 1970.
        /// It is the `Date` itself and not the `Created` text, which follows the
        /// time zone and locale of the Mac.
        var createdAtMilliseconds: Int64?
        /// `createdAtMilliseconds` in UTC, for a reader of the expected file.
        var createdAtUTC: String?
        /// The Run Status row, or nil when the Run Summary shows none.
        var runStatus: String?
        var exitStatus: Int?
        var wallTimeSeconds: Double?
        var stepCount: Int
        var inputCount: Int
        var outputCount: Int
        var signatureCount: Int
        var sidecarDisplayPath: String?
        /// The Run Summary rows that read Not recorded instead of being left out, because the reader
        /// invented the date or the record lacks the exit status or the wall time. Nil when there is none.
        var notRecorded: [String]?
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
        /// The lines the step's observation adds to its disclosure (Phase 2.10 lane U37). Nil when it adds none,
        /// so the expected file of a record with no observation holds no such key.
        var observation: ObservationLines?
    }

    /// The Termination, Output and Environment lines of a step's disclosure, each nil when it does not show.
    struct ObservationLines: Codable, Equatable {
        var termination: String?
        var output: String?
        var environment: String?
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
}

// MARK: - Per-record choices

struct ProvenanceDisplayCase {
    /// The name of the expected file, without its extension.
    let name: String

    /// Naming a case also gives the running test case its own storage root, since a test names its case before it
    /// loads a record (``ProvenanceDisplayStorageRoot``).
    init(name: String) {
        self.name = name
        ProvenanceDisplayStorageRoot.shared.activate()
    }
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
                workflowVersion: summary.workflowVersion,
                toolName: redaction(summary.toolName),
                toolVersion: summary.toolVersion,
                createdAtMilliseconds: summary.createdAt.map(Self.milliseconds),
                createdAtUTC: summary.createdAt.map(Self.utcText),
                runStatus: summary.runStatus?.label,
                exitStatus: summary.exitStatus,
                wallTimeSeconds: summary.wallTimeSeconds,
                stepCount: summary.stepCount,
                inputCount: summary.inputCount,
                outputCount: summary.outputCount,
                signatureCount: summary.signatureCount,
                sidecarDisplayPath: summary.sidecarDisplayPath.map(redaction.callAsFunction),
                notRecorded: Self.notRecordedRows(of: summary)
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
                            stderr: step.stderr.map(redaction.callAsFunction),
                            observation: step.observation.map {
                                ObservationLines(
                                    termination: $0.termination.map(redaction.callAsFunction),
                                    output: $0.output,
                                    environment: $0.environment.map(redaction.callAsFunction)
                                )
                            }
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
            runtime: model.runtimeRows.map { RuntimeRow(label: $0.label, value: redaction($0.value)) }
        )
    }

    @MainActor
    private static func notRecordedRows(of summary: ProvenanceRunSummary) -> [String]? {
        let rows = (summary.createdAtNotRecorded ? ["Created"] : [])
            + (summary.exitStatusNotRecorded ? ["Exit Status"] : [])
            + (summary.wallTimeNotRecorded ? ["Wall Time"] : [])
        return rows.isEmpty ? nil : rows
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

// MARK: - The storage root of a display case

/// Gives each display test case a managed storage root of its own, so no snapshot depends on where the Mac keeps
/// its tools (Phase 2.11 SW17 a).
///
/// The tab shows a recorded `<tool-root>/envs/htslib/bin/bgzip` under the reader's own tool root, by the tool's name
/// since Phase 2.12 lane 12.25 (Q-U6, `ProvenanceCommandDisplayTests`). The case still sets `LUNGFISH_STORAGE_ROOT`
/// to a new folder in the temporary directory and clears `LUNGFISH_CONDA_ROOT` until XCTest reports the case
/// finished, and then puts both back, so the `<storage-root>` and `<tool-root>` redactions name a folder of the test.
final class ProvenanceDisplayStorageRoot: NSObject, XCTestObservation, @unchecked Sendable {
    /// The observer, registered with XCTest the first time a case is named.
    static let shared: ProvenanceDisplayStorageRoot = {
        let observer = ProvenanceDisplayStorageRoot()
        XCTestObservationCenter.shared.addTestObserver(observer)
        return observer
    }()

    private let lock = NSLock()
    private var saved: [String: String?]?
    private var folder: URL?

    /// Sets the root for the test case that is running. A second call before the case finishes does nothing.
    func activate() {
        lock.lock()
        defer { lock.unlock() }
        guard saved == nil else { return }
        let environment = ProcessInfo.processInfo.environment
        saved = [
            "LUNGFISH_STORAGE_ROOT": environment["LUNGFISH_STORAGE_ROOT"],
            "LUNGFISH_CONDA_ROOT": environment["LUNGFISH_CONDA_ROOT"],
        ]
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-display-storage-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        folder = root
        setenv("LUNGFISH_STORAGE_ROOT", root.path, 1)
        unsetenv("LUNGFISH_CONDA_ROOT")
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        lock.lock()
        defer { lock.unlock() }
        guard let saved else { return }
        for (name, value) in saved {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
        if let folder { try? FileManager.default.removeItem(at: folder) }
        self.saved = nil
        folder = nil
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
