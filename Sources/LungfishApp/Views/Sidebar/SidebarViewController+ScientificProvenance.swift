// SidebarViewController+ScientificProvenance.swift - Rebinding an item's provenance after the sidebar moves or copies it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The sidebar calls `rehydrateScientificProvenance(from:to:)` after a rename, a duplicate, a move to a folder, a drag
// move and a drag copy, once the file system has moved or copied the item. It moved here from SidebarViewController.swift,
// which sits at its line baseline, and a plain folder in a project now takes the path rehydrator first (2.10 R-REBIND,
// SidebarMoveOfABuiltResultFolderReplayTests). A file and a `.lungfish*` bundle keep the schema-aware path.

import AppKit
import LungfishCore
import LungfishOperations
import LungfishWorkflow
import os.log

extension SidebarViewController {

    func rehydrateScientificProvenance(from sourceURL: URL, to destinationURL: URL) {
        // A plain folder holds its records inside it, and the schema-aware path would take the project as its root.
        // The last condition keeps a folder inside any other `.lungfish*` bundle on that path.
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory), isDirectory.boolValue,
           !ProvenanceWriter.isBundleDirectory(destinationURL),
           GUIImportedProvenanceRehydrator.finalBundleRoot(containing: destinationURL).map(ProjectRootTest.isProjectRoot) == true {
            fallbackToPathRehydration(from: sourceURL, to: destinationURL)
            return
        }

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
