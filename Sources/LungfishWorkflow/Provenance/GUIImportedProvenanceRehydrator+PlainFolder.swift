// GUIImportedProvenanceRehydrator+PlainFolder.swift - A plain result folder is its own provenance root
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane COPYFOLDER, row COPY-PLAIN-FOLDER-SIDECAR. A TaxTriage, Kraken 2, EsViritu, NVD or NAO-MGS result is a
// plain folder (no `lungfish*` extension) that holds its own record at its root. The enclosing project is the provenance
// root of a `lungfish*` bundle only, and taking it for a plain folder's root never finds the record inside the folder.
// A relocated copy of such a folder reads the record where the run wrote it, so its project-relative paths resolve
// against the source project, and every recorded digest is compared with the file in the copy.

import Foundation

extension GUIImportedProvenanceRehydrator {
    /// Whether both folders are plain folders that hold a record at their root.
    static func foldersHoldTheirOwnRecord(source: URL, destination: URL) -> Bool {
        [source, destination].allSatisfy { folder in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
                && !ProvenanceWriter.isBundleDirectory(folder)
                && FileManager.default.fileExists(
                    atPath: folder.appendingPathComponent(ProvenanceRecorder.provenanceFilename).path
                )
        }
    }

    /// The roots of a relocated copy. Plain folders that hold their records are their own roots, and any other item
    /// keeps the roots it always had.
    static func relocatedRoots(source: URL, destination: URL, ownsRecord: Bool) throws -> (source: URL, destination: URL) {
        guard ownsRecord else { return (provenanceRoot(for: source), try finalProvenanceRoot(for: destination)) }
        return (source.standardizedFileURL, destination.standardizedFileURL)
    }
}
