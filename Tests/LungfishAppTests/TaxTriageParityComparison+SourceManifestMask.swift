// TaxTriageParityComparison+SourceManifestMask.swift - The one mask of a TaxTriage source manifest, its summary's runtime
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane B30, BIO ruling Q1 and panel vote V-B30 (4 to 0 for option b). The command writes each source
// bundle's TaxTriage entry with the app's summary, whose second line names the seconds the pipeline ran
// (`TaxTriageResult.summary`), a measured value as a record's wall time is. The parity masks that number and nothing
// else, and only in the source manifests `folderDifferences` compares, never in the analysis folder, the inputs or the
// rest of the project, as `scripts/golden/normalize.py` masks the same token. The pattern needs the JSON-escaped
// newline on both sides of the line, so it hides only the digits and cannot hide a line that is missing. The
// contract's mask row (`docs/contracts/CLI-EQUIVALENCE.md`) stays as it is, as under G3.
// `TaxTriageParitySourceManifestMaskTests` pins what it hides and what it leaves.

import Foundation
import LungfishTestSupport

extension TaxTriageParityComparison {
    /// The name of the mask, as the plan's row for V-B30 names it.
    static let summaryRuntimeMaskName = "summaryRuntime"

    /// B30 ruling Q1. A TaxTriage entry's summary names the seconds its pipeline ran, as the app's entry always
    /// has, a measured value as a record's wall time is. Only that number is masked, as normalize.py masks it.
    /// `policy` is the compare's own policy, which this leaves as it is for every other file.
    static func sourceManifestPolicy(_ policy: OutputEquivalence.MaskPolicy) -> OutputEquivalence.MaskPolicy {
        var manifest = policy
        manifest.records.append(OutputEquivalence.Mask(name: summaryRuntimeMaskName) { text, _ in
            text.replacingOccurrences(
                of: "(\\\\nRuntime: )[0-9]+\\.[0-9](s\\\\n)", with: "$1<RUNTIME>$2", options: .regularExpression
            )
        })
        return manifest
    }
}
