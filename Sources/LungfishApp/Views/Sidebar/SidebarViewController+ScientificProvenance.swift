// SidebarViewController+ScientificProvenance.swift - Rebinding an item's provenance after the sidebar moves or copies it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The sidebar calls `rehydrateScientificProvenance(from:to:)` after a rename, a duplicate, a move to a folder, a drag
// move and a drag copy, once the file system has moved or copied the item. It moved here from SidebarViewController.swift
// with no change, since that file sits at its line baseline.

import AppKit
import LungfishOperations
import LungfishWorkflow
import os.log

extension SidebarViewController {

    func rehydrateScientificProvenance(from sourceURL: URL, to destinationURL: URL) {
        if GUIImportedProvenanceRehydrator.finalBundleRoot(containing: destinationURL) != nil {
            do {
                try GUIImportedProvenanceRehydrator.rehydrateImportedCopy(from: sourceURL, to: destinationURL)
                return
            } catch ProvenanceRehydrationError.missingSourceProvenance {
                do {
                    try GUIImportedProvenanceRehydrator.rehydrateRelocatedImportedCopy(
                        from: sourceURL,
                        to: destinationURL
                    )
                    return
                } catch GUIImportedProvenanceRehydratorError.unsupportedSourceProvenance {
                    fallbackToPathRehydration(from: sourceURL, to: destinationURL)
                    return
                } catch ProvenanceRehydrationError.missingSourceProvenance {
                    sidebarLogger.warning("rehydrateScientificProvenance: no source provenance for \(sourceURL.path, privacy: .public)")
                    return
                } catch {
                    sidebarLogger.warning("rehydrateScientificProvenance: failed relocated schema-aware rehydration for \(sourceURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return
                }
            } catch GUIImportedProvenanceRehydratorError.unsupportedSourceProvenance {
                fallbackToPathRehydration(from: sourceURL, to: destinationURL)
                return
            } catch {
                sidebarLogger.warning("rehydrateScientificProvenance: failed schema-aware rehydration for \(sourceURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }
        }

        fallbackToPathRehydration(from: sourceURL, to: destinationURL)
    }

    private func fallbackToPathRehydration(from sourceURL: URL, to destinationURL: URL) {
        ProvenancePathRehydrator.rehydrate(from: sourceURL, to: destinationURL) { message in
            sidebarLogger.warning("rehydrateScientificProvenance: \(message, privacy: .public)")
        }
    }
}
