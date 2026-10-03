// ProvenanceWriterMutation.swift - A filesystem mutation boundary reached while provenance is published
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishIO

/// A filesystem mutation boundary reached while provenance is published.
///
/// Observers can use these boundaries to refresh a compare-and-swap rollback
/// witness before allowing publication to continue. A signing-provider event
/// is emitted after the provider returns or throws because providers may
/// create signature artifacts before reporting a failure.
public struct ProvenanceWriterMutation: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case directoryPrepared
        case provenanceDocumentWritten
        case signingArtifactsMayHaveChanged
        case artifactRemoved
    }

    public let kind: Kind
    public let affectedURLs: [URL]
    let requiredPriorStates:
        [String: ProvenancePublicationArtifactState]
    let resultingStates:
        [String: ProvenancePublicationArtifactState]

    init(
        kind: Kind,
        affectedURLs: [URL],
        requiredPriorStates:
            [String: ProvenancePublicationArtifactState] = [:],
        resultingStates:
            [String: ProvenancePublicationArtifactState] = [:]
    ) {
        self.kind = kind
        self.affectedURLs = affectedURLs
        self.requiredPriorStates = requiredPriorStates
        self.resultingStates = resultingStates
    }

    public var url: URL {
        affectedURLs[0]
    }
}
