// StagingScratchNeed.swift - The free disk the fixed-order staging needs before it writes its scratch and outputs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore
import LungfishIO

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "StagingScratchNeed")

/// The FASTQ text of read files, as each file states it. The scratch need and the bucket count of ``SeededPairOrder``
/// both start from it (row FASTP-STAGING-MEMORY, findings F1 and F2 of lane FASTP-MEM).
enum ReadTextSize {

    /// The bytes a read's text holds past its bases and qualities: its header line, the plus line and four newlines.
    /// D1b's SRA names make about 48 (2,400,000 reads of 179,644,531 bases in 475,153,254 bytes of text), so 64 covers
    /// them and Illumina names of up to about 60 characters.
    static let perReadBytes: Int64 = 64

    /// The text bytes `url` states, nil when nothing does. A plain file states its size. A gzip file states its text
    /// through the reads and bases of its statistics sidecar (``FASTQMetadataStore``), two bytes a base and
    /// ``perReadBytes`` a read, unless that is less than the gzip file's own size, which says the sidecar describes
    /// another file. D1b's 19,279,040 pairs stated that way are 8,240,007,312 bytes against 7,740,781,880 counted, 6% over.
    static func stated(by url: URL) -> Int64? {
        guard let size = fileSize(url) else { return nil }
        guard url.pathExtension.lowercased() == "gz" else { return size }
        let resolved = url.resolvingSymlinksInPath()
        guard let statistics = (FASTQMetadataStore.load(for: url) ?? FASTQMetadataStore.load(for: resolved))?.computedStatistics,
              statistics.readCount > 0 else {
            return nil
        }
        let (bases, basesOverflow) = max(0, statistics.baseCount).multipliedReportingOverflow(by: 2)
        let (names, namesOverflow) = Int64(statistics.readCount).multipliedReportingOverflow(by: perReadBytes)
        let (text, sumOverflow) = bases.addingReportingOverflow(names)
        if basesOverflow || namesOverflow || sumOverflow { return Int64.max }
        return text >= size ? text : nil
    }

    /// The text of `urls`: each file as it states it, and a gzip file that states nothing at `gzipExpansion` times its
    /// size. A file that cannot be read counts as zero, and the sum stops at `Int64.max`.
    static func estimate(of urls: [URL], gzipExpansion: Int64) -> Int64 {
        var total: Int64 = 0
        for url in urls {
            let bytes: Int64
            if let text = stated(by: url) {
                bytes = text
            } else {
                let (product, overflow) = (fileSize(url) ?? 0).multipliedReportingOverflow(by: max(1, gzipExpansion))
                bytes = overflow ? Int64.max : product
            }
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            total = overflow ? Int64.max : sum
        }
        return total
    }

    /// The size of a file, a symbolic link counted as the file it names, nil when it cannot be read.
    private static func fileSize(_ url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        return (attributes?[.size] as? NSNumber).map { max(0, $0.int64Value) }
    }
}

/// The free disk space the fixed-order staging asks for before it writes anything (row FASTP-STAGING-MEMORY, ruling
/// BIO-ROWS-1-3, item 6).
///
/// Two routes write the reads out again in the seeded order of ``SeededPairOrder``. The fastp trim (`fastq trim`,
/// quality-trim, adapter-trim and fixed-trim, and the FASTQ window's trims through `FASTQDerivativeService`, all through
/// ``FastpPairedRunner``) keeps its work files in a hidden folder beside its output, and the Viral Recon staging keeps its
/// bucket files and its gzip outputs under the run's split folder. Neither said anything about disk before it started, so
/// a disk that was too small ended the run part way. Each route now compares the free space of the disk that holds its
/// work with ``needBytes(inputFiles:route:)`` and refuses with ``Refusal`` when the disk has less. A volume that does not
/// answer lets the run go ahead with one log line, as ``ClumpifyDiskNeed`` does.
///
/// The need is a multiple of the reads' text (``ReadTextSize``), taken from what the scratch holds and from D1b, which ran
/// both routes on 19,279,040 pairs: 7,740,781,880 bytes of text in 604,385,740 bytes of gzip (`gzip -dc | wc -c`).
/// - The trim's work holds at most three copies of the text: the R1 and R2 that fastp reads, fastp's two outputs and the
///   interleaved output. D1b peaked at 18,693,724 KB, 2.47 times the text. The need is three times the stated text, a
///   margin of 1.29 over the measure with the 6% the statement adds.
/// - The Viral Recon staging holds the LZ4-packed bucket files, all of them when the partition ends, and then the gzip
///   outputs that take their place. D1b's duplicate-rich reads peaked at 0.23 of the text, but real diverse reads
///   (HG002 chr20, measured with compression_tool) pack to 0.64, so the need is three quarters of the stated text, a
///   margin of 1.16 over that. A virtual bundle that the plan materializes first writes its text once more, which this
///   need does not count.
enum StagingScratchNeed {

    /// The two routes that stage reads in the seeded order, each with its own work on disk.
    enum Route: Sendable {
        /// The fastp trim of ``FastpPairedRunner``, whose work files sit beside the output.
        case fastpTrim
        /// The Viral Recon staging of ``ViralReconReadPairing``, whose files sit under the run's split folder.
        case viralReconStaging
    }

    /// How many times its size a gzip read file that states no text is counted. Reads as a sequencer writes them pack
    /// about 3 to 5 to 1 in gzip (not measured here) and clumped reads more (D1b's 12.8 to 1), so this never asks an
    /// ordinary run for more than it needs. A file of clumped reads with no sidecar can be asked for less, which leaves it
    /// where it was before the check.
    static let gzipExpansion: Int64 = 4

    /// The need as a fraction of the reads' text.
    private static func factor(for route: Route) -> (numerator: Int64, denominator: Int64) {
        switch route {
        case .fastpTrim: return (3, 1)
        case .viralReconStaging: return (3, 4)
        }
    }

    /// The free bytes a route needs for reads of `textBytes` bytes of FASTQ text, rounded up. A negative size counts as
    /// zero, and a need past `Int64.max` is `Int64.max`, so a very large input never wraps into a small need.
    static func needBytes(textBytes: Int64, route: Route) -> Int64 {
        let scale = factor(for: route)
        let (product, overflow) = max(0, textBytes).multipliedReportingOverflow(by: scale.numerator)
        guard !overflow, product <= Int64.max - (scale.denominator - 1) else { return Int64.max }
        return (product + scale.denominator - 1) / scale.denominator
    }

    /// The free bytes a route needs for these read files, measured now from the text each states.
    static func needBytes(inputFiles: [URL], route: Route) -> Int64 {
        needBytes(textBytes: ReadTextSize.estimate(of: inputFiles, gzipExpansion: gzipExpansion), route: route)
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
