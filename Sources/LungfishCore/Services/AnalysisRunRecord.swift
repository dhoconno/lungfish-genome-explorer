// AnalysisRunRecord.swift - Durable in-progress record for analysis result directories
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

/// A durable record, written inside an analysis result directory, saying that
/// the run producing it has not finished yet.
///
/// ## Visibility rule
///
/// A result directory that carries this record is **incomplete** and is never
/// listed (sidebar, `AnalysesFolder.listAnalyses`, CLI listings). The producer
/// removes the record as the last step of a successful run, which is the
/// positive completion signal: only then does the result appear. A run that
/// completes with warnings is a successful run and removes the record too.
///
/// A directory with **no** record is complete. That keeps results written by
/// builds that predate the record visible.
///
/// The record never makes a directory visible on its own, whatever the state
/// of its producer. A run that failed, was cancelled, or was interrupted by a
/// crash, quit or kill keeps its record and stays hidden.
/// ``liveness(currentHostName:processProbe:)`` is kept separate from
/// visibility so the app can offer interrupted runs for review and removal
/// (the Operations Panel "Interrupted" row) without ever deleting them
/// silently.
///
/// The record lives inside the project, so it travels with a shared project
/// and covers runs started from `lungfish-cli` as well as from the app.
public struct AnalysisRunRecord: Codable, Equatable, Sendable {

    /// Hidden file name, so directory listings that skip hidden files never
    /// show it and it is never mistaken for result content.
    public static let fileName = ".lungfish-run-in-progress.json"

    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Human-readable analysis name, e.g. "TaxTriage".
    public var analysisName: String
    /// The reproducible CLI command, when the producer knows it.
    public var command: String?
    public var startedAt: Date
    /// Host that ran the producer. Liveness can only be judged on this host.
    public var hostName: String
    public var processIdentifier: Int32
    /// Producer start time in microseconds since 1970, guarding against PID reuse.
    public var processStartTime: UInt64?
    /// Set when the producer knows the run ended without completing. `nil`
    /// while running, and after a crash, quit or kill.
    public var outcome: Outcome?

    public enum Outcome: String, Codable, Equatable, Sendable {
        case failed
        case cancelled
    }

    public init(
        analysisName: String,
        command: String? = nil,
        startedAt: Date = Date(),
        hostName: String = AnalysisRunRecord.currentHostName(),
        processIdentifier: Int32 = getpid(),
        processStartTime: UInt64? = AnalysisRunRecord.startTime(ofProcess: getpid())
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.analysisName = analysisName
        self.command = command
        self.startedAt = startedAt
        self.hostName = hostName
        self.processIdentifier = processIdentifier
        self.processStartTime = processStartTime
    }

    // MARK: - File operations

    public static func url(in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Returns `true` when the directory carries a run record, meaning its
    /// producer has not marked it complete. Unreadable or corrupt records
    /// still count: the file's presence is the signal.
    public static func isIncomplete(_ directoryURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(in: directoryURL).path)
    }

    /// Writes the record into `directoryURL` atomically.
    public static func begin(_ record: AnalysisRunRecord, in directoryURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: url(in: directoryURL), options: .atomic)
    }

    /// Reads the record, or `nil` when absent or unreadable.
    public static func load(from directoryURL: URL) -> AnalysisRunRecord? {
        guard let data = try? Data(contentsOf: url(in: directoryURL)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AnalysisRunRecord.self, from: data)
    }

    /// Records the reproducible command in an existing record. A directory
    /// without a record is complete and is left untouched.
    public static func updateCommand(_ command: String, in directoryURL: URL) {
        guard var record = load(from: directoryURL) else { return }
        record.command = command
        try? begin(record, in: directoryURL)
    }

    /// The positive completion signal: removes the record so the directory is
    /// listed. Unlinking is atomic, so a reader sees either the record or the
    /// complete directory. Safe to call when no record exists.
    ///
    /// - Returns: `true` when a record was removed.
    @discardableResult
    public static func markComplete(_ directoryURL: URL) -> Bool {
        let path = url(in: directoryURL).path
        return path.withCString { Darwin.unlink($0) } == 0
    }

    /// The nearest directory at or above `url` that carries a record, such as
    /// the batch root of a per-sample output directory. The search stops below
    /// a project's `Analyses` folder and never climbs more than a few levels.
    public static func enclosingIncompleteDirectory(for url: URL) -> URL? {
        var current = url.standardizedFileURL
        for _ in 0..<6 {
            if current.lastPathComponent == "Analyses" || current.path == "/" { return nil }
            if isIncomplete(current) { return current }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    /// Notes that the run ended without completing. The directory stays
    /// incomplete, so it stays hidden. A directory without a record is left alone.
    public static func recordOutcome(_ outcome: Outcome, in directoryURL: URL) {
        guard var record = load(from: directoryURL) else { return }
        record.outcome = outcome
        try? begin(record, in: directoryURL)
    }

    // MARK: - Liveness (for review and cleanup only, never visibility)

    public enum Liveness: Equatable, Sendable {
        /// The producer process on this host is still alive.
        case running
        /// The producer ran on this host and is gone (dead PID, or the PID was
        /// reused by a different process).
        case interrupted
        /// The record came from another computer. Its producer cannot be
        /// checked from here, so it is never treated as interrupted.
        case otherHost
    }

    /// What a process probe learned about a PID.
    public enum ProcessStatus: Equatable, Sendable {
        case notRunning
        /// Running, with its start time in microseconds since 1970 when known.
        case running(startTime: UInt64?)
    }

    public typealias ProcessProbe = @Sendable (Int32) -> ProcessStatus

    /// Classifies the producer. This never decides visibility, which depends
    /// only on the record being present.
    public func liveness(
        currentHostName: String = AnalysisRunRecord.currentHostName(),
        processProbe: ProcessProbe = AnalysisRunRecord.probeProcess
    ) -> Liveness {
        guard Self.normalizedHostName(hostName) == Self.normalizedHostName(currentHostName) else {
            return .otherHost
        }
        switch processProbe(processIdentifier) {
        case .notRunning:
            return .interrupted
        case .running(let startTime):
            if let recorded = processStartTime, let startTime, recorded != startTime {
                return .interrupted
            }
            return .running
        }
    }

    // MARK: - Host and process helpers

    public static func currentHostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "unknown-host" }
        let name = String(cString: buffer)
        return name.isEmpty ? "unknown-host" : name
    }

    static func normalizedHostName(_ name: String) -> String {
        var normalized = name.lowercased()
        if normalized.hasSuffix(".local") { normalized.removeLast(".local".count) }
        return normalized
    }

    /// Start time of a live process in microseconds since 1970, or `nil`.
    public static func startTime(ofProcess pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, size)
        }
        guard result == size else { return nil }
        return UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
    }

    @Sendable
    public static func probeProcess(_ pid: Int32) -> ProcessStatus {
        guard pid > 0 else { return .notRunning }
        if kill(pid, 0) != 0 && errno == ESRCH {
            return .notRunning
        }
        return .running(startTime: startTime(ofProcess: pid))
    }
}
