// ClassifierReadResolver+RecordedBAM.swift - The BAM candidates of a classifier result, read only from inside the result root
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: "com.lungfish.workflow", category: "ClassifierReadResolver")

extension ClassifierReadResolver {
    // MARK: - Recorded BAM (decision C4)

    /// The BAM paths that the EsViritu database of a result records for `sampleId`, as the first candidates of
    /// `resolveBAMURL`.
    ///
    /// A one-folder result records `bams/<sample>.third.filt.sorted.bam` and a batch result records
    /// `<sample>/bams/<sample>.third.filt.sorted.bam`, both relative to `resultDir`, which holds
    /// `esviritu.sqlite`. Each distinct recorded path is joined to `resultDir`, and an absolute path stays as it
    /// is, as the EsViritu viewer reads the column. The paths are handed on unchecked, since
    /// ``firstContainedBAM(among:within:sample:)`` gives every candidate the one containment check. The list is
    /// empty when there is no database or the database has no row with a `bam_path` for the sample.
    static func esVirituRecordedBAMCandidates(sampleId: String, resultDir: URL) -> [URL] {
        let databaseURL = resultDir.appendingPathComponent("esviritu.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path),
              let database = try? EsVirituDatabase(at: databaseURL),
              let rows = try? database.fetchRows(samples: [sampleId]) else { return [] }
        return joinedRecordedPaths(rows.compactMap(\.bamPath), resultDir: resultDir)
    }

    /// The BAM paths that the TaxTriage database of a result records for `sampleId`, as the first candidates of
    /// `locateBAMURL` (3.2 TTEXTRACT, finding F1 of TTACCESSIONS).
    ///
    /// The viewer sends the result's database as the result path, so `resultDir` is the folder that holds
    /// `taxtriage.sqlite`. A batch the app makes records `<sample>/minimap2/<sample>.<sample>.dwnld.references.bam`
    /// and a one-sample result records `minimap2/<sample>.<sample>.dwnld.references.bam`, both relative to
    /// `resultDir`, and the paths are handed on unchecked for ``firstContainedBAM(among:within:sample:)``. The list
    /// is empty when there is no readable database or no row of the sample records a BAM, and the `minimap2/` lookup
    /// beside the result then finds the BAM of an older layout.
    static func taxTriageRecordedBAMCandidates(sampleId: String, resultDir: URL) -> [URL] {
        let databaseURL = resultDir.appendingPathComponent("taxtriage.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path),
              let database = try? TaxTriageDatabase(at: databaseURL),
              let rows = try? database.fetchRows(samples: [sampleId]) else { return [] }
        return joinedRecordedPaths(rows.compactMap(\.bamPath), resultDir: resultDir)
    }

    /// Each distinct recorded path that is not empty, joined to `resultDir`, and an absolute path as it is.
    private static func joinedRecordedPaths(_ recorded: [String], resultDir: URL) -> [URL] {
        var tried = Set<String>()
        var candidates: [URL] = []
        for path in recorded where !path.isEmpty && tried.insert(path).inserted {
            candidates.append(path.hasPrefix("/") ? URL(fileURLWithPath: path) : resultDir.appendingPathComponent(path))
        }
        return candidates
    }

    // MARK: - One containment check for every candidate (decisions C4 and W4)

    /// What the containment check finds for one BAM candidate.
    enum BAMCandidateCheck: Equatable {
        /// An existing file whose physical path is inside the result root. The URL is that path.
        case inside(URL)
        /// An existing file whose physical path is outside the result root, such as a link that leaves it. It is
        /// never read, and the refusal says so.
        case outside
        /// No file. The path is missing, names a folder, or is a link whose target is missing.
        case absent
    }

    /// Checks one BAM candidate against `root`, the result folder.
    ///
    /// The path is standardized with its symlinks resolved, and `root` resolves the same way. A path that stays
    /// inside `root` and names an existing file is `.inside`, and the caller opens the resolved URL, so the path
    /// that was checked is the path that is read (SWIFT 6). A `..` step, an absolute path elsewhere and a symlink
    /// that leaves `root` all resolve to a file outside, and nothing there is read.
    static func checkedBAMCandidate(_ candidate: URL, within root: URL) -> BAMCandidateCheck {
        let resolved = CanonicalFilePath.url(for: candidate)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return .absent }
        return CanonicalFilePath.isPath(resolved, within: root) ? .inside(resolved) : .outside
    }

    /// The first candidate that passes ``checkedBAMCandidate(_:within:)`` as an inside file.
    ///
    /// A candidate that leaves the root is dropped, whichever layout found it, and the next one is tried. When no
    /// candidate is inside and at least one is a file outside, the refusal is `bamOutsideResult`, since the BAM
    /// exists and the user can fix it. Otherwise it is `bamNotFound`.
    static func firstContainedBAM(among candidates: [URL], within root: URL, sample: String) throws -> URL {
        var leavesRoot = false
        for candidate in candidates {
            switch checkedBAMCandidate(candidate, within: root) {
            case .inside(let url): return url
            case .outside: leavesRoot = true
            case .absent: continue
            }
        }
        if leavesRoot {
            logger.notice("A BAM candidate resolves outside the result root, so it is not read")
            throw ClassifierExtractionError.bamOutsideResult(sampleId: sample)
        }
        throw ClassifierExtractionError.bamNotFound(sampleId: sample)
    }

    /// The entries of `folder` as paths under `folder`, or an empty list when `folder` does not resolve to a folder
    /// inside `root`.
    ///
    /// A layout lookup lists a folder to find a BAM under another name. A link that leads out of `root` is never
    /// followed to list what lies there (SWIFT 6), so nothing outside the result is read. The folder is listed by its
    /// resolved path, since Foundation's listing by URL does not follow a link to a folder.
    static func listedFiles(in folder: URL, within root: URL) -> [URL] {
        let resolved = CanonicalFilePath.url(for: folder)
        guard CanonicalFilePath.isPath(resolved, within: root),
              let names = try? FileManager.default.contentsOfDirectory(atPath: resolved.path) else { return [] }
        return names.map { folder.appendingPathComponent($0) }
    }
}
