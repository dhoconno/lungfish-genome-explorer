// EsVirituCLIInvocationBuilder.swift - The arguments of the recorded `esviritu detect` command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Builds the `lungfish-cli esviritu detect` arguments that the app records for an EsViritu run,
/// so the legacy route, the CLI route and the executor name one argv for one configuration.
public enum EsVirituCLIInvocationBuilder {
    /// Arguments after `lungfish esviritu detect` recorded for a single-sample run.
    ///
    /// The command names every setting the run uses, so a pasted command runs
    /// the same detection (R3). The inputs are recorded as the wizard chose
    /// them, and `esviritu detect` resolves a `.lungfishfastq` bundle as the
    /// run does. The read format the wizard chose is recorded explicitly so
    /// the copied command runs pairs as pairs and mixed input as single-end.
    /// An input the read-set planner decides (`plansReadSet`: separate R1 and
    /// R2 files, a mix of pairs and single reads, or several files of single
    /// reads) records `--read-format auto`, so the CLI plans the bundle and
    /// runs the same files. The database, output folder, thread count, quality
    /// filter and extra arguments follow, so the CLI never falls back to
    /// defaults of its own.
    nonisolated static func esVirituDetectCLIArguments(for config: EsVirituConfig) -> [String] {
        var args = ["--input"] + config.inputFiles.map(\.path)
        args += ["--sample", config.sampleName]
        args += ["--read-format", config.plansReadSet ? "auto" : config.readFormat.rawValue]
        args += ["--db", config.databasePath.path]
        args += ["--output", config.outputDirectory.path]
        args += ["--threads", String(config.threads)]
        if !config.qualityFilter {
            args.append("--no-qc")
        }
        if !config.extraArguments.isEmpty {
            args += ["--extra-args", AdvancedCommandLineOptions.join(config.extraArguments)]
        }
        return args
    }

    /// Arguments after `lungfish-cli esviritu detect` the batch provenance
    /// records for a batch run.
    ///
    /// Every sample's inputs follow one `--input`, and `--sample` names the
    /// first sample. No command runs a batch, so the batch row records none
    /// (`cli-parity-gap` `esviritu-batch` on ``beginEsVirituBatchOperation(configs:routeContext:reporter:launch:)``).
    /// Only the batch provenance still starts from this list.
    nonisolated static func esVirituBatchCLIArguments(for configs: [EsVirituConfig]) -> [String] {
        var args = ["--input"]
        for config in configs {
            args += config.inputFiles.map(\.path)
        }
        args += ["--sample", configs.first?.sampleName ?? "batch"]
        return args
    }
}
