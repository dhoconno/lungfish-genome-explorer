// BlastVerificationArchive+SavedSearches.swift - The newest saved `blast submit` record a viewer asks for
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension BlastVerificationArchive {
    /// The newest readable `blast submit` record under `<directory>/blast-verifications/` that `matches` accepts, with
    /// the file it was read from, which the BLAST pane's table export reads. The search that completed last wins, as the
    /// archive orders its own files. A folder with no readable record, which a timed-out run leaves, is skipped.
    ///
    /// It reads every record, so it never runs on the main actor. A cancelled task stops reading and gets nothing.
    public static func newestSubmission(
        in directory: URL,
        matching matches: (BlastSubmissionRecord, URL) -> Bool
    ) -> (record: BlastSubmissionRecord, url: URL)? {
        let folder = directoryURL(for: directory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var newest: (record: BlastSubmissionRecord, url: URL)?
        for name in names {
            if Task.isCancelled { return nil }
            let url = folder.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent(BlastSubmissionRecord.recordFileName)
            guard let record = try? BlastSubmissionRecord.load(url), matches(record, url) else { continue }
            if let current = newest, completion(of: current.record) >= completion(of: record) { continue }
            newest = (record, url)
        }
        return newest
    }

    /// The project that holds `resultURL`, whose `blast-verifications` folder takes the result's searches.
    public static func savedSearchProject(ofResult resultURL: URL) -> URL? {
        ProjectTempDirectory.findProjectRoot(resultURL)
    }

    private static func completion(of record: BlastSubmissionRecord) -> Date {
        record.result.completedAt ?? record.savedAt
    }
}
