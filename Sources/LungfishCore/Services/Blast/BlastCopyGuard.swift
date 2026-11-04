// BlastCopyGuard.swift - Holds back LGE's own copies of a BLAST search on a bad day at NCBI, across processes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.core, category: "BlastCopyGuard")

/// Holds back LGE's own copies of a BLAST search when NCBI is having a bad day (ARCH-BLAST-RESILIENCE item 6, section 3).
///
/// Two spent searches in a row pause every copy for an hour, a search that comes back inside its first minutes resets
/// the count, and at most a set number of copies go in a rolling hour. The state is `<root>/blast/copy-guard.json`,
/// read and written under a `flock` on `copy-guard.json.lock`, so every process on this Mac shares it and the kernel
/// lets go of the lock when a process dies. A copy withheld costs a wait and never a search. So a file that cannot be
/// read counts as no pause, with a log line, and a lock that cannot be had leaves this process going on alone, since a
/// storage fault must not stop a rescue. A person's own Send Again does not ask the guard.
package actor BlastCopyGuard {
    /// The file's name in the folder that holds what BLAST shares across processes.
    package static let fileName = "copy-guard.json"

    /// What the guard says to a copy that is due.
    package enum Answer: Sendable, Equatable {
        /// The copy may go, and it is counted.
        case granted
        /// Two spent searches in a row paused every copy until this time.
        case paused(until: Date)
        /// The hour's copies are all out, and the next may go at this time.
        case capFull(until: Date)
    }

    /// The file's shape, `{schemaVersion, spentInARow, pausedUntil, copySends[]}`.
    package struct State: Codable, Sendable, Equatable {
        package var schemaVersion = 1
        package var spentInARow = 0
        package var pausedUntil: Date?
        package var copySends: [Date] = []

        package init() {}
    }

    private let fileProvider: @Sendable () async -> URL?
    private var resolved: URL?
    private var didResolve = false
    private let lockWait: TimeInterval
    /// What this process knows when there is no file, or none it can read.
    private var memory = State()

    /// A guard on `file`. With no file a guard holds only this process's copies, as a test's does.
    package init(file: URL? = nil, lockWait: TimeInterval = BlastSearchPolicy.gateLockWait) {
        self.fileProvider = { file }
        self.lockWait = lockWait
    }

    private init(fileProvider: @escaping @Sendable () async -> URL?) {
        self.fileProvider = fileProvider
        self.lockWait = BlastSearchPolicy.gateLockWait
    }

    /// The guard under the active managed storage root. A debug build's stand-in run keeps it in its own state folder
    /// instead (``BlastStandInState``), so two children can share it and neither touches the root.
    package static func managedStorageDefault(environment: [String: String]) -> BlastCopyGuard {
        BlastCopyGuard {
            let root = await MainActor.run { ManagedStorageConfigStore.shared.currentLocation().rootURL }
            return BlastStandInState.sharedFolder(environment: environment, storageRoot: root)
                .appendingPathComponent(fileName, isDirectory: false)
        }
    }

    // MARK: A copy

    /// Asks for a copy at `now`, and counts it when the answer is ``Answer/granted``.
    package func takeCopy(at now: Date) async -> Answer {
        await change { state in
            state.copySends = Self.inTheWindow(state.copySends, now: now)
            if let until = state.pausedUntil {
                // A pause further off than a whole pause can only come from a clock moved back, and reads as over.
                if until > now, until.timeIntervalSince(now) <= BlastSearchPolicy.guardPause {
                    return .paused(until: until)
                }
                state.pausedUntil = nil
            }
            guard state.copySends.count < BlastSearchPolicy.maxCopiesAnHour else {
                let oldest = state.copySends.min() ?? now
                return .capFull(until: oldest.addingTimeInterval(BlastSearchPolicy.copyWindow))
            }
            state.copySends.append(now)
            return .granted
        }
    }

    /// Gives back the copy taken at `date`, when the ledger refused it, so a copy that never went counts for nothing.
    package func giveBack(takenAt date: Date) async {
        await change { state in
            let closest = state.copySends.indices.min {
                abs(state.copySends[$0].timeIntervalSince(date)) < abs(state.copySends[$1].timeIntervalSince(date))
            }
            if let closest { state.copySends.remove(at: closest) }
        }
    }

    // MARK: How searches went

    /// One more search used up its copies. The last of a run sets the pause and starts the count again.
    package func searchWasSpent(at now: Date) async {
        await change { state in
            state.spentInARow += 1
            if state.spentInARow >= BlastSearchPolicy.spentInARowThatPause {
                state.pausedUntil = now.addingTimeInterval(BlastSearchPolicy.guardPause)
                state.spentInARow = 0
                logger.info("Two spent BLAST searches in a row pause LGE's copies for an hour")
            }
        }
    }

    /// A search came back inside its first minutes, so NCBI is answering and the count starts again.
    package func searchCameBackInTime() async {
        await change { $0.spentInARow = 0 }
    }

    /// What the guard holds, for a reader that shows it. Nothing here counts a copy.
    package func state() async -> State {
        await change { $0 }
    }

    // MARK: The file

    private static func inTheWindow(_ sends: [Date], now: Date) -> [Date] {
        sends.filter { now.timeIntervalSince($0) < BlastSearchPolicy.copyWindow }
    }

    private func file() async -> URL? {
        if !didResolve {
            resolved = await fileProvider()
            didResolve = true
        }
        return resolved
    }

    /// Reads the state, runs `body` and writes what it left, all under the lock. No other lock is ever held with it.
    private func change<Result: Sendable>(_ body: (inout State) -> Result) async -> Result {
        guard let url = await file() else { return body(&memory) }
        let descriptor = await lock(url)
        defer {
            if let descriptor {
                flock(descriptor, LOCK_UN)
                close(descriptor)
            }
        }
        var state = read(url) ?? memory
        let before = state
        let result = body(&state)
        memory = state
        if state != before { write(state, to: url) }
        return result
    }

    private func read(_ url: URL) -> State? {
        do {
            return try BlastSubmissionRecord.decoder.decode(State.self, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            return State()
        } catch {
            logger.warning("Could not read the BLAST copy guard, which counts as no pause: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func write(_ state: State, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try DurableReplace.replace(
                BlastSubmissionRecord.encoder.encode(state), named: url.lastPathComponent, in: url.deletingLastPathComponent()
            )
        } catch {
            logger.warning("Could not write the BLAST copy guard: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Tries for the lock on real seconds whatever clock a search reads, and goes on without it when the time is up.
    private func lock(_ url: URL) async -> Int32? {
        let lockURL = url.appendingPathExtension("lock")
        try? FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            logger.warning("The BLAST copy guard has no lock file it can open, so this process goes on alone")
            return nil
        }
        let deadline = ContinuousClock.now + .seconds(lockWait)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, ContinuousClock.now < deadline else {
                logger.warning("The BLAST copy guard could not be locked, so this process goes on alone")
                close(descriptor)
                return nil
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return descriptor
    }
}
