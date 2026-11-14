// RunFitPreflight.swift - Refuses a run that cannot fit this Mac's memory or free disk, before it starts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "RunFitPreflight")

/// What one run asks of the machine that starts it (Phase 5.1, lane RS-PREFLIGHT). The caller passes every figure and says
/// where each came from, so this folder sets no figure and names no kind of run. The refusal quotes each basis line.
package struct RunFitNeed: Sendable, Equatable {
    /// The most memory the run holds at once, in bytes.
    package var peakMemoryBytes: Int64
    /// Where the memory figure came from, in one line.
    package var memoryBasis: String
    /// The free disk the run needs, in bytes, on the volume that holds ``diskFolder``.
    package var freeDiskBytes: Int64
    /// Where the disk figure came from, in one line.
    package var diskBasis: String
    /// The folder the disk need is for. It need not exist yet: the volume of its nearest folder that does is read.
    package var diskFolder: URL

    package init(
        peakMemoryBytes: Int64, memoryBasis: String,
        freeDiskBytes: Int64, diskBasis: String, diskFolder: URL
    ) {
        self.peakMemoryBytes = peakMemoryBytes
        self.memoryBasis = memoryBasis
        self.freeDiskBytes = freeDiskBytes
        self.diskBasis = diskBasis
        self.diskFolder = diskFolder
    }

    /// `base * multiple + extra` in bytes, for a caller that derives a need from a size. A negative term counts as zero,
    /// and a product or a sum past `Int64.max` is `Int64.max`, so a very large input never wraps into a small need.
    package static func bytes(_ base: Int64, times multiple: Int64, plus extra: Int64 = 0) -> Int64 {
        let (product, productOverflow) = max(0, base).multipliedReportingOverflow(by: max(0, multiple))
        guard !productOverflow else { return Int64.max }
        let (total, totalOverflow) = product.addingReportingOverflow(max(0, extra))
        return totalOverflow ? Int64.max : total
    }
}

/// The facts of the host that the check reads. It has no default that reads `ProcessInfo`, as ``ExecutorPlanHostFacts``
/// has none, so a test tells two Macs apart by what each is handed. A caller passes
/// `Int64(clamping: ProcessInfo.processInfo.physicalMemory)`.
package struct RunFitHostFacts: Sendable, Equatable {
    package var physicalMemoryBytes: Int64

    package init(physicalMemoryBytes: Int64) {
        self.physicalMemoryBytes = physicalMemoryBytes
    }
}

/// The refusal of a run that cannot fit this Mac. Each case carries the Linux route the caller named, so no refusal leaves
/// it out. The words are what the app and the command line show.
package enum RunFitError: Error, LocalizedError, Equatable, Sendable {
    case insufficientMemory(needBytes: Int64, haveBytes: Int64, basis: String, linuxRoute: String)
    case insufficientDisk(needBytes: Int64, freeBytes: Int64, folder: URL, basis: String, linuxRoute: String)

    package var errorDescription: String? {
        switch self {
        case .insufficientMemory(let need, let have, let basis, let route):
            return RunFitPreflight.memoryRefusal(needBytes: need, haveBytes: have, basis: basis, linuxRoute: route)
        case .insufficientDisk(let need, let free, let folder, let basis, let route):
            return RunFitPreflight.diskRefusal(
                needBytes: need, freeBytes: free, folder: folder, basis: basis, linuxRoute: route
            )
        }
    }
}

/// One check for every run that asks for memory or disk, so a run that cannot fit this Mac is refused before it starts, in
/// words that name the Linux route. ``ClumpifyDiskNeed`` keeps its own rule for clumpify's work folder.
package enum RunFitPreflight {

    /// Reads the free bytes of the volume that holds a folder, nil when the volume does not answer. A `Sendable` closure,
    /// so it runs wherever the run starts and a test replaces it.
    package typealias FreeSpaceReader = @Sendable (URL) -> Int64?

    /// The Mac's reading: the bytes available for important usage on the volume of the folder, or of the nearest folder
    /// above it that exists, since a run's folder is often made after the check. It counts the space the system can purge,
    /// as the assembly sheet's disk check does. nil when the volume does not answer.
    package static let volumeFreeSpace: FreeSpaceReader = { folder in
        var nearest = folder
        var steps = 0
        while !FileManager.default.fileExists(atPath: nearest.path), steps < 64 {
            nearest = nearest.deletingLastPathComponent()
            steps += 1
        }
        let values = try? nearest.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// What the check decided for one run.
    package enum Verdict: Equatable, Sendable {
        /// The host has the memory and the volume has the free disk the run needs.
        case enough
        /// The run needs more memory than the host has.
        case tooLittleMemory(needBytes: Int64, haveBytes: Int64)
        /// The volume has less free space than the run needs.
        case tooLittleDisk(needBytes: Int64, freeBytes: Int64)
        /// The volume did not answer, so the run goes ahead. `logLine` names the folder.
        case unreadable(logLine: String)
    }

    /// Compares the need with the host's memory and with the free space of the volume that holds the need's folder. A need
    /// equal to what the host has passes. Memory comes first, since no one can free it, and a memory refusal reads no volume.
    /// A need of no disk reads no volume. The reader is a parameter, so a test decides what the volume holds.
    package static func verdict(need: RunFitNeed, host: RunFitHostFacts, freeSpace: FreeSpaceReader) -> Verdict {
        let memoryNeed = max(0, need.peakMemoryBytes)
        if memoryNeed > host.physicalMemoryBytes {
            return .tooLittleMemory(needBytes: memoryNeed, haveBytes: host.physicalMemoryBytes)
        }
        let diskNeed = max(0, need.freeDiskBytes)
        guard diskNeed > 0 else { return .enough }
        guard let available = freeSpace(need.diskFolder) else {
            return .unreadable(
                logLine: "Could not read the free space of the disk that holds \(need.diskFolder.path), "
                    + "so the free-disk check before this run is skipped."
            )
        }
        return available < diskNeed ? .tooLittleDisk(needBytes: diskNeed, freeBytes: available) : .enough
    }

    /// Refuses the run when this Mac cannot hold it, before the run starts or writes anything. A volume that does not
    /// answer lets the run go ahead with one log line that names the folder.
    ///
    /// `linuxRoute` is required and never optional. It is a sentence that says how to run this on a Linux machine, such as
    /// the command that writes the run's plan folder, and the refusal ends on it.
    ///
    /// - Throws: ``RunFitError``.
    package static func require(
        need: RunFitNeed,
        host: RunFitHostFacts,
        linuxRoute: String,
        freeSpace: FreeSpaceReader = RunFitPreflight.volumeFreeSpace
    ) throws {
        switch verdict(need: need, host: host, freeSpace: freeSpace) {
        case .enough:
            return
        case .unreadable(let logLine):
            logger.warning("\(logLine, privacy: .public)")
        case .tooLittleMemory(let needBytes, let haveBytes):
            throw RunFitError.insufficientMemory(
                needBytes: needBytes, haveBytes: haveBytes, basis: need.memoryBasis, linuxRoute: linuxRoute
            )
        case .tooLittleDisk(let needBytes, let freeBytes):
            throw RunFitError.insufficientDisk(
                needBytes: needBytes, freeBytes: freeBytes, folder: need.diskFolder,
                basis: need.diskBasis, linuxRoute: linuxRoute
            )
        }
    }

    // MARK: - Words

    private static let gibibyte: Int64 = 1_073_741_824
    private static let gigabyte: Int64 = 1_000_000_000

    /// The memory refusal, with the sizes in the units of a Mac's About window. It names no run, since the caller puts its own
    /// label in front of an error. It says what the run needs and what this Mac has, then where to run it, and ends on the
    /// Linux route.
    static func memoryRefusal(needBytes: Int64, haveBytes: Int64, basis: String, linuxRoute: String) -> String {
        let need = ByteCountFormatter.string(fromByteCount: needBytes, countStyle: .memory)
        var have = ByteCountFormatter.string(fromByteCount: haveBytes, countStyle: .memory)
        if have == need { have = "just under " + have }
        return sentences(
            "This run needs about \(need) of memory\(bracketed(basis)), and this Mac has \(have), so it was not started.",
            "Run it on a Linux machine with at least \(wholeUnits(needBytes, of: gibibyte)) GB of memory.",
            linuxRoute
        )
    }

    /// The disk refusal, with the sizes in the Finder's units and the folder as the caller named it.
    static func diskRefusal(needBytes: Int64, freeBytes: Int64, folder: URL, basis: String, linuxRoute: String) -> String {
        let need = ByteCountFormatter.string(fromByteCount: needBytes, countStyle: .file)
        var free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
        if free == need { free = "just under " + free }
        return sentences(
            "This run needs about \(need) of free disk\(bracketed(basis)), and the disk that holds \(folder.path) has "
                + "\(free) free, so it was not started.",
            "Free up space on that disk and start the run again.",
            "Run it on a Linux machine with at least \(wholeUnits(needBytes, of: gigabyte)) GB of free disk.",
            linuxRoute
        )
    }

    /// The sentences in order, each ended by a full stop, and a blank one left out.
    private static func sentences(_ parts: String...) -> String {
        parts.compactMap { part -> String? in
            var sentence = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let last = sentence.last else { return nil }
            if !".!?".contains(last) { sentence += "." }
            return sentence
        }.joined(separator: " ")
    }

    /// The basis line in brackets after a figure, or nothing when the caller gave none.
    private static func bracketed(_ basis: String) -> String {
        let line = basis.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? "" : " (\(line))"
    }

    /// The bytes in whole units of `unit`, rounded up, so a Linux machine of that size holds them.
    private static func wholeUnits(_ bytes: Int64, of unit: Int64) -> Int64 {
        let (whole, remainder) = max(0, bytes).quotientAndRemainder(dividingBy: unit)
        return remainder == 0 ? whole : whole + 1
    }
}
