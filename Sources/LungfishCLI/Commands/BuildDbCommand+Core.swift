// BuildDbCommand+Core.swift - What a build-db core takes and returns
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

// The `build-db kraken2`, `build-db esviritu` and `build-db taxtriage` bodies are cores that a caller in
// process can run, such as the analysis run executor's index step (plan decision E6 of Phase 2.7). Each is a
// static `buildDatabase(in:options:...)` on its leaf, in `BuildDbCommand+Kraken2Core.swift`,
// `BuildDbCommand+EsVirituCore.swift` and `BuildDbCommand+TaxTriageCore.swift`. It takes the result folder,
// these options and a `BuildDbEventSink`, builds the database, runs the cleanup, writes the records and
// returns what it built. The commands wrap them in `BuildDbCLIEvents.report`. The TaxTriage core also takes
// the form of its cleanup (decision T5 of Phase 2.8). The command keeps today's, which removes `top/` before
// the record, and TaxTriage on the executor (lane A2 of Phase 2.9) runs the one that keeps `top/`, comes
// after the record and returns a removal step.
//
// A core stops when the task that runs it is cancelled. Only the executor's index step cancels one today,
// under a cancelled `kraken2 classify` or `esviritu detect`, since a standalone `build-db` ends by the
// signal. A core checks before each sample folder it reads or cleans up, before it writes the database,
// before the EsViritu BAM move, after the samtools pass and before it writes the record, and throws
// `CancellationError` at the first check after the cancel. It then puts back the database of an earlier
// build and writes no record of a failed build (plan decision E5 of Phase 2.7). A step that finished before
// the cancel stays done and no record names it, such as a folder the cleanup compacted, a BAM the build
// moved or a `_temp` folder the cleanup removed. A cancel after the check before the record finds the build
// complete. `BuildDbCancellationTests` pins the checks, and the TaxTriage core follows the same pattern.

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
    /// Write the result folder's own record, `.lungfish-provenance.json`, when no other workflow's record is
    /// there, as the commands do. The analysis run executor's index step, an `AnalysisResultIndexing`
    /// builder that runs in phase P3, passes false, because the executor writes the root record itself in
    /// phase P4, after every other record of the run, and a record the index step wrote at the root would
    /// name the wrong workflow until then (risk R8). Each output's sidecar is still written, and the run's
    /// record is still returned.
    var writesFolderRecord = true
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
