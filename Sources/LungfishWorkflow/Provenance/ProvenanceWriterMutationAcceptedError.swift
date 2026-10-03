// ProvenanceWriterMutationAcceptedError.swift - Signals that a mutation receipt was accepted before a stop request
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishIO

/// Signals that a mutation receipt was accepted before a downstream observer
/// requested publication to stop. The writer must not undo the accepted
/// mutation; the enclosing transaction owns rollback from this point.
public struct ProvenanceWriterMutationAcceptedError:
    Error, LocalizedError, Sendable
{
    public let underlyingDescription: String

    public init(_ error: Error) {
        underlyingDescription = String(reflecting: error)
    }

    public var errorDescription: String? {
        underlyingDescription
    }
}
