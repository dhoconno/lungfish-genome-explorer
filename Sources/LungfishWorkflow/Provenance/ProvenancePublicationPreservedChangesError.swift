// ProvenancePublicationPreservedChangesError.swift - Names the paths where rollback kept newer changes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Darwin
import CryptoKit
import LungfishIO

public struct ProvenancePublicationPreservedChangesError:
    Error, LocalizedError, Sendable
{
    public let paths: [String]

    public init(urls: [URL]) {
        paths = urls.map(\.path)
    }

    public var errorDescription: String? {
        "Rollback preserved newer external filesystem generations at: "
            + paths.joined(separator: ", ")
    }
}
