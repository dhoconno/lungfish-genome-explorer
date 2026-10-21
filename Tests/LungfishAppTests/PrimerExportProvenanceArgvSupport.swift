// PrimerExportProvenanceArgvSupport.swift - The argv a primer export records, for the tests that compare it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.43 M3. The app's `primerOrderExportProvenanceArgv` and `primerSelectionExportProvenanceArgv` went with
// the in-process route, since the leaf records the canonical argv of the invocation it ran. The tests that compare the
// row, the record and the leaf keep their call spelling through these two forms of that argv.

import Foundation
@testable import LungfishApp
import LungfishCore
import LungfishKit
import LungfishWorkflow

extension MainSplitViewController {
    static func primerOrderExportProvenanceArgv(
        draft: PrimerOrderDraft,
        metadata: PrimerOrderMetadata,
        destinationURL: URL
    ) -> [String] {
        primerOrderExportInvocation(draft: draft, metadata: metadata, destinationURL: destinationURL).canonicalArgv()
    }

    static func primerSelectionExportProvenanceArgv(
        analysisURL: URL,
        selection: PrimerAnalysisExportSelection,
        kind: PrimerAnalysisExportKind,
        destinationURL: URL
    ) -> [String] {
        primerSelectionExportInvocation(
            analysisURL: analysisURL, selection: selection, kind: kind, destinationURL: destinationURL
        ).canonicalArgv()
    }
}
