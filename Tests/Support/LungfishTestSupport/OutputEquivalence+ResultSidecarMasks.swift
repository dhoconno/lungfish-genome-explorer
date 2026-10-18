// OutputEquivalence+ResultSidecarMasks.swift - The run clocks of three result sidecars
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// OutputEquivalence+Masks.swift is over the size baseline and may not grow, so a mask added after it lives here, in
// an extension of the same enum. The mask is one reviewed entry of the Masks row of docs/contracts/CLI-EQUIVALENCE.md
// (ruling 1 of the review of lane 12.06 M1). It replaces the clock masks that the parity classes of the classifier
// result imports and of the CZ-ID import each kept for themselves.

import Foundation

extension OutputEquivalence.Masks {
    /// The run clocks of three result sidecars, each set to a placeholder where the document is one of them.
    ///
    /// - A classification result (`classification-result.json`): the top-level `runtime`, the seconds the pipeline
    ///   or conversion ran, becomes `<DURATION>`, and `savedAt`, the time the sidecar was saved, becomes
    ///   `<TIMESTAMP>`. The object holds the keys `config`, `reportPath`, `outputPath`, `runtime`, `toolVersion` and
    ///   `savedAt` and no key beyond those and the optional `brackenPath`, `profileOutcome`, `provenanceId`,
    ///   `fragmentComposition` and `readPairingContract`.
    /// - An EsViritu result (`esviritu-result.json`): the top-level `savedAt` alone becomes `<TIMESTAMP>`, and its
    ///   `runtime` is compared as written. The object holds `config`, `detectionPath`, `virusCount`, `runtime`,
    ///   `toolVersion` and `savedAt` and no key beyond those and the optional `assemblyPath`, `taxProfilePath`,
    ///   `coveragePath` and `provenanceId`.
    /// - An analysis folder's `analysis-metadata.json`: the top-level `created` alone becomes `<TIMESTAMP>`. The
    ///   object holds exactly `tool`, `isBatch` and `created`.
    ///
    /// The same keys in any other document, a key one level down, a document with another key or without a named
    /// one, and every other value of the three sidecars are compared as written.
    public static let resultSidecarClocks = OutputEquivalence.Mask(name: "resultSidecarClocks") { text, _ in
        rewritingJSON(text) { value, changed in maskResultSidecarClocks(in: value, changed: &changed) }
    }

    private static let classificationResultRequiredKeys: Set<String> = [
        "config", "reportPath", "outputPath", "runtime", "toolVersion", "savedAt",
    ]
    private static let classificationResultOptionalKeys: Set<String> = [
        "brackenPath", "profileOutcome", "provenanceId", "fragmentComposition", "readPairingContract",
    ]
    private static let esVirituResultRequiredKeys: Set<String> = [
        "config", "detectionPath", "virusCount", "runtime", "toolVersion", "savedAt",
    ]
    private static let esVirituResultOptionalKeys: Set<String> = [
        "assemblyPath", "taxProfilePath", "coveragePath", "provenanceId",
    ]
    private static let analysisMetadataKeys: Set<String> = ["tool", "isBatch", "created"]

    static func maskResultSidecarClocks(in value: Any, changed: inout Bool) -> Any {
        guard var object = value as? [String: Any] else { return value }
        let keys = Set(object.keys)
        if classificationResultRequiredKeys.isSubset(of: keys),
           keys.isSubset(of: classificationResultRequiredKeys.union(classificationResultOptionalKeys)) {
            object["runtime"] = "<DURATION>"
            object["savedAt"] = "<TIMESTAMP>"
        } else if esVirituResultRequiredKeys.isSubset(of: keys),
                  keys.isSubset(of: esVirituResultRequiredKeys.union(esVirituResultOptionalKeys)) {
            object["savedAt"] = "<TIMESTAMP>"
        } else if keys == analysisMetadataKeys {
            object["created"] = "<TIMESTAMP>"
        } else {
            return value
        }
        changed = true
        return object
    }
}
