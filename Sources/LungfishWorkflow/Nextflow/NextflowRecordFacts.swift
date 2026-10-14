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
/// (``TaxTriageRecordFacts/nextflowFacts(revision:pin:pipelineSource:)``).
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
    /// Two lines name it. Nextflow starts its output with the banner `N E X T F L O W  ~  version 25.04.6`, and 26.04
    /// prints it the same way (line 1 of Q35's V3 run A). A Nextflow that finds `CLAUDECODE` or `NXF_AGENT_MODE` in its
    /// environment prints an agent log with no banner and no `Launching` line instead (V3-BIO 4), which is why LGE's
    /// launch removes both (``WorkflowEngineLaunch``). The line `Nextflow version: 26.04.6` is the one TaxTriage's
    /// workflow prints from `workflow.nextflow.version`, the engine that ran (`workflows/taxtriage.nf:537` at v3.3.8),
    /// so a log from an engine run in agent mode names it only when the workflow's own code prints that line. A
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

    /// The step's resolved options for a writer that found the Nextflow version itself (Phase 2.10 N3),
    /// `pipelineSource` and, when it is known, `nextflowVersion`.
    package func resolvedOptions(nextflowVersion: String?) -> [String: ParameterValue] {
        var options: [String: ParameterValue] = ["pipelineSource": .string(pipelineSource.rawValue)]
        if let nextflowVersion {
            options["nextflowVersion"] = .string(nextflowVersion)
        }
        return options
    }

    /// The version of the Nextflow that ran, from its own debug log `.nextflow.log` in the launch folder, or nil (N3).
    ///
    /// Nextflow 26.04.6 logs `<date> <time> [main] INFO  nextflow.cli.CmdRun - N E X T F L O W  ~  version 26.04.6` as the
    /// second line of that log (Q35's real run V1, `warm-meta/nextflow.log`). Only that logger's line counts, so the
    /// argv the launcher logs on the first line never stands in for it.
    package static func nextflowVersion(inDebugLog text: String) -> String? {
        firstCapture(
            #"(?m)^[A-Z][a-z]{2}-[0-9]{2} [0-9:.]+ \[main\] INFO +nextflow\.cli\.CmdRun - N E X T F L O W[ \t]+~[ \t]+version[ \t]+([0-9][0-9A-Za-z.\-]*)"#,
            in: text)
    }

    /// The version `nextflow -version` printed, or nil (N3). Nextflow 26.04.6 prints `version 26.04.6 build 12646` as a
    /// line of its banner, and the one-line form `nextflow version 26.04.6.12646` that `-v` prints ends with the build.
    package static func nextflowVersion(inVersionOutput text: String) -> String? {
        firstCapture(#"(?m)^[ \t]*version[ \t]+([0-9][0-9A-Za-z.\-]*)[ \t]+build[ \t]+[0-9]+"#, in: text)
            ?? firstCapture(#"(?m)^nextflow version ([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+)?)\.[0-9]+[ \t]*$"#, in: text)
    }

    /// The commit Nextflow resolved, as the first `Launching` line of `text` names it, or nil (2.9 R2). Nextflow 26.04.6
    /// names its first ten characters, as in `Launching `https://github.com/nf-core/viralrecon` [fervent_ochoa] -
    /// revision: 395079f1d2 [3.0.0]`, after the logger's name in its debug log and at the start of a console line.
    package static func launchedCommit(inLog text: String) -> String? {
        firstCapture(#"(?m)(?:^|nextflow\.cli\.CmdRun - )Launching `[^`]+` \[[^\]]+\] - revision: ([0-9a-f]{7,40})\b"#, in: text)
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[range])
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
