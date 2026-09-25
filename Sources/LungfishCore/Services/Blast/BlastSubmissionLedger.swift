// BlastSubmissionLedger.swift - Rolling-hour record of reads sent to NCBI BLAST
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let ledgerLogger = Logger(subsystem: LogSubsystem.core, category: "BlastSubmissionLedger")

// MARK: - Ledger Event

/// One BLAST submission: when it was sent and how many reads it carried.
public struct BlastSubmissionLedgerEvent: Sendable, Codable, Equatable {
    public let date: Date
    public let count: Int

    public init(date: Date, count: Int) {
        self.date = date
        self.count = max(0, count)
    }
}

// MARK: - Budget Rule

/// The rolling-window budget rule shared by every ledger implementation.
public enum BlastSubmissionBudget {

    /// Length of the rolling window, one hour.
    public static let window: TimeInterval = 3600

    /// Drops events older than the window, checks that `count` more reads
    /// fit under `limit`, and records them at `now`.
    ///
    /// - Throws: ``BlastServiceError/rateLimitExceeded(retryAfter:)`` with the
    ///   seconds until the oldest event in the window expires.
    public static func reserve(
        _ events: inout [BlastSubmissionLedgerEvent],
        count: Int,
        at now: Date,
        limit: Int,
        window: TimeInterval = window
    ) throws {
        events = prune(events, now: now, window: window)
        let used = events.reduce(0) { $0 + $1.count }
        guard used + count <= limit else {
            let oldest = events.map(\.date).min()
            let retryAfter = oldest.map { max(1, window - now.timeIntervalSince($0)) } ?? window
            throw BlastServiceError.rateLimitExceeded(retryAfter: retryAfter)
        }
        events.append(BlastSubmissionLedgerEvent(date: now, count: count))
    }

    /// Events still inside the window at `now`. Events dated in the future
    /// (a clock moved backwards) are kept, so the budget never grows.
    public static func prune(
        _ events: [BlastSubmissionLedgerEvent],
        now: Date,
        window: TimeInterval = window
    ) -> [BlastSubmissionLedgerEvent] {
        events.filter { now.timeIntervalSince($0.date) < window }
    }
}

// MARK: - Ledger Protocol

/// Where ``BlastService`` records how many reads it sent to NCBI in the
/// last hour. Implementations make ``reserve(count:at:limit:)`` atomic.
public protocol BlastSubmissionLedger: Sendable {
    /// Atomically checks the rolling-hour budget and records `count` reads.
    func reserve(count: Int, at now: Date, limit: Int) async throws

    /// The events still inside the window at `now`.
    func events(at now: Date) async -> [BlastSubmissionLedgerEvent]
}

// MARK: - In-Memory Ledger

/// A per-process ledger. Quitting the process forgets it; used by tests and
/// by services created without a storage root.
public actor InMemoryBlastSubmissionLedger: BlastSubmissionLedger {
    private var stored: [BlastSubmissionLedgerEvent]

    public init(events: [BlastSubmissionLedgerEvent] = []) {
        self.stored = events
    }

    public func reserve(count: Int, at now: Date, limit: Int) async throws {
        try BlastSubmissionBudget.reserve(&stored, count: count, at: now, limit: limit)
    }

    public func events(at now: Date) async -> [BlastSubmissionLedgerEvent] {
        stored = BlastSubmissionBudget.prune(stored, now: now)
        return stored
    }
}

// MARK: - File Ledger

/// A ledger kept as JSON on disk, so quitting and relaunching the app, or
/// running the CLI beside it, does not reset NCBI's hourly budget.
///
/// Each reservation takes an exclusive `flock` on a sibling lock file,
/// re-reads the file, applies the budget rule, and writes the file back
/// atomically, so the app and CLI processes share one budget. If the file
/// cannot be read or written the ledger keeps working in memory and logs a
/// warning; a storage problem never blocks BLAST.
public actor FileBlastSubmissionLedger: BlastSubmissionLedger {

    /// File name of the ledger inside its directory.
    public static let fileName = "submission-ledger.json"

    /// Directory under the managed storage root that holds the ledger.
    public static let directoryName = "blast"

    private let fileURLProvider: @Sendable () async -> URL?
    private var resolvedURL: URL?
    private var didResolve = false
    private var memoryFallback: [BlastSubmissionLedgerEvent] = []

    /// Creates a ledger stored at `fileURL`.
    public init(fileURL: URL) {
        self.fileURLProvider = { fileURL }
    }

    /// Creates a ledger whose file location is resolved on first use.
    public init(fileURLProvider: @escaping @Sendable () async -> URL?) {
        self.fileURLProvider = fileURLProvider
    }

    /// The ledger file for a managed storage root:
    /// `<root>/blast/submission-ledger.json`.
    public static func fileURL(storageRoot: URL) -> URL {
        storageRoot
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// The ledger under the active managed storage root.
    public static func managedStorageDefault() -> FileBlastSubmissionLedger {
        FileBlastSubmissionLedger {
            let root = await MainActor.run { ManagedStorageConfigStore.shared.currentLocation().rootURL }
            return fileURL(storageRoot: root)
        }
    }

    public func reserve(count: Int, at now: Date, limit: Int) async throws {
        guard let url = await fileURL() else {
            try BlastSubmissionBudget.reserve(&memoryFallback, count: count, at: now, limit: limit)
            return
        }
        try Self.withExclusiveLock(for: url) {
            var events = Self.read(url) ?? memoryFallback
            try BlastSubmissionBudget.reserve(&events, count: count, at: now, limit: limit)
            memoryFallback = events
            Self.write(events, to: url)
        }
    }

    public func events(at now: Date) async -> [BlastSubmissionLedgerEvent] {
        guard let url = await fileURL() else {
            return BlastSubmissionBudget.prune(memoryFallback, now: now)
        }
        let events = Self.read(url) ?? memoryFallback
        return BlastSubmissionBudget.prune(events, now: now)
    }

    // MARK: - File access

    private func fileURL() async -> URL? {
        if !didResolve {
            resolvedURL = await fileURLProvider()
            didResolve = true
        }
        return resolvedURL
    }

    private struct LedgerFile: Codable {
        var schemaVersion: Int
        var events: [BlastSubmissionLedgerEvent]
    }

    private static func read(_ url: URL) -> [BlastSubmissionLedgerEvent]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(LedgerFile.self, from: data).events
        } catch {
            ledgerLogger.warning("Could not read BLAST submission ledger at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func write(_ events: [BlastSubmissionLedgerEvent], to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(LedgerFile(schemaVersion: 1, events: events))
            try data.write(to: url, options: .atomic)
        } catch {
            ledgerLogger.warning("Could not write BLAST submission ledger at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Runs `body` while holding an exclusive advisory lock on `<url>.lock`.
    /// Runs `body` unlocked if the lock file cannot be opened.
    private static func withExclusiveLock<T>(for url: URL, _ body: () throws -> T) rethrows -> T {
        let lockURL = url.appendingPathExtension("lock")
        try? FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return try body() }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
