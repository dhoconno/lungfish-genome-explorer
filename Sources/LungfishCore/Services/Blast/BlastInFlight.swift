// BlastInFlight.swift - The lines that find BLAST searches with no project open, and the lock on each search
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.core, category: "BlastInFlight")

/// One search's line, `<root>/blast/in-flight/<searchID>.json`.
///
/// It is an index that holds a label and a path and no reads, so losing it loses no search, since a project's opening
/// adopts the folder again (ARCH-BLAST-RESILIENCE section 1). A line outlives its search's ending until
/// ``BlastSearchPolicy/lineRetention``, so that a copied folder still reads as a copy after the first folder is done.
package struct BlastInFlightLine: Codable, Sendable, Equatable {
    package static let currentSchemaVersion = 1

    package var schemaVersion: Int
    package var searchID: UUID
    /// The result folder that sends for this search.
    package var output: String
    /// The search's label, which is the taxon or query name.
    package var label: String
    package var origin: BlastSearchFile.Origin
    package var state: BlastSearchFile.State
    package var createdAt: Date
    package var lastContactAt: Date
    /// When a pass next has something to do, nil once the search has ended.
    package var nextDueAt: Date?
    package var rids: [String]
    /// The row's words as the last writer left them.
    package var words: String

    package init(_ file: BlastSearchFile, output: URL, words: String, now: Date) {
        self.schemaVersion = Self.currentSchemaVersion
        self.searchID = file.searchID
        self.output = output.standardizedFileURL.path
        self.label = file.facts.taxonName
        self.origin = file.origin
        self.state = file.state
        self.createdAt = file.createdAt
        self.lastContactAt = file.copies.flatMap { [$0.postAt, $0.lastCheckAt].compactMap { $0 } }.max() ?? file.createdAt
        self.nextDueAt = file.state.isEnding ? nil : file.nextStep(now: now).due
        self.rids = file.copies.compactMap(\.rid)
        self.words = words
    }
}

/// How a result folder stands against the line of its search (items 18 and 19).
package enum BlastFolderStanding: Sendable, Equatable {
    /// The line names this folder.
    case home
    /// No line names this search, so this folder takes it up.
    case noLine
    /// The line names a folder that has gone, so this one is where the project went.
    case moved
    /// The line names another folder that still exists, so this one only checks and fetches and never POSTs.
    case copy
}

/// The lock of one search. Only its holder writes the search's files. The kernel frees it when the process dies, so a
/// killed process leaves nothing stale and there is no process number to go wrong (section 3).
package struct BlastSearchLock: Sendable {
    fileprivate let descriptor: Int32

    /// Lets go before the process ends, for a caller in a process that outlives the search.
    package func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// What asking for the lock came to.
    package enum Answer: Sendable {
        case taken(BlastSearchLock)
        case heldByAnother
        /// The root cannot hold a lock, which must not stop a rescue, so the search goes on without one.
        case unavailable
    }
}

/// The lines and locks under `<root>/blast/in-flight/`. It reads and writes only under the root, since a child at
/// launch that opens a project under `~/Documents` can hang (section 4).
package struct BlastInFlightIndex: Sendable {
    package static let folderName = "in-flight"

    private let folderProvider: @Sendable () async -> URL?

    /// An index in `folder`.
    package init(folder: URL) {
        self.folderProvider = { folder }
    }

    private init(folderProvider: @escaping @Sendable () async -> URL?) {
        self.folderProvider = folderProvider
    }

    /// The index under the active managed storage root, or in a debug stand-in run's own state folder.
    package static func managedStorageDefault(environment: [String: String]) -> BlastInFlightIndex {
        BlastInFlightIndex {
            let root = await MainActor.run { ManagedStorageConfigStore.shared.currentLocation().rootURL }
            return BlastStandInState.sharedFolder(environment: environment, storageRoot: root)
                .appendingPathComponent(folderName, isDirectory: true)
        }
    }

    private func preparedFolder() async -> URL? {
        guard let folder = await folderProvider() else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func read(_ url: URL) -> BlastInFlightLine? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? BlastSubmissionRecord.decoder.decode(BlastInFlightLine.self, from: data)
    }

    // MARK: Lines

    /// Every line this LGE can read. Listings skip `._` names, and a line that cannot be read costs only itself.
    package func lines() async -> [BlastInFlightLine] {
        guard let folder = await folderProvider(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.sorted()
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix("._") }
            .compactMap { Self.read(folder.appendingPathComponent($0, isDirectory: false)) }
    }

    package func line(of searchID: UUID) async -> BlastInFlightLine? {
        guard let folder = await folderProvider() else { return nil }
        return Self.read(folder.appendingPathComponent("\(searchID.uuidString).json", isDirectory: false))
    }

    /// The line that names `output`, for a folder that holds no file to read the ID from, since it has gone.
    package func line(forOutput output: URL) async -> BlastInFlightLine? {
        let path = output.standardizedFileURL.path
        return await lines().first { $0.output == path }
    }

    /// Writes `line`. A line that cannot be written costs only the index, and a project's opening brings it back.
    package func write(_ line: BlastInFlightLine) async {
        guard let folder = await preparedFolder() else { return }
        do {
            let data = try BlastSubmissionRecord.encoder.encode(line)
            try DurableReplace.replace(data, named: "\(line.searchID.uuidString).json", in: folder)
        } catch {
            logger.warning("Could not write a BLAST search's line: \(error.localizedDescription, privacy: .public)")
        }
    }

    package func remove(_ searchID: UUID) async {
        guard let folder = await folderProvider() else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(searchID.uuidString).json", isDirectory: false))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(searchID.uuidString).lock", isDirectory: false))
    }

    /// How `folder` stands against the line of `searchID`.
    package func standing(of searchID: UUID, folder: URL) async -> BlastFolderStanding {
        guard let line = await line(of: searchID) else { return .noLine }
        if line.output == folder.standardizedFileURL.path { return .home }
        return FileManager.default.fileExists(atPath: line.output) ? .copy : .moved
    }

    // MARK: The lock

    /// Asks for the search's lock once, with no wait. It is held until ``BlastSearchLock/release()`` or the process ends.
    package func takeLock(of searchID: UUID) async -> BlastSearchLock.Answer {
        guard let folder = await preparedFolder() else { return .unavailable }
        let path = folder.appendingPathComponent("\(searchID.uuidString).lock", isDirectory: false).path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            logger.warning("Could not open a BLAST search's lock, so this run goes on without one")
            return .unavailable
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let reason = errno
            close(descriptor)
            if reason == EWOULDBLOCK { return .heldByAnother }
            logger.warning("Could not take a BLAST search's lock, so this run goes on without one")
            return .unavailable
        }
        return .taken(BlastSearchLock(descriptor: descriptor))
    }

    // MARK: A person's Stop

    private func stopRequest(of searchID: UUID, in folder: URL) -> URL {
        folder.appendingPathComponent("\(searchID.uuidString).stop", isDirectory: false)
    }

    /// Takes the lock for a person's Stop. A leaf at work reads the request, leaves its files as they stand and ends, so
    /// no later write of its goes over the Stop.
    package func takeLockForStop(of searchID: UUID) async -> BlastSearchLock.Answer {
        guard let folder = await preparedFolder() else { return .unavailable }
        let request = stopRequest(of: searchID, in: folder)
        FileManager.default.createFile(atPath: request.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: request) }
        let deadline = ContinuousClock.now + .seconds(BlastSearchPolicy.stopWait)
        while true {
            let answer = await takeLock(of: searchID)
            guard case .heldByAnother = answer, ContinuousClock.now < deadline else { return answer }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Runs `work`, and ends it as a cancel when a person's Stop asks for the search. A request older than the longest
    /// Stop waits was left by a Stop that died, and it stops nothing.
    package func runStoppable<Value: Sendable>(
        _ searchID: UUID,
        _ work: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        guard let folder = await preparedFolder() else { return try await work() }
        let request = stopRequest(of: searchID, in: folder)
        return try await withThrowingTaskGroup(of: Value?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                while true {
                    if let date = (try? request.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                       Date().timeIntervalSince(date) < BlastSearchPolicy.stopWait {
                        throw CancellationError()
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else { throw CancellationError() }
            return value
        }
    }
}
