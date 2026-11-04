// FASTQMetadataSaveFailureReports.swift - The words of a metadata edit that could not be saved
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

extension InspectorFailureReports {
    /// A person's edit of a read set's metadata could not be written to its bundle, such as on a read-only or full
    /// volume (METADATA-EDIT-READONLY, Phase 3.2). `bundleName` is the bundle as the sidebar names it, and the error
    /// text goes only to the details area.
    static func saveMetadataEdit(bundleName: String, _ error: any Error) -> FailureReport {
        FailureReport(
            failedStep: "Save the metadata edit",
            whatHappened: "Lungfish could not save this metadata edit in \(bundleName). The location may be read-only or full.",
            nextStep: "Move the project somewhere you can write to, then make the edit again.",
            underlying: error
        )
    }
}
