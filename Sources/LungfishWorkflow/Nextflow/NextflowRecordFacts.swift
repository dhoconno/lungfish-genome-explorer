// NextflowRecordFacts.swift - The engine and pipeline facts of one Nextflow step, one shape for every workflow
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The engine and pipeline facts of one Nextflow step, one shape for every workflow (Phase 2.9 lane B11, decision R1).
///
/// - The step's tool is the pipeline id and its version the commit that ran, with the release tag that names the
///   commit beside it as `githubReleaseVersion`.
/// - The step's resolved options hold the version of the Nextflow that ran as `nextflowVersion`, read from the banner
///   the engine printed into the run's own log, and nothing when no log holds a banner.
///
/// TaxTriage is the first workflow whose step records this shape (``TaxTriageRecordFacts/nextflowFacts(revision:)``).
package struct NextflowRecordFacts: Sendable, Equatable {
    /// The step's tool, the pipeline id, such as `taxtriage`.
    package let toolName: String
    /// The step's tool version, the commit of the pipeline that ran.
    package let toolVersion: String
    /// The release tag that names the commit, nil when no tag names it.
    package let githubReleaseVersion: String?

    package init(toolName: String, toolVersion: String, githubReleaseVersion: String?) {
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.githubReleaseVersion = githubReleaseVersion
    }

    /// The step's resolved options, the version of the Nextflow that ran as `nextflowVersion`, read from the banner in
    /// `logFile`. Empty when there is no log, when it cannot be read as UTF-8 and when it holds no banner.
    package func resolvedOptions(logFile: URL?) -> [String: ParameterValue] {
        guard let logFile,
              let text = try? String(contentsOf: logFile, encoding: .utf8),
              let version = Self.nextflowVersion(inLog: text) else {
            return [:]
        }
        return ["nextflowVersion": .string(version)]
    }

    /// The version in the first banner line Nextflow printed into `text`, `N E X T F L O W  ~  version 25.04.6`, or nil.
    package static func nextflowVersion(inLog text: String) -> String? {
        guard let banner = text.range(
            of: #"N E X T F L O W\s+~\s+version\s+[0-9][0-9A-Za-z.\-]*"#,
            options: .regularExpression
        ) else {
            return nil
        }
        return text[banner].split(whereSeparator: \.isWhitespace).last.map(String.init)
    }
}
