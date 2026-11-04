// BlastSubmissionLedger.swift - Rolling-hour record of reads sent to NCBI BLAST
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let ledgerLogger = Logger(subsystem: LogSubsystem.core, category: "BlastSubmissionLedger")

// MARK: - Ledger Event

/// Which kind of POST a ledger event counts. A re-POST counts as what it repeats.
public enum BlastSubmissionKind: String, Sendable, Codable, Equatable {
    /// A search's first send.
    case first
    /// LGE sending a search again on its own.
    case copy
}

/// One BLAST POST: when it was sent, how many reads it carried and what kind it was.
public struct BlastSubmissionLedgerEvent: Sendable, Codable, Equatable {
    public let date: Date
    public let count: Int
    public let kind: BlastSubmissionKind

    public init(date: Date, count: Int, kind: BlastSubmissionKind = .first) {
        self.date = date
        self.count = max(0, count)
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case date, count, kind
    }

    /// An event of an older file holds no `kind`, and every one of those was a first send.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            date: try container.decode(Date.self, forKey: .date),
            count: try container.decode(Int.self, forKey: .count),
            kind: try container.decodeIfPresent(BlastSubmissionKind.self, forKey: .kind) ?? .first
        )
    }
}

// MARK: - Limit Refusal

/// What LGE's own limit says to a POST it holds back. NCBI hears nothing of it.
public struct BlastLimitRefusal: Sendable, Equatable {
    /// The limit that applied, in reads an hour.
    public let limit: Int
    /// The reads that limit has counted in the last hour.
    public let used: Int
    /// The reads this POST would carry.
    public let count: Int
    /// When the reads fit, nil when they are more than the limit and never will.
    public let fitsAt: Date?
    /// When LGE refused.
    public let refusedAt: Date

    public init(limit: Int, used: Int, count: Int, fitsAt: Date?, refusedAt: Date) {
        self.limit = limit
        self.used = used
        self.count = count
        self.fitsAt = fitsAt
        self.refusedAt = refusedAt
    }

    /// The seconds until the reads fit, nil when they never will.
    public var retryAfter: TimeInterval? {
        fitsAt.map { max(1, $0.timeIntervalSince(refusedAt)) }
    }
}

// MARK: - Budget Rule

/// The rolling-window budget rule shared by every ledger implementation.
public enum BlastSubmissionBudget {

    /// Length of the rolling window, one hour.
    public static let window: TimeInterval = 3600

    /// How long the ledger keeps an event, so that it can also count the POSTs of a rolling 24 hours.
    public static let dayWindow: TimeInterval = 86400

    /// Drops events older than a day, checks that `count` more reads fit under
    /// `limit` in the window, and records them at `now`. A first send counts only
    /// first sends, so a copy never refuses one, and a copy counts every POST.
    ///
    /// - Throws: ``BlastServiceError/rateLimitExceeded(_:)`` with when the
    ///   reads fit, which is later than when the oldest event leaves if they
    ///   do not fit even then.
    public static func reserve(
        _ events: inout [BlastSubmissionLedgerEvent],
        count: Int,
        kind: BlastSubmissionKind = .first,
        at now: Date,
        limit: Int,
        window: TimeInterval = window
    ) throws {
        events = prune(events, now: now, window: max(window, dayWindow))
        let inWindow = prune(events, now: now, window: window)
        let counted = kind == .first ? inWindow.filter { $0.kind == .first } : inWindow
        let used = counted.reduce(0) { $0 + $1.count }
        guard used + count <= limit else {
            throw BlastServiceError.rateLimitExceeded(BlastLimitRefusal(
                limit: limit,
                used: used,
                count: count,
                fitsAt: fitTime(of: count, among: counted, used: used, limit: limit, window: window),
                refusedAt: now
            ))
        }
        events.append(BlastSubmissionLedgerEvent(date: now, count: count, kind: kind))
    }

    /// When `count` reads fit as `counted` leave the window one by one, nil when they are more than `limit`.
    private static func fitTime(
        of count: Int,
        among counted: [BlastSubmissionLedgerEvent],
        used: Int,
        limit: Int,
        window: TimeInterval
    ) -> Date? {
        guard count <= limit else { return nil }
        var left = used
        for event in counted.sorted(by: { $0.date < $1.date }) {
            left -= event.count
            if left + count <= limit { return event.date.addingTimeInterval(window) }
        }
        return nil
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
    /// Atomically checks the rolling-hour budget and records `count` reads as `kind`.
    func reserve(count: Int, kind: BlastSubmissionKind, at now: Date, limit: Int) async throws

    /// The events still inside the window at `now`.
    func events(at now: Date) async -> [BlastSubmissionLedgerEvent]

    /// The POSTs of the 24 hours before `now`, each one event whatever reads it carried.
    func postsInTheLastDay(at now: Date) async -> Int
}

// MARK: - In-Memory Ledger

/// A per-process ledger. Quitting the process forgets it; used by tests and
/// by services created without a storage root.
public actor InMemoryBlastSubmissionLedger: BlastSubmissionLedger {
    private var stored: [BlastSubmissionLedgerEvent]

    public init(events: [BlastSubmissionLedgerEvent] = []) {
        self.stored = events
    }

    public func reserve(count: Int, kind: BlastSubmissionKind, at now: Date, limit: Int) async throws {
        try BlastSubmissionBudget.reserve(&stored, count: count, kind: kind, at: now, limit: limit)
    }

    public func events(at now: Date) async -> [BlastSubmissionLedgerEvent] {
        BlastSubmissionBudget.prune(stored, now: now)
    }

    public func postsInTheLastDay(at now: Date) async -> Int {
        BlastSubmissionBudget.prune(stored, now: now, window: BlastSubmissionBudget.dayWindow).count
    }
}

// MARK: - File Ledger

/// A ledger kept as JSON on disk, so quitting and relaunching the app, or
/// running the CLI beside it, does not reset LGE's own hourly limit.
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

    /// The ledger under the active managed storage root. A debug build's stand-in run keeps it in its own state
    /// folder instead (``BlastStandInState``), so two children can share it and neither touches the real root.
    public static func managedStorageDefault(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> FileBlastSubmissionLedger {
        FileBlastSubmissionLedger {
            let root = await MainActor.run { ManagedStorageConfigStore.shared.currentLocation().rootURL }
            return BlastStandInState.sharedFolder(environment: environment, storageRoot: root)
                .appendingPathComponent(fileName, isDirectory: false)
        }
    }

    public func reserve(count: Int, kind: BlastSubmissionKind, at now: Date, limit: Int) async throws {
        guard let url = await fileURL() else {
            try BlastSubmissionBudget.reserve(&memoryFallback, count: count, kind: kind, at: now, limit: limit)
            return
        }
        try Self.withExclusiveLock(for: url) {
            var events = Self.read(url) ?? memoryFallback
            try BlastSubmissionBudget.reserve(&events, count: count, kind: kind, at: now, limit: limit)
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

    public func postsInTheLastDay(at now: Date) async -> Int {
        let events = await fileURL().flatMap { Self.read($0) } ?? memoryFallback
        return BlastSubmissionBudget.prune(events, now: now, window: BlastSubmissionBudget.dayWindow).count
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
