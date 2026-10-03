// ProvenancePublicationArtifactState.swift - State of one provenance publication artifact on disk
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import CryptoKit
import LungfishIO

indirect enum ProvenancePublicationArtifactState:
    Equatable, Sendable
{
    case missing
    case file(
        ProvenancePublicationArtifactMetadata,
        sha256: String
    )
    case symbolicLink(
        ProvenancePublicationArtifactMetadata,
        destination: String
    )
    case directory(
        ProvenancePublicationArtifactMetadata,
        children: [ProvenancePublicationDirectoryEntry]
    )
    case other(ProvenancePublicationArtifactMetadata)
}
