// ProvenancePublicationArtifacts.swift - Lists the artifacts a provenance publication touches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import CryptoKit
import LungfishIO

public enum ProvenancePublicationArtifacts {
    public static func bundleRootArtifacts(for rootURL: URL) -> [URL] {
        sidecarArtifacts(for: rootURL.appendingPathComponent(ProvenanceWriter.provenanceFilename))
            + [rootURL.appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)]
    }

    public static func fileSidecarArtifacts(for outputURL: URL) -> [URL] {
        sidecarArtifacts(for: ProvenanceRecorder.fileSidecarURL(for: outputURL))
    }

    public static func sidecarArtifacts(for sidecarURL: URL) -> [URL] {
        [
            sidecarURL,
            ProvenanceSigningConfiguration.signatureURL(for: sidecarURL),
            ProvenanceSigningConfiguration.publicKeyURL(for: sidecarURL),
        ]
    }

    /// Removes a record with the `<record>.signature.json` and `<record>.pub` beside it. The public key and the
    /// signature go first, so an interrupted removal never leaves a signature beside a record that is gone, and a
    /// signature that stays beside the record a later run writes is never over bytes the new record does not hold.
    public static func removeSidecarArtifacts(for sidecarURL: URL) throws {
        let fileManager = FileManager.default
        for artifact in sidecarArtifacts(for: sidecarURL).reversed() where fileManager.fileExists(atPath: artifact.path) {
            try fileManager.removeItem(at: artifact)
        }
    }
}
