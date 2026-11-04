// SidebarViewController+CloneMetadata.swift - Clone Metadata saves each target and says which saves failed
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishKit

extension SidebarViewController {
    /// Writes `source`'s metadata to each target bundle under the target's own sample name, and returns the targets
    /// that could not be written, each with its error (METADATA-EDIT-READONLY, Phase 3.2). The old loop used `try?`,
    /// so a read-only or full volume lost the copy with no words and the change notice went out as if it had worked.
    static func cloneMetadata(_ source: FASTQSampleMetadata, to targets: [URL]) -> [(target: URL, error: any Error)] {
        var failed: [(target: URL, error: any Error)] = []
        for target in targets {
            let cloned = source.cloned(withName: target.deletingPathExtension().lastPathComponent)
            do {
                try FASTQBundleCSVMetadata.save(cloned.toLegacyCSV(), to: target)
            } catch {
                failed.append((target: target, error: error))
            }
        }
        return failed
    }

    /// The one alert for the targets that could not be written, or nil when every save worked. `total` is the number
    /// of targets. The error text of each goes only to the details area.
    static func cloneMetadataFailureReport(_ failed: [(target: URL, error: any Error)], of total: Int) -> FailureReport? {
        guard let first = failed.first else { return nil }
        let names = failed.map { $0.target.deletingPathExtension().lastPathComponent }
        let others = total - failed.count
        let kept = others <= 0 ? "" : (others == 1 ? " The other one got the copy." : " The other \(others) got the copy.")
        let nextStep = "Move the project somewhere you can write to, then copy the metadata again."
        if failed.count == 1 {
            return FailureReport(
                failedStep: "Copy the metadata to \(names[0])",
                whatHappened: "Lungfish could not save the copied metadata in \(names[0]). The location may be read-only or full.\(kept)",
                nextStep: nextStep,
                underlying: first.error
            )
        }
        let shown = names.prefix(5).joined(separator: ", ")
        let rest = names.count > 5 ? " and \(names.count - 5) more" : ""
        return FailureReport(
            failedStep: "Copy the metadata to \(failed.count) of \(total) samples",
            whatHappened: "Lungfish could not save the copied metadata in \(shown)\(rest). The location may be read-only or full.\(kept)",
            nextStep: nextStep,
            itemErrors: zip(names, failed).map { (name: $0, error: $1.error) }
        )
    }
}
