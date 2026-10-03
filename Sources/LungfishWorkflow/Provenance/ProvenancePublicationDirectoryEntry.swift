// ProvenancePublicationDirectoryEntry.swift - A named entry inside a directory artifact
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import CryptoKit
import LungfishIO

struct ProvenancePublicationDirectoryEntry:
    Equatable, Sendable
{
    let name: String
    let state: ProvenancePublicationArtifactState
}
