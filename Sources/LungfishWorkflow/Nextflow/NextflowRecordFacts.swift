// NextflowRecordFacts.swift - The engine and pipeline facts of one Nextflow step, one shape for every workflow
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The engine and pipeline facts of one Nextflow step, one shape for every workflow (Phase 2.9 lane B11, decision R1).
///
/// - The step's tool is the pipeline id and its version the revision that ran, the lock's pinned revision unless the
///   run named another, with the release tag that names the revision beside it as `githubReleaseVersion`.
/// - The step's resolved options hold where the launched code came from as `pipelineSource`, `remote` or `snapshot`,
///   which LGE never patches (decision T6), and the version of the Nextflow that ran as `nextflowVersion`, read from
///   the run's own log (``nextflowVersion(inLog:)``) and left out when the log names no version.
///
/// TaxTriage is the first workflow whose step records this shape
/// (``TaxTriageRecordFacts/nextflowFacts(revision:pipelineSource:)``).
package struct NextflowRecordFacts: Sendable, Equatable {
    /// The step's tool, the pipeline id, such as `taxtriage`.
    package let toolName: String
    /// The step's tool version, the revision of the pipeline that ran, a commit or a tag as the lock or the run named it.
    package let toolVersion: String
    /// The release tag that names the revision, nil when no tag names it.
    package let githubReleaseVersion: String?
    /// Where the launched code came from, the repository Nextflow resolved or LGE's snapshot of the revision.
    package let pipelineSource: NextflowPipelineSource

    package init(
        toolName: String,
        toolVersion: String,
        githubReleaseVersion: String?,
        pipelineSource: NextflowPipelineSource
    ) {
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.githubReleaseVersion = githubReleaseVersion
        self.pipelineSource = pipelineSource
    }

    /// The facts of a step that ran the lock's pin, the pipeline id at the pinned revision with the pin's release tag,
    /// nil when the lock names none. Only a route that resolved the pin uses it. A route that runs a revision a caller
    /// set records that revision instead, so a record never names a revision that did not run.
    package init(pin: NextflowPipelinePin, pipelineSource: NextflowPipelineSource) {
        self.init(
            toolName: pin.pipelineID,
            toolVersion: pin.revision,
            githubReleaseVersion: pin.releaseVersion.isEmpty ? nil : pin.releaseVersion,
            pipelineSource: pipelineSource
        )
    }

    /// The step's resolved options, `pipelineSource` and the version of the Nextflow that ran as `nextflowVersion`,
    /// read from `logFile`. The version is left out when there is no log, when it cannot be read as UTF-8 and when it
    /// names no version.
    package func resolvedOptions(logFile: URL?) -> [String: ParameterValue] {
        var options: [String: ParameterValue] = ["pipelineSource": .string(pipelineSource.rawValue)]
        if let logFile,
           let text = try? String(contentsOf: logFile, encoding: .utf8),
           let version = Self.nextflowVersion(inLog: text) {
            options["nextflowVersion"] = .string(version)
        }
        return options
    }

    /// The version of the Nextflow that ran, from the first line of `text` that names it, or nil.
    ///
    /// Two lines name it. Nextflow 25.04 starts its output with the banner `N E X T F L O W  ~  version 25.04.6`.
    /// Nextflow 26.04 prints no version on its standard output, and the line `Nextflow version: 26.04.6` is the one
    /// TaxTriage's workflow prints from `workflow.nextflow.version`, the engine that ran (`workflows/taxtriage.nf:537`
    /// at v3.3.8), so under Nextflow 26 a workflow's log names the engine only when its own code prints that line. A
    /// line counts only when it starts with one of the two, so a path or an argument in the preamble LGE writes at the
    /// top of the log never stands in for it.
    package static func nextflowVersion(inLog text: String) -> String? {
        guard let line = text.range(
            of: #"(?m)^[ \t]*(N E X T F L O W[ \t]+~[ \t]+version|Nextflow version:)[ \t]+[0-9][0-9A-Za-z.\-]*"#,
            options: .regularExpression
        ) else {
            return nil
        }
        return text[line].split(whereSeparator: \.isWhitespace).last.map(String.init)
    }
}

/// Where the code a Nextflow step launched came from (decision T6 (c)). LGE patches neither, so both hold the code of
/// the revision the step names.
package enum NextflowPipelineSource: String, Sendable, Equatable {
    /// The pipeline's repository, which `nextflow run` resolved at the revision passed with `-r`.
    case remote
    /// LGE's snapshot of the revision, exported from Nextflow's cached checkout, which `nextflow run` started without
    /// `-r`.
    case snapshot
}
