// BlastContactGate.swift - Spaces every contact with BLAST from this Mac, across processes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.core, category: "BlastContactGate")

/// Gives each POST, status check and fetch a slot, ``BlastSearchPolicy/contactSpacing`` seconds after the last slot any
/// process on this Mac took (ARCH-BLAST-RESILIENCE item 9 and section 4).
///
/// A contact takes the lock on `<root>/blast/contact-gate`, writes its slot there, lets go and only then sleeps to the
/// slot, so no process waits under the lock. The kernel lets go of a `flock` when its process dies, so a killed process
/// costs at most one slot and leaves nothing stale. A last slot too far ahead reads as now, which covers a clock moved
/// back. The gate never ends a search: a lock it cannot have, a file it cannot open and a value it cannot read all
/// leave this process with its own spacing, and only a cancel comes out of it as an error.
package actor BlastContactGate {
    /// The file's name in the folder that holds what BLAST shares across processes.
    package static let fileName = "contact-gate"

    private struct Place: Sendable {
        let file: URL?
        let clock: BlastSearchClock
    }

    private let placeProvider: @Sendable () async -> Place
    private var resolved: Place?
    private let lockWait: TimeInterval
    /// The last slot this process took, which is all the spacing it has when the file cannot be used.
    private var lastSlotHere: Date?

    /// A gate on `file`, read on `clock`. With no file a gate spaces only this process.
    package init(file: URL?, clock: BlastSearchClock, lockWait: TimeInterval = BlastSearchPolicy.gateLockWait) {
        self.placeProvider = { Place(file: file, clock: clock) }
        self.lockWait = lockWait
    }

    private init(placeProvider: @escaping @Sendable () async -> Place) {
        self.placeProvider = placeProvider
        self.lockWait = BlastSearchPolicy.gateLockWait
    }

    /// The gate under the active managed storage root, on this run's clock. A debug build's stand-in run keeps it in
    /// its own state folder instead (``BlastStandInState``), so two children can share it and neither touches the root.
    package static func managedStorageDefault(environment: [String: String]) -> BlastContactGate {
        BlastContactGate {
            let root = await MainActor.run { ManagedStorageConfigStore.shared.currentLocation().rootURL }
            let shared = BlastStandInState.sharedFolder(environment: environment, storageRoot: root)
            return Place(
                file: shared.appendingPathComponent(fileName, isDirectory: false),
                clock: BlastSearchClock(environment: environment, sharedFolder: shared)
            )
        }
    }

    /// Waits for this contact's slot. It throws only when the task is cancelled.
    package func takeSlot() async throws {
        let place = await resolvedPlace()
        let slot = try await reserveSlot(in: place)
        let wait = slot.timeIntervalSince(place.clock.now())
        if wait > 0 { try await place.clock.sleep(wait) }
    }

    /// `last` + the spacing, or `now` when that has passed. A `last` too far ahead to be real reads as `now`.
    package static func slot(after last: Date?, now: Date) -> Date {
        guard var last else { return now }
        if last.timeIntervalSince(now) > BlastSearchPolicy.gateFutureLimit { last = now }
        return max(now, last.addingTimeInterval(BlastSearchPolicy.contactSpacing))
    }

    private func resolvedPlace() async -> Place {
        if let resolved { return resolved }
        let place = await placeProvider()
        resolved = place
        return place
    }

    private func reserveSlot(in place: Place) async throws -> Date {
        guard let file = place.file, let descriptor = Self.openFile(file) else {
            logger.warning("The BLAST contact gate has no file it can open, so this process keeps its own spacing")
            return slotHere(place)
        }
        defer { close(descriptor) }
        guard try await lock(descriptor) else {
            logger.warning("The BLAST contact gate could not be locked, so this process keeps its own spacing")
            return slotHere(place)
        }
        defer { flock(descriptor, LOCK_UN) }
        let slot = Self.slot(after: Self.lastSlot(in: descriptor), now: place.clock.now())
        Self.write(slot, to: descriptor)
        lastSlotHere = slot
        return slot
    }

    private func slotHere(_ place: Place) -> Date {
        let slot = Self.slot(after: lastSlotHere, now: place.clock.now())
        lastSlotHere = slot
        return slot
    }

    /// Tries for the lock until `lockWait` has passed, on real seconds whatever clock the gate reads.
    private func lock(_ descriptor: Int32) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(lockWait)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private static func openFile(_ file: URL) -> Int32? {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        return descriptor >= 0 ? descriptor : nil
    }

    /// The slot the file holds, or nil for a file that is empty or cannot be read as one.
    private static func lastSlot(in descriptor: Int32) -> Date? {
        var bytes = [UInt8](repeating: 0, count: 64)
        let count = pread(descriptor, &bytes, bytes.count, 0)
        guard count > 0 else { return nil }
        let text = String(decoding: bytes.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seconds = Double(text), seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Writes in place, since the lock belongs to this file and a replaced file would not share it.
    private static func write(_ slot: Date, to descriptor: Int32) {
        let bytes = Array("\(slot.timeIntervalSince1970)\n".utf8)
        guard ftruncate(descriptor, 0) == 0, pwrite(descriptor, bytes, bytes.count, 0) == bytes.count else {
            logger.warning("The BLAST contact gate could not write its slot, so the next contact may come sooner")
            return
        }
    }
}
