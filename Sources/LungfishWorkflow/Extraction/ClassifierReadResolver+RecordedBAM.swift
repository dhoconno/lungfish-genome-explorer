// ClassifierReadResolver+RecordedBAM.swift - The BAM a classifier database row records, read only from inside the result root
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: "com.lungfish.workflow", category: "ClassifierReadResolver")

extension ClassifierReadResolver {
    // MARK: - Recorded BAM (decision C4)

    /// The BAM that the EsViritu database of a result records for `sampleId`, as the first candidate of
    /// `resolveBAMURL`.
    ///
    /// A one-folder result records `bams/<sample>.third.filt.sorted.bam` and a batch result records
    /// `<sample>/bams/<sample>.third.filt.sorted.bam`, both relative to `resultDir`, which holds
    /// `esviritu.sqlite`. The list is empty when there is no database, the database has no row with a
    /// `bam_path` for the sample, or no recorded path passes ``recordedBAMURL(_:within:)``.
    static func esVirituRecordedBAMCandidates(sampleId: String, resultDir: URL) -> [URL] {
        let databaseURL = resultDir.appendingPathComponent("esviritu.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path),
              let database = try? EsVirituDatabase(at: databaseURL),
              let rows = try? database.fetchRows(samples: [sampleId]) else { return [] }
        var tried = Set<String>()
        for recorded in rows.compactMap(\.bamPath) where !recorded.isEmpty {
            guard tried.insert(recorded).inserted else { continue }
            if let url = recordedBAMURL(recorded, within: resultDir) { return [url] }
            logger.info("An EsViritu bam_path names no file inside the result root, trying the layout lookups")
        }
        return []
    }

    /// The file that `recorded`, a path read from a database row, names inside `root`, or nil.
    ///
    /// A relative path is joined to `root`, and an absolute path stays as it is, as the EsViritu viewer reads
    /// the column. The path is standardized with its symlinks resolved. It is used only when the resolved path
    /// stays inside `root`, whose own symlinks resolve the same way, and names an existing file. A `..` step, an
    /// absolute path elsewhere and a symlink that leaves `root` all give nil, so the caller falls back to its
    /// layout lookups. The caller opens the resolved URL, so the path that was checked is the path that is read.
    static func recordedBAMURL(_ recorded: String, within root: URL) -> URL? {
        let joined = recorded.hasPrefix("/")
            ? URL(fileURLWithPath: recorded)
            : root.appendingPathComponent(recorded)
        let resolved = CanonicalFilePath.url(for: joined)
        var isDirectory: ObjCBool = false
        guard let relative = CanonicalFilePath.relativePath(of: resolved, within: root), !relative.isEmpty,
              FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return resolved
    }
}
