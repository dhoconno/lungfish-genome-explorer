// BuildDbCommand+Core.swift - What a build-db core takes and returns
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

// The `build-db kraken2` and `build-db esviritu` bodies are cores that a caller in process can run, such as
// the analysis run executor's index step (plan decision E6 of Phase 2.7). Each is a static
// `buildDatabase(in:options:events:)` on its leaf, in `BuildDbCommand+Kraken2Core.swift` and
// `BuildDbCommand+EsVirituCore.swift`. It takes the result folder, these options and a
// `BuildDbEventSink`, builds the database, runs the cleanup, writes the records and returns what it built.
// The commands wrap them in `BuildDbCLIEvents.report`. `build-db taxtriage` keeps an instance body, because
// its report parsers are instance methods, and its core waits for TaxTriage on the executor in 2.8.

/// The options of one `build-db` run, as a command parses them. `globalOptions` goes into the record's
/// command line and options, so an in-process caller passes the options it wants the record to name.
struct BuildDbRunOptions {
    /// Rebuild a database that already exists.
    var force = false
    /// Keep the intermediate files that the cleanup removes or compacts.
    var noCleanup = false
    /// `build-db kraken2` only, the sample folders to read in place of every folder in the result folder.
    var sampleDirectories: [URL] = []
    var globalOptions: GlobalOptions
}

/// What one `build-db` run left in its result folder.
struct BuildDbRunResult: Sendable {
    /// The database file at the root of the result folder, such as `kraken2.sqlite`.
    let databaseURL: URL
    /// The rows the run wrote, or nil when it found the database there and built nothing.
    let rowCount: Int?
    /// The record the run wrote beside the database, or nil when it built nothing. Its steps are the
    /// samtools passes, the BAM relocation of `build-db esviritu` and the database build.
    let record: ProvenanceEnvelope?

    /// The last sentence a run prints about the database, which its `complete` line also carries.
    var summary: String {
        guard let rowCount else {
            return "Database already exists at \(databaseURL.path). Use --force to rebuild."
        }
        return "Built database at \(databaseURL.path) with \(rowCount) rows"
    }
}
