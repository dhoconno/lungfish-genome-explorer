// ClumpifyDiskNeed.swift - The free disk a Mac import needs before BBTools clumpify reorders one sample's reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "ClumpifyDiskNeed")

/// The free disk space a Mac import asks for before BBTools clumpify reorders one sample's reads (C5 lane DISK, the
/// BIO and QA ruling "a free-disk check before clumpify").
///
/// The automatic clumping choice names clumpify for every sample of short reads whatever its size (C5 O49, D5), so a
/// large import now writes clumpify's work where it wrote none before. Before each sample's clumpify the import refuses
/// that sample when the volume holding clumpify's work folder has less free space than ``needBytes(inputBytes:)``. It
/// never skips clumpify for lack of disk instead, since a choice that depends on the host's disk is what O49 and D5
/// removed.
///
/// clumpify's work folder is the ingestion config's `outputDirectory`. The pipeline names its output file there, hands
/// the folder to the storage step as the working directory of every clumpify launch, and the step writes its split
/// scratch there. In a batch import it is the sample's workspace under the project's `.tmp` folder.
public enum ClumpifyDiskNeed {

    /// Free bytes asked for each byte of the sample's read files. C4's node run of one sample peaked at 5,463,083,200
    /// bytes of work for 422,847,301 bytes of reads. Past the reads and the tool environment that is 4.0 times the
    /// reads, and the 1.25 margin of CHTC's plan makes 5.
    public static let multiple: Int64 = 5

    /// The free bytes one sample needs: five times the size on disk of its read files. A negative size counts as zero,
    /// and a product past `Int64.max` is `Int64.max`, so a very large input never wraps into a small need.
    public static func needBytes(inputBytes: Int64) -> Int64 {
        let (product, overflow) = max(0, inputBytes).multipliedReportingOverflow(by: multiple)
        return overflow ? Int64.max : product
    }

    /// Reads the free bytes of the volume that holds a folder, nil when the volume does not answer. A `Sendable`
    /// closure, so it runs wherever the import runs and never on the main actor.
    public typealias FreeSpaceReader = @Sendable (URL) -> Int64?

    /// The Mac's reading: the bytes available for important usage on the folder's volume, which counts the space the
    /// system can purge, as the assembly sheet's disk check reads it. nil when the volume does not answer.
    public static let volumeFreeSpace: FreeSpaceReader = { folder in
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// The reader the pipeline consults. A task-local, so a test replaces it for one import without a change to the
    /// batch importer. Nothing outside a test sets it.
    @TaskLocal public static var freeSpaceReader: FreeSpaceReader = ClumpifyDiskNeed.volumeFreeSpace

    /// The size on disk of the read files, in bytes, measured now. A symbolic link counts as the file it names, and a
    /// file that cannot be read counts as zero.
    public static func inputBytes(of files: [URL]) -> Int64 {
        files.reduce(Int64(0)) { total, url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
            return total + max(0, attributes?[.size] as? Int64 ?? 0)
        }
    }

    /// What the check decided for one sample.
    public enum Verdict: Equatable, Sendable {
        /// The volume has at least the bytes the reads need.
        case enough
        /// The volume has less free space than clumpify needs, so the sample is refused.
        case tooLittle(needBytes: Int64, freeBytes: Int64)
        /// The volume did not answer, so the import goes ahead. `logLine` names the folder.
        case unreadable(logLine: String)
    }

    /// Compares the free space of the volume holding `folder` with what the reads need. Free space equal to the need
    /// passes. The reader is a parameter, so a test decides what the volume holds.
    public static func verdict(inputFiles: [URL], folder: URL, freeSpace: FreeSpaceReader) -> Verdict {
        let need = needBytes(inputBytes: inputBytes(of: inputFiles))
        guard let free = freeSpace(folder) else {
            return .unreadable(
                logLine: "Could not read the free space of the disk that holds \(folder.path), "
                    + "so the free-disk check before clumpify is skipped for this sample."
            )
        }
        return free < need ? .tooLittle(needBytes: need, freeBytes: free) : .enough
    }

    /// Refuses the sample when its disk is too small, before clumpify starts or writes anything for it. A volume that
    /// does not answer lets the import go ahead with one log line that names the folder.
    ///
    /// - Throws: ``FASTQIngestionError/insufficientDiskForClumpify(sample:needBytes:freeBytes:folder:)``.
    static func require(
        sample: String,
        inputFiles: [URL],
        folder: URL,
        freeSpace: FreeSpaceReader = ClumpifyDiskNeed.freeSpaceReader
    ) throws {
        switch verdict(inputFiles: inputFiles, folder: folder, freeSpace: freeSpace) {
        case .enough:
            return
        case .unreadable(let logLine):
            logger.warning("\(logLine, privacy: .public)")
        case .tooLittle(let need, let free):
            throw FASTQIngestionError.insufficientDiskForClumpify(
                sample: sample, needBytes: need, freeBytes: free, folder: folder
            )
        }
    }

    /// The refusal the import shows, with the sizes in the Finder's units.
    static func refusal(sample: String, needBytes: Int64, freeBytes: Int64, folder: URL) -> String {
        let need = ByteCountFormatter.string(fromByteCount: needBytes, countStyle: .file)
        let free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
        return "\(sample) needs about \(need) free for clumpify to reorder its reads for storage, and the disk that "
            + "holds \(folder.path) has \(free) free. Free space there, or import with no clumping "
            + "(--clumping-tool none)."
    }
}
