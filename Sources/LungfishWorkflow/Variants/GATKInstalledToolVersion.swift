// GATKInstalledToolVersion.swift - The version of the GATK that is really installed
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Asks the managed gatk-core environment which GATK it runs.
///
/// The plugin pack's lock file pins a version, but a provenance sidecar
/// should name the binary that executed. `gatk --version` prints
/// `The Genome Analysis Toolkit (GATK) v4.6.2.0`; the numeric version is
/// extracted from that line.
public enum GATKInstalledToolVersion {
    public static let executable = "gatk"
    public static let environment = "gatk-core"

    /// The installed version, or `nil` when GATK is not installed or does
    /// not answer within `timeout`.
    public static func probe(
        condaManager: CondaManager = .shared,
        timeout: TimeInterval = 60
    ) async -> String? {
        do {
            let version = try await detectToolVersion(
                toolName: executable,
                environment: environment,
                condaManager: condaManager,
                flags: ["--version"],
                timeout: timeout
            )
            return normalized(version)
        } catch {
            return nil
        }
    }

    /// The version `detectToolVersion` extracted, or `nil` for its
    /// "unknown" sentinel or an empty answer.
    public static func normalized(_ version: String) -> String? {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "unknown" else { return nil }
        return trimmed
    }
}
