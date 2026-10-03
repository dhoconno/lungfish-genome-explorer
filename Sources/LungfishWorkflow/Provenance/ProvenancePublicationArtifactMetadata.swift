// ProvenancePublicationArtifactMetadata.swift - File metadata captured for a provenance publication artifact
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import CryptoKit
import LungfishIO

struct ProvenancePublicationArtifactMetadata:
    Equatable, Sendable
{
    let mode: UInt32
    let device: UInt64
    let inode: UInt64
    let linkCount: UInt64
    let size: Int64
}
