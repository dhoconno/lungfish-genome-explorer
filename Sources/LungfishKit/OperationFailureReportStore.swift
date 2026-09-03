// OperationFailureReportStore.swift - Automatic on-disk failure reports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// Persists a diagnostic report for every operation that fails.
///
/// Failure reports used to exist only as clipboard text produced by the
/// Operations Panel, which meant a failure could only be read by someone
/// sitting at the machine with the app still running. Writing the same report
/// to disk as the failure happens lets the first debugging step be "read the
/// log file" instead of "drive the GUI".
///
/// Reports land in a per-user logs directory rather than inside a project
/// because operations can fail with no project open, and because
/// `~/Library/Logs` is where macOS users and support tooling already look.
public final class OperationFailureReportStore: @unchecked Sendable {
    /// Number of reports kept on disk. Older reports are pruned on each write
    /// so an app left running for weeks cannot fill the user's disk.
    public static let defaultRetentionLimit = 50

    private let directory: URL
    private let retentionLimit: Int
    private let fileManager: FileManager

    public init(
        directory: URL,
        retentionLimit: Int = OperationFailureReportStore.defaultRetentionLimit,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.retentionLimit = max(1, retentionLimit)
        self.fileManager = fileManager
    }

    public convenience init() {
        self.init(directory: OperationFailureReportStore.defaultDirectory())
    }

    /// True when running under a test harness, where the shared
    /// ``OperationCenter`` is exercised by hundreds of tests that deliberately
    /// fail operations. Those must not deposit reports in the developer's real
    /// logs directory.
    ///
    /// Detected by looking for a loaded test framework rather than the usual
    /// `XCTestConfigurationFilePath` environment variable, because the SwiftPM
    /// runner used by this package sets no `XCTEST*` variables at all.
    private static var isRunningUnderTests: Bool { TestHarness.isRunning }

    /// The directory reports are written to, exposed so the UI can tell the
    /// user where to look without duplicating the path construction.
    public var reportsDirectory: URL { directory }

    /// `~/Library/Logs/<app name>/Operations/Failures`.
    ///
    /// Nested under the existing per-operation log directory so all operation
    /// diagnostics stay in one place, and keyed on app identity so a Debug
    /// build never interleaves its reports with a shipped build's.
    public static func defaultDirectory(
        appIdentity: LungfishAppIdentity = .current,
        libraryDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        let library = libraryDirectory
            ?? (isRunningUnderTests
                ? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                    .appendingPathComponent("LungfishTestLibrary", isDirectory: true)
                : nil)
            ?? fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(appIdentity.logDirectoryName, isDirectory: true)
            .appendingPathComponent("Operations", isDirectory: true)
            .appendingPathComponent("Failures", isDirectory: true)
    }

    // MARK: - Writing

    /// Writes a failure report for `item` and prunes older reports.
    ///
    /// Returns `nil` for operations that did not fail, and also for any I/O
    /// error: a full or read-only logs directory must never turn one failed
    /// operation into a second, louder failure. The caller has already lost
    /// the operation; losing the log too is not worth an alert.
    @discardableResult
    public func writeReport(for item: OperationCenter.Item) -> URL? {
        guard item.state == .failed else { return nil }

        let url = directory.appendingPathComponent(fileName(for: item))
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.buildFailureReport(for: item)
                .write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }

        pruneOldReports()
        return url
    }

    /// Keeps only the newest `retentionLimit` reports.
    ///
    /// Ordering is lexical on the file name, which is equivalent to time order
    /// because every name starts with a fixed-width `yyyyMMdd-HHmmss` stamp.
    /// That avoids trusting file modification dates, which copies and backups
    /// rewrite.
    private func pruneOldReports() {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        let reports = names.filter { $0.hasSuffix(Self.reportSuffix) }.sorted()
        guard reports.count > retentionLimit else { return }
        for name in reports.prefix(reports.count - retentionLimit) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: - Naming

    private static let reportSuffix = ".log"

    private func fileName(for item: OperationCenter.Item) -> String {
        let stamp = Self.fileTimestampFormatter.string(from: item.startedAt)
        // The id suffix disambiguates operations started within the same second.
        let idSuffix = String(item.id.uuidString.prefix(8)).lowercased()
        return "\(stamp)-\(Self.slug(item.title))-\(idSuffix)\(Self.reportSuffix)"
    }

    private static func slug(_ value: String) -> String {
        let slug = value
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return String((slug.isEmpty ? "operation" : slug).prefix(48))
    }

    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    // MARK: - Composition

    /// Builds the structured failure report: CLI command, error message, error
    /// detail (including captured stderr), and the full timestamped log.
    ///
    /// This lives beside ``OperationCenter``, which owns the data, so the
    /// report can be produced whether or not the Operations Panel was ever
    /// opened. The panel's clipboard and GitHub-issue actions call the same
    /// function so on-disk and pasted reports never drift apart.
    ///
    /// Falls back gracefully: if structured `errorMessage`/`errorDetail` fields
    /// are not set (e.g. download failures that only populate `detail`), the
    /// `detail` subtitle text is used as the failure reason.
    public static func buildFailureReport(for item: OperationCenter.Item) -> String {
        var lines: [String] = []
        lines.append("=== Lungfish Operation Failure Report ===")
        lines.append("Operation: \(item.title)")
        if let cmd = item.cliCommand {
            lines.append("")
            lines.append("CLI Command:")
            lines.append("  \(cmd)")
        }
        // Prefer structured errorMessage; fall back to the detail subtitle which
        // download/ingestion paths always populate with the failure reason.
        let errorText = item.errorMessage ?? item.detail
        if !errorText.isEmpty {
            lines.append("")
            lines.append("Error: \(errorText)")
        }
        if let detail = item.errorDetail {
            lines.append("")
            lines.append("Details:")
            detail.components(separatedBy: "\n").forEach { lines.append("  \($0)") }
        }
        if !item.logEntries.isEmpty {
            lines.append("")
            lines.append("Log:")
            item.logEntries.forEach { entry in
                let ts = logTimestampFormatter.string(from: entry.timestamp)
                lines.append("  [\(ts)] [\(entry.level.rawValue.uppercased())] \(entry.message)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
