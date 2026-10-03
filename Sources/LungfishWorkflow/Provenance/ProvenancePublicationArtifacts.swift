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
}
