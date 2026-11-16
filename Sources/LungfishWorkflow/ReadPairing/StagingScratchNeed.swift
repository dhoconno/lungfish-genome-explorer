// StagingScratchNeed.swift - The free disk the fixed-order staging needs before it writes its scratch and outputs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "StagingScratchNeed")

/// The free disk space the fixed-order staging asks for before it writes anything (row FASTP-STAGING-MEMORY, ruling
/// BIO-ROWS-1-3, item 6).
///
/// Two routes write the reads out again in the seeded order of ``SeededPairOrder``. The fastp trim (`fastq trim`,
/// quality-trim, adapter-trim and fixed-trim, and the window's trims, all through ``FastpPairedRunner``) keeps its work
/// files in a hidden folder beside its output, and the Viral Recon staging keeps its bucket files and its gzip outputs
/// under the run's split folder. Neither said anything about disk before it started, so a disk that was too small ended
/// the run part way. Each route now compares the free space of the disk that holds its work with ``needBytes(inputFiles:route:)``
/// and refuses with ``Refusal`` when the disk has less. A volume that does not answer lets the run go ahead with one log
/// line, as ``ClumpifyDiskNeed`` does.
///
/// The need comes from D1b, which ran both routes on the same 19,279,040 pairs (604,385,740 bytes of gzip reads, 6.4 GB of
/// FASTQ text, so a gzip file of those reads holds ten times its size).
/// - The trim's work folder peaked at 18,693,724 KB, which is 31.7 times the gzip bytes and three copies of the text. At the
///   peak it holds the seeded R1 and R2, fastp's two outputs and the re-interleaved file. The need is four times the text,
///   so 40 times a gzip file of D1b's reads, a margin of 1.26 over the measure.
/// - The Viral Recon staging peaked at 1,719,860 KB, which is 2.9 times the gzip bytes and 0.28 of the text. It holds the
///   packed bucket files and the two gzip outputs. The need is two fifths of the text, so 4 times a gzip file of D1b's reads,
///   a margin of 1.37 over the measure. A virtual bundle that the plan materializes first writes its text once more, which
///   this need does not count.
///
/// A plain read file counts at its size and a gzip file at ``gzipExpansion`` times its size. Reads that gzip less than D1b's
/// clumped reads need less than that says, so the check can refuse a disk that would have held the run. Finding the text
/// of a gzip file means reading all of it, which the check does not do.
enum StagingScratchNeed {

    /// The two routes that stage reads in the seeded order, each with its own work on disk.
    enum Route: Sendable {
        /// The fastp trim of ``FastpPairedRunner``, whose work files sit beside the output.
        case fastpTrim
        /// The Viral Recon staging of ``ViralReconReadPairing``, whose files sit under the run's split folder.
        case viralReconStaging
    }

    /// How many times its size a gzip read file is counted. D1b's gzip reads held 10.6 times their size in text, and the
    /// whole number below it keeps the need from growing past the measure for reads that gzip less well.
    static let gzipExpansion: Int64 = 10

    /// The need as a fraction of the reads' text.
    private static func factor(for route: Route) -> (numerator: Int64, denominator: Int64) {
        switch route {
        case .fastpTrim: return (4, 1)
        case .viralReconStaging: return (2, 5)
        }
    }

    /// The free bytes a route needs for plain read files of `plainBytes` and gzip read files of `gzipBytes`, rounded up. A
    /// negative size counts as zero, and a need past `Int64.max` is `Int64.max`, so a very large input never wraps into a
    /// small need.
    static func needBytes(plainBytes: Int64, gzipBytes: Int64, route: Route) -> Int64 {
        let (expanded, expandOverflow) = max(0, gzipBytes).multipliedReportingOverflow(by: gzipExpansion)
        let (text, sumOverflow) = expanded.addingReportingOverflow(max(0, plainBytes))
        let scale = factor(for: route)
        let (product, productOverflow) = text.multipliedReportingOverflow(by: scale.numerator)
        guard !expandOverflow, !sumOverflow, !productOverflow, product <= Int64.max - (scale.denominator - 1) else {
            return Int64.max
        }
        return (product + scale.denominator - 1) / scale.denominator
    }

    /// The free bytes a route needs for these read files, measured now. A symbolic link counts as the file it names, and a
    /// file that cannot be read counts as zero.
    static func needBytes(inputFiles: [URL], route: Route) -> Int64 {
        var plain: Int64 = 0
        var gzip: Int64 = 0
        for url in inputFiles {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
            let size = max(0, (attributes?[.size] as? NSNumber)?.int64Value ?? 0)
            if url.pathExtension.lowercased() == "gz" { gzip += size } else { plain += size }
        }
        return needBytes(plainBytes: plain, gzipBytes: gzip, route: route)
    }

    /// Reads the free bytes of the volume that holds a folder, nil when the volume does not answer.
    typealias FreeSpaceReader = ClumpifyDiskNeed.FreeSpaceReader

    /// The reader the staging consults. A task-local, so a test replaces it for one run. Nothing outside a test sets it.
    /// It is read in the task that calls ``require(route:inputFiles:folder:freeSpace:)``, so a caller checks before it
    /// starts a detached task.
    @TaskLocal static var freeSpaceReader: FreeSpaceReader = ClumpifyDiskNeed.volumeFreeSpace

    /// What the check decided.
    enum Verdict: Equatable, Sendable {
        /// The volume has at least the bytes the staging needs.
        case enough
        /// The volume has less free space than the staging needs, so the run is refused.
        case tooLittle(needBytes: Int64, freeBytes: Int64)
        /// The volume did not answer, so the run goes ahead. `logLine` names the folder.
        case unreadable(logLine: String)
    }

    /// Compares the free space of the volume holding `folder` with what the reads need. Free space equal to the need
    /// passes. A volume answers only for a path that exists, so the nearest folder above `folder` that does is asked.
    static func verdict(route: Route, inputFiles: [URL], folder: URL, freeSpace: FreeSpaceReader) -> Verdict {
        let need = needBytes(inputFiles: inputFiles, route: route)
        guard let free = freeSpace(existingFolder(for: folder)) else {
            return .unreadable(
                logLine: "Could not read the free space of the disk that holds \(folder.path), "
                    + "so the free-disk check before staging is skipped."
            )
        }
        return free < need ? .tooLittle(needBytes: need, freeBytes: free) : .enough
    }

    /// Refuses the run when its disk is too small, before it makes a folder or writes a file. A volume that does not answer
    /// lets it go ahead with one log line that names the folder.
    ///
    /// - Throws: ``Refusal``.
    static func require(
        route: Route,
        inputFiles: [URL],
        folder: URL,
        freeSpace: FreeSpaceReader = StagingScratchNeed.freeSpaceReader
    ) throws {
        switch verdict(route: route, inputFiles: inputFiles, folder: folder, freeSpace: freeSpace) {
        case .enough:
            return
        case .unreadable(let logLine):
            logger.warning("\(logLine, privacy: .public)")
        case .tooLittle(let need, let free):
            throw Refusal(route: route, needBytes: need, freeBytes: free, folder: folder)
        }
    }

    /// The refusal a run shows, with the sizes in the Finder's units. It says what the staging needs and what the disk has,
    /// that nothing was written, and what to do.
    struct Refusal: Error, LocalizedError, Equatable {
        let route: Route
        let needBytes: Int64
        let freeBytes: Int64
        let folder: URL

        var errorDescription: String? {
            let need = ByteCountFormatter.string(fromByteCount: needBytes, countStyle: .file)
            var free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
            if free == need { free = "just under " + free }
            switch route {
            case .fastpTrim:
                return "Trimming needs about \(need) free for its work files next to the output, and the disk that holds "
                    + "\(folder.path) has \(free) free, so nothing was trimmed. Free up space on that disk or write the "
                    + "output to a disk with more room, then run the trim again."
            case .viralReconStaging:
                return "Staging the reads for Viral Recon needs about \(need) free for the files it writes, and the disk that "
                    + "holds \(folder.path) has \(free) free, so nothing was staged. Free up space on that disk or keep the "
                    + "project on a disk with more room, then run again."
            }
        }
    }

    /// The nearest folder at or above `folder` that exists.
    static func existingFolder(for folder: URL) -> URL {
        var candidate = folder
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path || parent.path.isEmpty { break }
            candidate = parent
        }
        return candidate
    }
}
