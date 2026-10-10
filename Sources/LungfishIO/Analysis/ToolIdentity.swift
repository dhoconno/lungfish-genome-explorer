// ToolIdentity.swift - Typed identifiers for analysis kinds and managed tools
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The identifier of an analysis kind, the result type stored under `Analyses/`.
///
/// The raw value is today's analysis id such as `kraken2`, `bbmap` or `ont-genotyping`.
/// Unknown ids are valid, because an id can come from a newer build or an import sidecar.
/// It is deliberately not an enum and not `ExpressibleByStringLiteral`, so a lock id such
/// as `bbtools` cannot stand in for an analysis id by accident. It is coded as a bare
/// JSON string.
public struct AnalysisToolID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// The identifier of a managed tool, an entry of the managed tool lock.
///
/// The raw value is the lock's `tools[].id` or `packTools[].id` such as `bbtools`,
/// `htslib` or `gatk4`. It has the same shape and rules as ``AnalysisToolID`` and is a
/// separate type so the two identity spaces cannot be mixed.
public struct ManagedToolID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}
