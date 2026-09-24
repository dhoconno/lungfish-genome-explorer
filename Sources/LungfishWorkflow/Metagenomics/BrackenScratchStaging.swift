// BrackenScratchStaging.swift - Whitespace-free staging for the Bracken launcher
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Stages a Bracken run in a whitespace-free scratch directory.
///
/// The conda `bracken` launcher is a bash script that expands its paths
/// unquoted (`if [ -f ${INPUT} ]`, `-o ${OUTPUT}`, `$DATABASE/...`), so a
/// report inside a project folder with a space in its name fails with
/// "Input file ... does not exist" no matter how carefully the argv is
/// built. Rather than patch the third-party script, the report is copied
/// into a scratch directory under the system temp dir, the outputs are
/// written there, and the results are moved back afterwards. A database
/// or distribution path with whitespace is reached through a symlink in
/// the same scratch directory.
struct BrackenScratchStaging: Sendable {
    /// The scratch directory this staging owns and removes on `cleanUp()`.
    let scratchDirectory: URL
    /// The Kraken report as produced by the run.
    let sourceReportURL: URL
    /// The copy Bracken reads.
    let stagedReportURL: URL
    /// Where Bracken writes its abundance table.
    let stagedOutputURL: URL
    /// Where Bracken writes its re-estimated Kraken-style report.
    let stagedReportOutputURL: URL
    /// The modelled output paths the results move back to.
    let finalOutputURL: URL
    let finalReportOutputURL: URL
    /// The database directory Bracken is given: the real one, or a symlink
    /// in the scratch directory when the real path carries whitespace.
    let sourceDatabasePath: URL
    let stagedDatabasePath: URL
    /// The kmer distribution file, resolved the same way as the database.
    let sourceDistributionURL: URL
    let stagedDistributionURL: URL

    /// `FileManager.temporaryDirectory` unless its path has whitespace, in
    /// which case `/tmp`.
    static func defaultScratchRoot() -> URL {
        let temporary = FileManager.default.temporaryDirectory
        if Self.hasWhitespace(temporary.path) {
            return URL(fileURLWithPath: "/tmp", isDirectory: true)
        }
        return temporary
    }

    static func hasWhitespace(_ path: String) -> Bool {
        path.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    /// Lays out the scratch paths without touching the filesystem.
    static func plan(
        config: ClassificationConfig,
        distributionURL: URL,
        scratchRoot: URL = defaultScratchRoot()
    ) -> BrackenScratchStaging {
        let scratch = scratchRoot.appendingPathComponent(
            "lungfish-bracken-\(UUID().uuidString)",
            isDirectory: true
        )
        let databasePath = config.databasePath.standardizedFileURL
        let stagedDatabase = hasWhitespace(databasePath.path)
            ? scratch.appendingPathComponent("db", isDirectory: true)
            : databasePath
        let stagedDistribution: URL
        if stagedDatabase != databasePath,
           distributionURL.standardizedFileURL.deletingLastPathComponent().path == databasePath.path {
            // The distribution sits inside the database, so the symlink covers it.
            stagedDistribution = stagedDatabase.appendingPathComponent(distributionURL.lastPathComponent)
        } else if hasWhitespace(distributionURL.path) {
            stagedDistribution = scratch.appendingPathComponent(distributionURL.lastPathComponent)
        } else {
            stagedDistribution = distributionURL
        }
        return BrackenScratchStaging(
            scratchDirectory: scratch,
            sourceReportURL: config.reportURL,
            stagedReportURL: scratch.appendingPathComponent(config.reportURL.lastPathComponent),
            stagedOutputURL: scratch.appendingPathComponent(config.brackenURL.lastPathComponent),
            stagedReportOutputURL: scratch.appendingPathComponent(config.brackenReportURL.lastPathComponent),
            finalOutputURL: config.brackenURL,
            finalReportOutputURL: config.brackenReportURL,
            sourceDatabasePath: databasePath,
            stagedDatabasePath: stagedDatabase,
            sourceDistributionURL: distributionURL,
            stagedDistributionURL: stagedDistribution
        )
    }

    /// Every path Bracken will be handed, for a whitespace check.
    var stagedPaths: [URL] {
        [stagedReportURL, stagedOutputURL, stagedReportOutputURL, stagedDatabasePath, stagedDistributionURL]
    }

    /// Creates the scratch directory, copies the report in, and links the
    /// database or distribution when their real paths carry whitespace.
    func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        try fm.copyItem(at: sourceReportURL, to: stagedReportURL)
        if stagedDatabasePath != sourceDatabasePath {
            try fm.createSymbolicLink(at: stagedDatabasePath, withDestinationURL: sourceDatabasePath)
        }
        if stagedDistributionURL != sourceDistributionURL,
           stagedDistributionURL.deletingLastPathComponent().path == scratchDirectory.path {
            try fm.createSymbolicLink(at: stagedDistributionURL, withDestinationURL: sourceDistributionURL)
        }
    }

    /// Moves whichever outputs Bracken wrote back to their modelled paths,
    /// replacing stale files. Missing outputs are left for the caller's
    /// existing validation to report.
    func collectOutputs() throws {
        let fm = FileManager.default
        for (staged, final) in [(stagedOutputURL, finalOutputURL), (stagedReportOutputURL, finalReportOutputURL)]
        where fm.fileExists(atPath: staged.path) {
            if fm.fileExists(atPath: final.path) {
                try fm.removeItem(at: final)
            }
            try fm.moveItem(at: staged, to: final)
        }
    }

    /// Removes the scratch directory. Safe to call whether or not `prepare()` ran.
    func cleanUp() {
        try? FileManager.default.removeItem(at: scratchDirectory)
    }
}
