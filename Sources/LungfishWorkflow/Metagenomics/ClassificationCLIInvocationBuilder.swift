// ClassificationCLIInvocationBuilder.swift — One argv builder for `lungfish kraken2 classify`.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Builds the `lungfish kraken2 classify` argv for a ``ClassificationConfig``,
/// used both to execute a classification
/// and to display/record it.
///
/// Since Phase 2.7 (decision E11) the argv names `kraken2 classify`, the command that runs
/// ``Kraken2AnalysisRunTool``, so the command the Operations panel records is the command whose
/// root record names it. `conda classify` stays registered, so a command recorded before still
/// replays. A configuration whose database digest is a SHA-256 adds `--db-digest`, so a replay
/// refuses a database whose install receipt holds another digest (E9).
///
/// Before this type existed, the single-sample GUI path
/// (`AppDelegate+Classification.runClassification`) built its own,
/// unrelated, broken display string: `--db <databasePath.path>` (the CLI's
/// `--db` is resolved by `MetagenomicsDatabaseRegistry.database(named:)`
/// against the registry *name*, not a filesystem path — passing a path fails
/// with "Database ... not found in registry"), and it omitted `--preset`,
/// `--confidence`, `--min-hit-groups`, `--paired`, `--profile` and
/// `--output-dir` entirely, so even a corrected `--db` would reproduce a
/// different analysis. The batch path's
/// `classificationBatchReplayCommand` already built the argv correctly; this
/// type is that same field mapping, extracted so the single-sample path can
/// share it instead of hand-rolling a second, divergent encoding.
public enum ClassificationCLIInvocationBuilder {
    /// Builds the full `lungfish kraken2 classify` invocation for one sample.
    /// Explicit `--confidence`/`--min-hit-groups` reproduce `config`'s exact
    /// values regardless of which preset (or manual override) originally
    /// produced them — no `--preset` flag is needed since these two options
    /// fully determine Kraken2's sensitivity behavior, matching the batch
    /// replay path this builder replaces.
    public static func build(for config: ClassificationConfig) -> CLIInvocation {
        var arguments = ["kraken2", "classify"]
        arguments += ["--db", config.databaseName]
        if let digest = Kraken2DatabaseReceipt.normalizedSHA256(config.databaseDigest) {
            arguments += ["--db-digest", digest]
        }
        arguments += ["--output-dir", config.outputDirectory.path]
        arguments += ["--confidence", String(config.confidence)]
        arguments += ["--min-hit-groups", String(config.minimumHitGroups)]
        arguments += ["--threads", String(config.threads)]

        // The read format is always pinned so a pasted command reproduces
        // the run instead of re-detecting the layout (parity with
        // `lungfish esviritu detect --read-format`).
        // A bundle whose read set the CLI plans is recorded with `auto`, so
        // `conda classify` pairs it itself (docs/contracts/READ-PAIRING.md).
        // Loose files of single reads follow the pair as `--unpaired`.
        if config.plansReadSet {
            arguments += ["--read-format", "auto"]
        } else {
            switch config.readFormat {
            case .paired:
                arguments.append("--paired")
            case .interleaved, .unpaired:
                arguments += ["--read-format", config.readFormat.rawValue]
            }
            for file in config.singleReadFiles {
                arguments += ["--unpaired", file.path]
            }
        }
        if config.memoryMapping {
            arguments.append("--memory-mapping")
        }
        if config.quickMode {
            arguments.append("--quick")
        }
        if !config.extraArguments.isEmpty {
            arguments += ["--extra-args", AdvancedCommandLineOptions.join(config.extraArguments)]
        }
        if config.goal == .profile {
            let request = config.brackenProfileRequest ?? .automaticDefault
            arguments.append("--profile")
            arguments += ["--bracken-read-length", String(request.readLength)]
            arguments += ["--bracken-threshold", String(request.threshold)]
            if case .explicit(let rank) = request.rank {
                arguments += ["--bracken-level", rank.code]
            }
        }

        arguments += (config.originalInputFiles ?? config.inputFiles).map(\.path)
        return CLIInvocation(arguments: arguments)
    }
}
