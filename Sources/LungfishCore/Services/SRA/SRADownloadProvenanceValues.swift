// SRADownloadProvenanceValues.swift - The values an SRA download's provenance records, shared by the window and the CLI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The strategy names an SRA download records under `requestedStrategy` and
/// `selectedStrategy`.
///
/// `lungfish-cli fetch sra download` and the window's SRA import both take
/// their names from here, so the same run records the same names whichever
/// surface downloaded it.
public enum SRADownloadStrategy {
    /// What the user asked for. `toolkitOnly` is `fetch sra download
    /// --use-toolkit`, which the window does not offer.
    public static func requested(preference: SRADownloadSourcePreference, toolkitOnly: Bool = false) -> String {
        if toolkitOnly {
            return "sra-toolkit"
        }
        return preference == .ncbi ? "sra-toolkit-first" : "ena-direct"
    }

    /// The route that served the run, given where its files came from. Nil
    /// `source` is the preferred archive's own route.
    public static func selected(
        preference: SRADownloadSourcePreference,
        toolkitOnly: Bool = false,
        source: SRAFASTQDownloadSource?
    ) -> String {
        if toolkitOnly {
            return "sra-toolkit"
        }
        switch preference {
        case .ena:
            return source == nil || source == .ena ? "ena-direct" : "sra-toolkit-fallback"
        case .ncbi:
            return source == nil || source == .sraToolkit ? "sra-toolkit" : "ena-fallback"
        }
    }
}

public extension SRAFASTQDownloadSource {
    /// What the run's provenance records under `condaEnvironment`. The SRA
    /// Toolkit runs in the managed sra-tools environment, and ENA's mirror
    /// needs none.
    var recordedCondaEnvironment: String {
        usesSRAToolkit ? "managed sra-tools" : "none"
    }
}

public extension SRAService.FASTQDownloadStepTrace {
    /// The tool version a provenance step records for this trace. An SRA
    /// Toolkit step records "sra-tools" and the version the managed tool
    /// lock pins, such as "sra-tools 3.4.1", when `sraToolsVersion` names
    /// one. Any other step records its own version.
    func recordedToolVersion(sraToolsVersion: String?) -> String {
        guard toolVersion == "sra-tools", let sraToolsVersion, !sraToolsVersion.isEmpty else {
            return toolVersion
        }
        return "sra-tools \(sraToolsVersion)"
    }

    /// The `resolvedOptions` entry of a provenance step whose trace belongs
    /// to an attempt that did not serve the run. Such a step stays recorded,
    /// and no later step depends on it.
    static let failedAttemptOption = (key: "attempt", value: "failed")
}
