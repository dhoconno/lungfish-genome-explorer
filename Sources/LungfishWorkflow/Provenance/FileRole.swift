// FileRole.swift - Role of a file in a workflow step
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishCore

// MARK: - FileRole

/// The role of a file in a run or step (`input`, `output`), by its raw value.
///
/// It is string-backed like `BundleKindID`, so a value this build does not know, such as a later
/// writer's `sampleSheet`, decodes and encodes again unchanged inside a record of schema version 2 or
/// later. In a version 1 record such a value fails to decode as it always did, so the record still
/// falls to the primitive adapter and a released record keeps its shape and signing payload. The
/// static members are the values this build knows.
public struct FileRole: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The role with this raw value when this build knows it, else nil, for a site that maps an
    /// unknown name to a fallback.
    public init?(knownRawValue rawValue: String) {
        guard Self.known.contains(FileRole(rawValue: rawValue)) else { return nil }
        self.init(rawValue: rawValue)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let role = FileRole(rawValue: try container.decode(String.self))
        guard role.isKnown || ProvenanceFileValueDecoding.acceptsUnknownValues else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot initialize FileRole from invalid String value \(role.rawValue)"
            )
        }
        self = role
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    /// True for a value this build knows.
    public var isKnown: Bool { Self.known.contains(self) }

    public static let input = FileRole(rawValue: "input")
    public static let output = FileRole(rawValue: "output")
    public static let reference = FileRole(rawValue: "reference")
    public static let index = FileRole(rawValue: "index")
    public static let log = FileRole(rawValue: "log")
    public static let report = FileRole(rawValue: "report")

    /// The values this build knows, which a version 1 record may hold.
    public static let known: Set<FileRole> = [.input, .output, .reference, .index, .log, .report]
}
