// RunSubcommand+ViralReconRecord.swift - The facts of a Viral Recon run's record on the one Nextflow record shape
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow

extension RunSubcommand {
    /// The Nextflow facts of a Viral Recon step on the record shape of 2.9 R1 (Phase 2.10 lane B31).
    ///
    /// The step's tool is the lock's pipeline id, `nf-core-viralrecon`, at the revision `-r` takes, with the release tag
    /// that names that revision beside it (``NFCoreRunRequest/viralReconReleaseVersion(pin:)``). `workflow run` always
    /// launches the repository with `-r`, never a snapshot, so the code came from `remote`. LGE's own command stays the
    /// argv of the run.
    static func viralReconStepFacts(for request: NFCoreRunRequest) -> NextflowRecordFacts {
        NextflowRecordFacts(
            toolName: NextflowWorkflowDescriptor.viralRecon.lockPipelineID,
            toolVersion: request.version,
            githubReleaseVersion: request.viralReconReleaseVersion(
                pin: try? NextflowWorkflowDescriptor.viralRecon.resolveBundledPin()),
            pipelineSource: .remote
        )
    }

    /// The run's options, split by 2.7 E12 into what the caller chose and what the command applied unasked.
    ///
    /// A pipeline parameter is explicit when the caller passed it with the value that ran, and `input` and `outdir`
    /// come from `--input` and `--results-dir`. A parameter LGE adds or overrides, such as the `skip_freyja` and
    /// `skip_freyja_boot` that no Apple Silicon run can do without, is a resolved default with the value that ran. The
    /// profile `-profile` passes is explicit beside the executor that names it. The release tag is explicit when
    /// `--version` named the revision and a resolved default when the lock's pin did, and `resume` and `prepareOnly` are
    /// explicit only when their flags were given.
    func viralReconRunOptions(
        request: NFCoreRunRequest,
        prepareOnly: Bool,
        releaseVersion: String?
    ) -> (explicit: [String: ParameterValue], resolvedDefaults: [String: ParameterValue]) {
        var explicit: [String: ParameterValue] = [:]
        var resolved: [String: ParameterValue] = [:]
        for (key, value) in request.effectiveParams {
            if key == "input" || key == "outdir" || request.params[key] == value {
                explicit[key] = .string(value)
            } else {
                resolved[key] = .string(value)
            }
        }
        explicit["executor"] = .string(request.executor.rawValue)
        explicit["profile"] = .string(request.executor.rawValue)
        if let releaseVersion {
            if version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                resolved["github_release_version"] = .string(releaseVersion)
            } else {
                explicit["github_release_version"] = .string(releaseVersion)
            }
        }
        for (key, given) in [("resume", request.resume), ("prepareOnly", prepareOnly)] {
            if given { explicit[key] = .boolean(true) } else { resolved[key] = .boolean(false) }
        }
        return (explicit, resolved)
    }
}
